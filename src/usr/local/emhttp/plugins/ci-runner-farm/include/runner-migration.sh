#!/bin/bash
# Durable, fail-closed classic <-> scale-set backend migration.
# POOL_BACKEND is requested intent only. Effective state is read exclusively
# from the persisted transition record.

MIGRATION_STATE="${MIGRATION_STATE:-$CFGDIR/backend-transition.json}"
MIGRATION_CLASSIC_QUIESCE_FILE="${MIGRATION_CLASSIC_QUIESCE_FILE:-$RUNDIR/classic-admissions.quiesced}"
MIGRATION_CLASSIC_QUARANTINE_STATE="${MIGRATION_CLASSIC_QUARANTINE_STATE:-$CFGDIR/classic-quarantine.json}"
MIGRATION_EFFECTIVE_BACKEND=classic
MIGRATION_REQUESTED_BACKEND=classic
MIGRATION_PHASE=classic_active
MIGRATION_TRANSITION_ID=""
MIGRATION_TARGET_CONFIG_REVISION=""
MIGRATION_OWNERSHIP_REVISION=""
MIGRATION_COMPATIBILITY_RECORD_ID=""
MIGRATION_LAST_BARRIER=classic_only
MIGRATION_UPDATED_AT=""
MIGRATION_REVISION=""
MIGRATION_QUARANTINE_OWNER=""
MIGRATION_QUARANTINE_INSTALLATION_ID=""
MIGRATION_QUARANTINE_GROUP_NAME=""
MIGRATION_QUARANTINE_GROUP_ID=0
MIGRATION_QUARANTINE_PHASE=""
MIGRATION_QUARANTINE_TRANSITION_ID=""
MIGRATION_QUARANTINE_FOUND_ID=0

migration_revision_compute() {
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s' \
    "$MIGRATION_REQUESTED_BACKEND" "$MIGRATION_EFFECTIVE_BACKEND" "$MIGRATION_PHASE" \
    "$MIGRATION_TRANSITION_ID" "$MIGRATION_TARGET_CONFIG_REVISION" \
    "$MIGRATION_OWNERSHIP_REVISION" "$MIGRATION_COMPATIBILITY_RECORD_ID" |
    sha256sum | cut -d' ' -f1
}

migration_load() {
  local values
  MIGRATION_REQUESTED_BACKEND="${POOL_BACKEND:-classic}"
  MIGRATION_EFFECTIVE_BACKEND=classic; MIGRATION_PHASE=classic_active
  MIGRATION_TRANSITION_ID=""; MIGRATION_TARGET_CONFIG_REVISION=""
  MIGRATION_OWNERSHIP_REVISION=""; MIGRATION_COMPATIBILITY_RECORD_ID=""
  MIGRATION_LAST_BARRIER=classic_only; MIGRATION_UPDATED_AT=""
  if [ -f "$MIGRATION_STATE" ]; then
    [ ! -L "$MIGRATION_STATE" ] &&
      [ "$(stat -c %a "$MIGRATION_STATE" 2>/dev/null)" = 600 ] &&
      [ "$(stat -c %s "$MIGRATION_STATE" 2>/dev/null)" -le 65536 ] || return 1
    values="$(php -r '
      $j=json_decode(file_get_contents($argv[1]),true);
      $keys=["requested_backend","effective_backend","transition_phase","transition_id",
        "target_config_revision","ownership_revision","compatibility_record_id",
        "last_proven_barrier","updated_at"];
      if(!is_array($j)||($j["schema_version"]??0)!==1)exit(2);
      foreach($keys as $k){$v=$j[$k]??"";if(!is_string($v)||str_contains($v,"|")||preg_match("/[\\x00-\\x1f]/",$v))exit(3);echo $v,"|";}
    ' "$MIGRATION_STATE" 2>/dev/null)" || return 1
    IFS='|' read -r MIGRATION_REQUESTED_BACKEND MIGRATION_EFFECTIVE_BACKEND MIGRATION_PHASE \
      MIGRATION_TRANSITION_ID MIGRATION_TARGET_CONFIG_REVISION MIGRATION_OWNERSHIP_REVISION \
      MIGRATION_COMPATIBILITY_RECORD_ID MIGRATION_LAST_BARRIER MIGRATION_UPDATED_AT _ <<<"$values"
  fi
  case "$MIGRATION_REQUESTED_BACKEND" in classic|scaleset) ;; *) return 1 ;; esac
  case "$MIGRATION_EFFECTIVE_BACKEND:$MIGRATION_PHASE" in
    classic:classic_active|classic:preparing_scaleset_ineligible|classic:quiescing_classic|\
    classic:classic_ineligible|classic:activating_scaleset|scaleset:scaleset_active|\
    scaleset:quiescing_scaleset|scaleset:scaleset_ineligible|scaleset:draining_assigned_jit|\
    scaleset:activating_classic) ;;
    *) return 1 ;;
  esac
  MIGRATION_REVISION="$(migration_revision_compute)"
}

migration_write() {
  local phase="$1" effective="$2" barrier="$3" tmp dir
  case "$effective:$phase" in
    classic:classic_active|classic:preparing_scaleset_ineligible|classic:quiescing_classic|\
    classic:classic_ineligible|classic:activating_scaleset|scaleset:scaleset_active|\
    scaleset:quiescing_scaleset|scaleset:scaleset_ineligible|scaleset:draining_assigned_jit|\
    scaleset:activating_classic) ;;
    *) return 1 ;;
  esac
  dir="$(dirname "$MIGRATION_STATE")"; mkdir -p "$dir" || return 1
  tmp="$MIGRATION_STATE.tmp.$$"
  php -r '
    $j=["schema_version"=>1,"requested_backend"=>$argv[2],"effective_backend"=>$argv[3],
      "transition_phase"=>$argv[4],"transition_id"=>$argv[5],
      "target_config_revision"=>$argv[6],"ownership_revision"=>$argv[7],
      "compatibility_record_id"=>$argv[8],"last_proven_barrier"=>$argv[9],
      "updated_at"=>gmdate("c")];
    $h=fopen($argv[1],"xb");if(!$h)exit(2);
    if(fwrite($h,json_encode($j,JSON_UNESCAPED_SLASHES)."\n")===false||!fflush($h))exit(3);
    if(function_exists("fsync")&&!fsync($h))exit(4);
    fclose($h);
  ' "$tmp" "${POOL_BACKEND:-classic}" "$effective" "$phase" "$MIGRATION_TRANSITION_ID" \
    "$MIGRATION_TARGET_CONFIG_REVISION" "$MIGRATION_OWNERSHIP_REVISION" \
    "$MIGRATION_COMPATIBILITY_RECORD_ID" "$barrier" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f "$tmp" "$MIGRATION_STATE" || { rm -f "$tmp"; return 1; }
  migration_load
}

backend_effective() {
  migration_load || { printf 'invalid\n'; return 1; }
  printf '%s\n' "$MIGRATION_EFFECTIVE_BACKEND"
}

backend_classic_admission_allowed() {
  migration_load || return 1
  case "$MIGRATION_EFFECTIVE_BACKEND:$MIGRATION_PHASE:$MIGRATION_LAST_BARRIER" in
    classic:classic_active:classic_only|scaleset:activating_classic:jit_drained) return 0 ;;
    *) return 1 ;;
  esac
}

backend_scaleset_admission_allowed() {
  migration_load || return 1
  case "$MIGRATION_EFFECTIVE_BACKEND:$MIGRATION_PHASE:$MIGRATION_LAST_BARRIER" in
    scaleset:scaleset_active:scaleset_eligible|classic:activating_scaleset:classic_ineligible)
      return 0
      ;;
    *) return 1 ;;
  esac
}

migration_revision_valid() { [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; }

migration_record_matches() {
  local expected="$1" id
  scaleset_record_valid || return 1
  id="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);echo $j["compatibility_record_id"]??"";' \
    "$SCALESET_COMPAT" 2>/dev/null)"
  [ "$id" = "$expected" ]
}

migration_start() {
  local expected_config="$1" ownership="$2" compatibility="$3" expected_transition="$4"
  migration_revision_valid "$expected_config" && migration_revision_valid "$ownership" &&
    migration_revision_valid "$compatibility" && migration_revision_valid "$expected_transition" ||
    { err "invalid migration revision"; return 2; }
  migration_load || { err "backend transition state is invalid"; return 2; }
  [ "$MIGRATION_REVISION" = "$expected_transition" ] ||
    { err "backend transition changed in another session"; return 3; }
  [ "$(config_revision)" = "$expected_config" ] ||
    { err "configuration changed before migration"; return 3; }
  [ "$POOL_BACKEND" = scaleset ] || { err "requested backend is not scaleset"; return 2; }
  migration_record_matches "$compatibility" ||
    { err "compatibility evidence is missing, stale, or does not match"; return 2; }
  if [ "$MIGRATION_PHASE" = classic_active ]; then
    MIGRATION_TRANSITION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s' "$$-$(date +%s)")"
    MIGRATION_TARGET_CONFIG_REVISION="$expected_config"
    MIGRATION_OWNERSHIP_REVISION="$ownership"
    MIGRATION_COMPATIBILITY_RECORD_ID="$compatibility"
    migration_write preparing_scaleset_ineligible classic classic_only || return 1
  fi
  migration_advance_forward
}

migration_advance_forward() {
  [ "$(config_revision)" = "$MIGRATION_TARGET_CONFIG_REVISION" ] ||
    { err "migration paused because configuration changed"; return 3; }
  case "$MIGRATION_PHASE" in
    preparing_scaleset_ineligible)
      scaleset_supervisor_start && scaleset_prepare_ineligible "$MIGRATION_OWNERSHIP_REVISION" &&
        migration_write quiescing_classic classic scaleset_ineligible
      ;;
    quiescing_classic)
      migration_classic_quiesce &&
        migration_write classic_ineligible classic classic_drained
      ;;
    classic_ineligible)
      migration_classic_prove_ineligible &&
        migration_write activating_scaleset classic classic_ineligible
      ;;
    activating_scaleset)
      scaleset_activate_eligible "$MIGRATION_OWNERSHIP_REVISION" &&
        scaleset_autoscale_tick &&
        scaleset_activation_prove_effective &&
        migration_write scaleset_active scaleset scaleset_eligible
      ;;
    scaleset_active) return 0 ;;
    *) err "forward migration is not valid from $MIGRATION_PHASE"; return 2 ;;
  esac
}

migration_rollback() {
  local expected_config="$1" ownership="$2" compatibility="$3" expected_transition="$4"
  migration_load || return 2
  [ "$MIGRATION_REVISION" = "$expected_transition" ] &&
    [ "$(config_revision)" = "$expected_config" ] &&
    [ "$MIGRATION_OWNERSHIP_REVISION" = "$ownership" ] &&
    [ "$MIGRATION_COMPATIBILITY_RECORD_ID" = "$compatibility" ] ||
    { err "rollback revisions do not match persisted transition"; return 3; }
  if [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ] && [ "$MIGRATION_PHASE" != classic_active ]; then
    scaleset_make_ineligible "$MIGRATION_OWNERSHIP_REVISION" &&
      migration_classic_activate && migration_classic_prove_effective &&
      scaleset_delete_owned "$MIGRATION_OWNERSHIP_REVISION" &&
      { scaleset_supervisor_stop; migration_write classic_active classic classic_only; }
    return
  fi
  if [ "$MIGRATION_PHASE" = scaleset_active ]; then
    migration_write quiescing_scaleset scaleset scaleset_eligible || return 1
  fi
  migration_advance_reverse
}

migration_advance_reverse() {
  case "$MIGRATION_PHASE" in
    quiescing_scaleset)
      scaleset_make_ineligible "$MIGRATION_OWNERSHIP_REVISION" &&
        migration_write scaleset_ineligible scaleset scaleset_ineligible
      ;;
    scaleset_ineligible)
      scaleset_publish_zero_capacity &&
        migration_write draining_assigned_jit scaleset scaleset_ineligible
      ;;
    draining_assigned_jit)
      jit_reconcile
      migration_jit_drained &&
        migration_write activating_classic scaleset jit_drained
      ;;
    activating_classic)
      migration_classic_activate && migration_classic_prove_effective &&
        scaleset_delete_owned "$MIGRATION_OWNERSHIP_REVISION" &&
        migration_write classic_active classic classic_only
      ;;
    classic_active) return 0 ;;
    *) err "rollback is not valid from $MIGRATION_PHASE"; return 2 ;;
  esac
}

migration_quarantine_identity() {
  local installation suffix
  [ "${GH_SCOPE:-}" = org ] && [ -n "${GH_OWNER:-}" ] || return 1
  installation="$(scaleset_installation_id)" || return 1
  [[ "$installation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  suffix="$(printf '%s' "$GH_OWNER|$installation" | sha256sum | cut -c1-16)"
  MIGRATION_QUARANTINE_OWNER="$GH_OWNER"
  MIGRATION_QUARANTINE_INSTALLATION_ID="$installation"
  MIGRATION_QUARANTINE_GROUP_NAME="crf-quarantine-$suffix"
}

migration_quarantine_state_load() {
  local values
  [ -f "$MIGRATION_CLASSIC_QUARANTINE_STATE" ] &&
    [ ! -L "$MIGRATION_CLASSIC_QUARANTINE_STATE" ] &&
    [ "$(stat -c %a "$MIGRATION_CLASSIC_QUARANTINE_STATE" 2>/dev/null)" = 600 ] &&
    [ "$(stat -c %s "$MIGRATION_CLASSIC_QUARANTINE_STATE" 2>/dev/null)" -le 16384 ] || return 1
  values="$(php -r '
    $j=json_decode(file_get_contents($argv[1]),true);
    $keys=["schema_version","owner","installation_id","group_name","group_id","phase","transition_id"];
    if(!is_array($j)||array_keys($j)!==$keys||$j["schema_version"]!==1||
      !is_string($j["owner"])||!is_string($j["installation_id"])||
      !is_string($j["group_name"])||!is_int($j["group_id"])||$j["group_id"]<0||
      !is_string($j["phase"])||!in_array($j["phase"],["create_intent","active","delete_intent"],true)||
      !is_string($j["transition_id"]))exit(2);
    foreach(["owner","installation_id","group_name","phase","transition_id"] as $k)
      if(str_contains($j[$k],"|")||preg_match("/[\x00-\x1f]/",$j[$k]))exit(3);
    echo $j["owner"],"|",$j["installation_id"],"|",$j["group_name"],"|",
      $j["group_id"],"|",$j["phase"],"|",$j["transition_id"],"|";
  ' "$MIGRATION_CLASSIC_QUARANTINE_STATE" 2>/dev/null)" || return 1
  IFS='|' read -r MIGRATION_QUARANTINE_OWNER MIGRATION_QUARANTINE_INSTALLATION_ID \
    MIGRATION_QUARANTINE_GROUP_NAME MIGRATION_QUARANTINE_GROUP_ID \
    MIGRATION_QUARANTINE_PHASE MIGRATION_QUARANTINE_TRANSITION_ID _ <<<"$values"
  [[ "$MIGRATION_QUARANTINE_GROUP_ID" =~ ^[0-9]+$ ]]
}

migration_quarantine_state_write() {
  local phase="$1" group_id="$2" tmp
  case "$phase" in create_intent|active|delete_intent) ;; *) return 1 ;; esac
  [[ "$group_id" =~ ^[0-9]+$ ]] || return 1
  [ "$phase" = create_intent ] || [ "$group_id" -gt 0 ] || return 1
  mkdir -p "$(dirname "$MIGRATION_CLASSIC_QUARANTINE_STATE")" || return 1
  tmp="$MIGRATION_CLASSIC_QUARANTINE_STATE.tmp.$$"
  php -r '
    $j=["schema_version"=>1,"owner"=>$argv[2],"installation_id"=>$argv[3],
      "group_name"=>$argv[4],"group_id"=>(int)$argv[5],"phase"=>$argv[6],
      "transition_id"=>$argv[7]];
    $h=fopen($argv[1],"xb");if(!$h)exit(2);
    if(fwrite($h,json_encode($j,JSON_UNESCAPED_SLASHES)."\n")===false||!fflush($h))exit(3);
    if(function_exists("fsync")&&!fsync($h))exit(4);
    fclose($h);
  ' "$tmp" "$MIGRATION_QUARANTINE_OWNER" "$MIGRATION_QUARANTINE_INSTALLATION_ID" \
    "$MIGRATION_QUARANTINE_GROUP_NAME" "$group_id" "$phase" \
    "$MIGRATION_TRANSITION_ID" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f "$tmp" "$MIGRATION_CLASSIC_QUARANTINE_STATE" ||
    { rm -f "$tmp"; return 1; }
  migration_quarantine_state_load
}

migration_quarantine_group_find() {
  local name="$1" page=1 parsed count found
  MIGRATION_QUARANTINE_FOUND_ID=0
  while [ "$page" -le 100 ]; do
    gh_api_request GET "/orgs/$GH_OWNER/actions/runner-groups?per_page=100&page=$page" ||
      return 1
    parsed="$(printf '%s' "$GH_RESPONSE" | php -r '
      $j=json_decode(stream_get_contents(STDIN),true);
      if(!is_array($j)||!isset($j["runner_groups"])||!is_array($j["runner_groups"]))exit(2);
      $found=[];
      foreach($j["runner_groups"] as $g)if(($g["name"]??null)===$argv[1])$found[]=$g;
      if(count($found)>1)exit(3);
      $id=0;
      if(count($found)===1){
        $g=$found[0];
        if(!is_int($g["id"]??null)||$g["id"]<=0||
          ($g["visibility"]??"")!=="selected"||
          ($g["allows_public_repositories"]??null)!==false)exit(4);
        $id=$g["id"];
      }
      echo count($j["runner_groups"]),"|",$id;
    ' "$name" 2>/dev/null)" || return 1
    IFS='|' read -r count found <<<"$parsed"
    [[ "$count" =~ ^[0-9]+$ ]] && [[ "$found" =~ ^[0-9]+$ ]] || return 1
    if [ "$found" -gt 0 ]; then
      MIGRATION_QUARANTINE_FOUND_ID="$found"
      return 0
    fi
    [ "$count" -lt 100 ] && return 0
    page=$((page + 1))
  done
  return 1
}

migration_quarantine_ensure() {
  local expected_owner expected_installation expected_name body
  migration_quarantine_identity || { err "could not derive classic quarantine identity"; return 1; }
  expected_owner="$MIGRATION_QUARANTINE_OWNER"
  expected_installation="$MIGRATION_QUARANTINE_INSTALLATION_ID"
  expected_name="$MIGRATION_QUARANTINE_GROUP_NAME"
  if [ -e "$MIGRATION_CLASSIC_QUARANTINE_STATE" ]; then
    migration_quarantine_state_load ||
      { err "classic quarantine ownership state is invalid"; return 1; }
    [ "$MIGRATION_QUARANTINE_OWNER" = "$expected_owner" ] &&
      [ "$MIGRATION_QUARANTINE_INSTALLATION_ID" = "$expected_installation" ] &&
      [ "$MIGRATION_QUARANTINE_GROUP_NAME" = "$expected_name" ] &&
      [ "$MIGRATION_QUARANTINE_TRANSITION_ID" = "$MIGRATION_TRANSITION_ID" ] ||
      { err "classic quarantine ownership identity does not match this transition"; return 1; }
  else
    migration_quarantine_group_find "$expected_name" ||
      { err "could not check for an existing classic quarantine group"; return 1; }
    [ "$MIGRATION_QUARANTINE_FOUND_ID" -eq 0 ] ||
      { err "refusing to adopt unowned runner group $expected_name"; return 1; }
    MIGRATION_QUARANTINE_OWNER="$expected_owner"
    MIGRATION_QUARANTINE_INSTALLATION_ID="$expected_installation"
    MIGRATION_QUARANTINE_GROUP_NAME="$expected_name"
    migration_quarantine_state_write create_intent 0 || return 1
  fi
  case "$MIGRATION_QUARANTINE_PHASE" in
    create_intent)
      migration_quarantine_group_find "$MIGRATION_QUARANTINE_GROUP_NAME" || return 1
      if [ "$MIGRATION_QUARANTINE_FOUND_ID" -eq 0 ]; then
        body="$(php -r 'echo json_encode(["name"=>$argv[1],"visibility"=>"selected",
          "allows_public_repositories"=>false],JSON_UNESCAPED_SLASHES);' \
          "$MIGRATION_QUARANTINE_GROUP_NAME")" || return 1
        # The subsequent exact-name lookup is authoritative. It also recovers
        # an accepted POST whose response was lost.
        gh_api_request POST "/orgs/$GH_OWNER/actions/runner-groups" "$body" || true
        migration_quarantine_group_find "$MIGRATION_QUARANTINE_GROUP_NAME" ||
          { err "could not recover classic quarantine group creation"; return 1; }
      fi
      [ "$MIGRATION_QUARANTINE_FOUND_ID" -gt 0 ] ||
        { err "GitHub did not create the classic quarantine group"; return 1; }
      migration_quarantine_state_write active "$MIGRATION_QUARANTINE_FOUND_ID" || return 1
      ;;
    active)
      migration_quarantine_group_find "$MIGRATION_QUARANTINE_GROUP_NAME" || return 1
      [ "$MIGRATION_QUARANTINE_FOUND_ID" -eq "$MIGRATION_QUARANTINE_GROUP_ID" ] ||
        { err "owned classic quarantine group is missing or changed"; return 1; }
      ;;
    delete_intent)
      err "classic quarantine cleanup is incomplete"
      return 1
      ;;
  esac
}

migration_quarantine_group_inventory() {
  local group_id="$1" output="$2" page=1 parsed count
  : >"$output" || return 1
  while [ "$page" -le 100 ]; do
    gh_api_request GET "/orgs/$GH_OWNER/actions/runner-groups/$group_id/runners?per_page=100&page=$page" ||
      { rm -f "$output"; return 1; }
    parsed="$output.page"
    if ! printf '%s' "$GH_RESPONSE" | php -r '
      $j=json_decode(stream_get_contents(STDIN),true);
      if(!is_array($j)||!isset($j["runners"])||!is_array($j["runners"]))exit(2);
      foreach($j["runners"] as $r){
        $id=$r["id"]??null;$name=$r["name"]??null;
        if(!is_int($id)||$id<=0||!is_string($name)||str_contains($name,"|")||
          preg_match("/[\x00-\x1f]/",$name))exit(3);
        echo $id,"|",$name,"\n";
      }
    ' >"$parsed"; then
      rm -f "$output" "$parsed"; return 1
    fi
    count="$(wc -l <"$parsed" | tr -d ' ')"
    cat "$parsed" >>"$output"; rm -f "$parsed"
    [ "$count" -lt 100 ] && { chmod 0600 "$output"; return 0; }
    page=$((page + 1))
  done
  rm -f "$output"
  return 1
}

migration_quarantine_move_all() {
  local inventory runner remote records group_inventory match id name
  migration_quarantine_ensure || return 1
  [ "$MIGRATION_QUARANTINE_GROUP_ID" -gt 0 ] || return 1
  inventory="$(github_runner_inventory "org:$GH_OWNER")" ||
    { err "could not inventory classic runner registrations before quarantine"; return 1; }
  records="$(mktemp "$RUNDIR/classic-quarantine-records.XXXXXX")" || return 1
  : >"$records"
  for runner in $(managed_names); do
    [ -n "$runner" ] || continue
    remote="$(host)-$runner"
    match="$(printf '%s\n' "$inventory" |
      awk -F'|' -v hosted="$remote" -v plain="$runner" '$2 == hosted || $2 == plain { print $1"|"$2 }')"
    [ "$(printf '%s\n' "$match" | sed '/^$/d' | wc -l)" -eq 1 ] ||
      { rm -f "$records"; err "could not resolve one exact GitHub registration for $runner"; return 1; }
    printf '%s\n' "$match" >>"$records"
  done
  chmod 0600 "$records"
  while IFS='|' read -r id name; do
    [ -n "$id" ] || continue
    gh_api_request PUT \
      "/orgs/$GH_OWNER/actions/runner-groups/$MIGRATION_QUARANTINE_GROUP_ID/runners/$id" ||
      { rm -f "$records"; err "could not quarantine classic runner $name"; return 1; }
    [ "$GH_STATUS" = 204 ] ||
      { rm -f "$records"; err "GitHub rejected classic runner quarantine for $name"; return 1; }
  done <"$records"
  group_inventory="$(mktemp "$RUNDIR/classic-quarantine-group.XXXXXX")" ||
    { rm -f "$records"; return 1; }
  migration_quarantine_group_inventory "$MIGRATION_QUARANTINE_GROUP_ID" "$group_inventory" ||
    { rm -f "$records" "$group_inventory"; return 1; }
  while IFS='|' read -r id name; do
    [ -n "$id" ] || continue
    awk -F'|' -v want="$id" '$1 == want { found=1 } END { exit !found }' "$group_inventory" ||
      { rm -f "$records" "$group_inventory"; err "classic runner $name was not quarantined"; return 1; }
  done <"$records"
  rm -f "$records" "$group_inventory"
}

migration_quarantine_delete() {
  local expected_owner expected_installation expected_name
  [ -e "$MIGRATION_CLASSIC_QUARANTINE_STATE" ] || return 0
  migration_quarantine_identity || return 1
  expected_owner="$MIGRATION_QUARANTINE_OWNER"
  expected_installation="$MIGRATION_QUARANTINE_INSTALLATION_ID"
  expected_name="$MIGRATION_QUARANTINE_GROUP_NAME"
  migration_quarantine_state_load || return 1
  [ "$MIGRATION_QUARANTINE_OWNER" = "$expected_owner" ] &&
    [ "$MIGRATION_QUARANTINE_INSTALLATION_ID" = "$expected_installation" ] &&
    [ "$MIGRATION_QUARANTINE_GROUP_NAME" = "$expected_name" ] &&
    [ "$MIGRATION_QUARANTINE_TRANSITION_ID" = "$MIGRATION_TRANSITION_ID" ] &&
    [ "$MIGRATION_QUARANTINE_GROUP_ID" -gt 0 ] ||
    { err "refusing to delete a classic quarantine group with mismatched ownership"; return 1; }
  [ "$MIGRATION_QUARANTINE_PHASE" = delete_intent ] ||
    migration_quarantine_state_write delete_intent "$MIGRATION_QUARANTINE_GROUP_ID" || return 1
  migration_quarantine_group_find "$MIGRATION_QUARANTINE_GROUP_NAME" || return 1
  if [ "$MIGRATION_QUARANTINE_FOUND_ID" -gt 0 ]; then
    [ "$MIGRATION_QUARANTINE_FOUND_ID" -eq "$MIGRATION_QUARANTINE_GROUP_ID" ] || return 1
    gh_api_request DELETE \
      "/orgs/$GH_OWNER/actions/runner-groups/$MIGRATION_QUARANTINE_GROUP_ID" || return 1
    [ "$GH_STATUS" = 204 ] || [ "$GH_STATUS" = 404 ] || return 1
  fi
  migration_quarantine_group_find "$MIGRATION_QUARANTINE_GROUP_NAME" || return 1
  [ "$MIGRATION_QUARANTINE_FOUND_ID" -eq 0 ] ||
    { err "classic quarantine group cleanup was not confirmed"; return 1; }
  rm -f "$MIGRATION_CLASSIC_QUARANTINE_STATE"
}

migration_classic_quiesce() {
  local runner busy=0
  mkdir -p "$(dirname "$MIGRATION_CLASSIC_QUIESCE_FILE")" || return 1
  ( umask 077; printf 'transition_id=%s\nconfig_revision=%s\n' \
    "$MIGRATION_TRANSITION_ID" "$MIGRATION_TARGET_CONFIG_REVISION" \
    >"$MIGRATION_CLASSIC_QUIESCE_FILE" ) || return 1
  chmod 0600 "$MIGRATION_CLASSIC_QUIESCE_FILE" || return 1
  fleet_inventory_refresh || { err "could not inventory classic runners during quiesce"; return 1; }
  migration_quarantine_move_all || return 1
  github_phase_refresh || { err "could not prove classic runner phases during quiesce"; return 1; }
  for runner in $(managed_names); do
    [ -n "$runner" ] || continue
    case "$(runner_state "$runner")" in
      idle)
        remove_runner "$runner" ||
          { err "GitHub did not confirm safe retirement of idle classic runner $runner"; return 1; }
        ;;
      busy|starting|error) busy=$((busy + 1)) ;;
    esac
  done
  fleet_inventory_refresh || return 1
  if [ "$(current_count)" -ne 0 ] || [ "$busy" -ne 0 ]; then
    err "classic quiesce is waiting for $busy assigned, busy, or uncertain runner(s)"
    return 1
  fi
}

migration_classic_prove_ineligible() {
  local target name prefix inventory
  [ -f "$MIGRATION_CLASSIC_QUIESCE_FILE" ] || return 1
  fleet_inventory_refresh && [ "$(current_count)" -eq 0 ] ||
    { err "classic containers remain after quiesce"; return 1; }
  target="org:$GH_OWNER"
  prefix="$(host)-${NAME_PREFIX}-"
  inventory="$(github_runner_inventory "$target")" ||
    { err "could not verify classic GitHub runner registrations"; return 1; }
  while IFS='|' read -r _ name _; do
    [ -n "$name" ] || continue
    case "$name" in "$prefix"*|"${NAME_PREFIX}-"*)
      err "classic GitHub runner registration remains: $name"
      return 1
      ;;
    esac
  done <<<"$inventory"
  local quarantine_inventory
  if [ -e "$MIGRATION_CLASSIC_QUARANTINE_STATE" ]; then
    migration_quarantine_state_load || return 1
    quarantine_inventory="$(mktemp "$RUNDIR/classic-quarantine-proof.XXXXXX")" || return 1
    migration_quarantine_group_inventory "$MIGRATION_QUARANTINE_GROUP_ID" "$quarantine_inventory" ||
      { rm -f "$quarantine_inventory"; return 1; }
    [ ! -s "$quarantine_inventory" ] ||
      { rm -f "$quarantine_inventory"; err "classic quarantine group still contains runners"; return 1; }
    rm -f "$quarantine_inventory"
    migration_quarantine_delete || return 1
  fi
}

migration_classic_activate() {
  if [ -e "$MIGRATION_CLASSIC_QUARANTINE_STATE" ] ||
    [ -e "$MIGRATION_CLASSIC_QUIESCE_FILE" ]; then
    migration_classic_quiesce || return 1
    migration_classic_prove_ineligible || return 1
  fi
  rm -f "$MIGRATION_CLASSIC_QUIESCE_FILE"
  # REVIEW(crf-v3q.13.19): cmd_start normally follows the effective backend.
  # This dynamically scoped capability authorizes only the exact rollback FSM
  # state whose remote scale sets are ineligible and whose JIT work is drained.
  MIGRATION_CLASSIC_ACTIVATION=1 cmd_start
}

migration_classic_prove_effective() {
  local runner count=0 phase
  [ ! -f "$MIGRATION_CLASSIC_QUIESCE_FILE" ] || return 1
  fleet_inventory_refresh || return 1
  github_phase_refresh || return 1
  for runner in $(managed_names); do
    [ -n "$runner" ] || continue
    phase="$(runner_state "$runner")"
    case "$phase" in busy|idle) count=$((count + 1)) ;; esac
  done
  [ "$count" -gt 0 ] ||
    { err "classic activation has no online runner"; return 1; }
}
migration_jit_drained() {
  local state phase reservation snapshot_ok
  # REVIEW(crf-v3q.13.17): Rollback needs proof across all three authorities:
  # durable JIT/reservation state, the fresh GitHub session snapshot, and the
  # managed Docker inventory. Unknown or ambiguous state always blocks.
  for state in "$JIT_STATE_DIR"/*.state; do
    [ -f "$state" ] || continue
    phase="$(jit_state_field "$state" phase)"
    [ "$phase" = deleted ] || {
      err "JIT operation ${state##*/} remains in phase ${phase:-unknown}"
      return 1
    }
  done
  scaleset_snapshot_refresh || {
    err "cannot prove JIT drain without a fresh scale-set snapshot"
    return 1
  }
  snapshot_ok="$(php -r '
    $j=json_decode(file_get_contents($argv[1]),true);$now=time();
    if(!is_array($j)||!is_array($j["pools"]??null)||count($j["pools"])===0)exit(2);
    foreach($j["pools"] as $p){
      $observed=strtotime((string)($p["observed_at"]??""));
      $valid=strtotime((string)($p["valid_until"]??""));
      if(($p["session_healthy"]??false)!==true||($p["assigned_jobs"]??-1)!==0||
        !is_array($p["acquired_handles"]??null)||count($p["acquired_handles"])!==0||
        $observed===false||$valid===false||$observed>$now+5||$valid<=$now||
        $valid-$observed>30)exit(3);
    }
    echo "yes";
  ' "$SCALESET_SNAPSHOT" 2>/dev/null)" || {
    err "assigned, pending, or stale GitHub scale-set work remains"
    return 1
  }
  [ "$snapshot_ok" = yes ] || return 1
  for reservation in "$RESERVATION_DIR"/*.state; do
    [ -f "$reservation" ] || continue
    phase="$(reservation_field "$reservation" phase)"
    if [ "$phase" = offered ]; then
      reservation_release "$(basename "$reservation" .state)" || return 1
      continue
    fi
    err "resource reservation ${reservation##*/} remains in phase ${phase:-unknown}"
    return 1
  done
  fleet_inventory_refresh || return 1
  if awk -F'|' '$12=="scaleset" && ($2=="running" || $2=="created"){found=1}
      END{exit !found}' "$INVENTORY_FILE"; then
    err "managed JIT containers remain after scale-set drain"
    return 1
  fi
}
