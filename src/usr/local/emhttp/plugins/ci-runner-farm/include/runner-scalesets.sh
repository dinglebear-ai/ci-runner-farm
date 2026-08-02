#!/bin/bash
# Scale-set helper lifecycle. The helper remains fail-closed until a fresh,
# packaged-identity-bound compatibility record exists.

SCALESET_HELPER="${SCALESET_HELPER:-$SCRIPT_DIR/../bin/crf-scaleset}"
SCALESET_STATE_DIR="${SCALESET_STATE_DIR:-$RUNDIR/scalesets}"
SCALESET_DURABLE_BOOTSTRAP_STATE_DIR="${SCALESET_DURABLE_BOOTSTRAP_STATE_DIR:-$CACHE_ROOT/state/scalesets}"
SCALESET_DURABLE_STATE_DIR_PINNED="${SCALESET_DURABLE_STATE_DIR+x}"
SCALESET_DURABLE_STATE_DIR_CONFIGURED="${SCALESET_DURABLE_STATE_DIR-}"
SCALESET_PID="${SCALESET_PID:-$SCALESET_STATE_DIR/supervisor.pid}"
SCALESET_SOCKET="${SCALESET_SOCKET:-$SCALESET_STATE_DIR/supervisor.sock}"
SCALESET_COMPAT="${SCALESET_COMPAT:-$CFGDIR/scaleset-compatibility.json}"
SCALESET_RUNTIME_CONFIG="${SCALESET_RUNTIME_CONFIG:-$SCALESET_STATE_DIR/runtime-config.json}"
SCALESET_OWNERSHIP="${SCALESET_OWNERSHIP:-$CFGDIR/scale-set-ownership.json}"
SCALESET_INSTALLATION_FILE="${SCALESET_INSTALLATION_FILE:-$CFGDIR/installation-id}"
SCALESET_SNAPSHOT="${SCALESET_SNAPSHOT:-$SCALESET_STATE_DIR/snapshot.json}"
SCALESET_PROBE_CONFIG="${SCALESET_PROBE_CONFIG:-$SCALESET_STATE_DIR/probe-config.json}"
SCALESET_WORKLOAD_EVIDENCE="${SCALESET_WORKLOAD_EVIDENCE:-$CFGDIR/scaleset-workload-evidence.json}"
SCALESET_QUARANTINE_STATE="${SCALESET_QUARANTINE_STATE:-$CFGDIR/scaleset-quarantine.json}"
GITHUB_APP_TOKEN_FILE="${GITHUB_APP_TOKEN_FILE:-$SCALESET_STATE_DIR/github-app-installation.token}"
SCALESET_HELPER_LOG_MAX_BYTES="${SCALESET_HELPER_LOG_MAX_BYTES:-8388608}"
SCALESET_OPERATION_MAX_FILES="${SCALESET_OPERATION_MAX_FILES:-32}"
SCALESET_DEMAND_TTL_MAX_SECONDS="${SCALESET_DEMAND_TTL_MAX_SECONDS:-120}"
SCALESET_QUARANTINE_GROUP_NAME=""
SCALESET_QUARANTINE_GROUP_ID=0
SCALESET_QUARANTINE_PHASE=""
SCALESET_QUARANTINE_FOUND_ID=0
SCALESET_PRODUCTION_GROUP_ID=0

scaleset_paths_refresh() {
  if [ "$SCALESET_DURABLE_STATE_DIR_PINNED" = x ]; then
    SCALESET_DURABLE_STATE_DIR="$SCALESET_DURABLE_STATE_DIR_CONFIGURED"
  else
    SCALESET_DURABLE_STATE_DIR="$CACHE_ROOT/state/scalesets"
  fi
}

scaleset_paths_refresh

scaleset_import_bootstrap_durable_state() {
  local source="$SCALESET_DURABLE_BOOTSTRAP_STATE_DIR" target="$SCALESET_DURABLE_STATE_DIR" backup
  [ "$source" != "$target" ] || return 0
  [ -d "$source" ] || return 0
  find "$source" -mindepth 1 -print -quit 2>/dev/null | grep -q . || return 0
  mkdir -p "$target" && chmod 0700 "$target" || return 1
  if find "$target" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    err "refusing to merge legacy and configured scale-set durable state"
    return 1
  fi
  cp -a -- "$source/." "$target/" || return 1
  find "$target" -type d -exec chmod 0700 {} + 2>/dev/null || true
  find "$target" -type f -exec chmod 0600 {} + 2>/dev/null || true
  backup="$source.migrated-$(date -u +%Y%m%dT%H%M%SZ)"
  mv -- "$source" "$backup" || return 1
  log "migrated scale-set durable state to $target"
}

scaleset_plugin_digest() {
  local root="${SCALESET_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  (
    cd "$root" || exit
    # The active helper is independently pinned by helper_digest. Emergency
    # rollback copies must live on cache, but ignore the historical hidden
    # filename if an older deployment left one inside bin.
    find . -type f ! -path './bin/.crf-scaleset.rollback-*' -print0 |
      LC_ALL=C sort -z | xargs -0 sha256sum
  ) | sha256sum | cut -d' ' -f1
}

scaleset_image_digest() {
  local ref="${BUILTIN_IMAGE:-ci-runner-farm-runner:latest}" value
  if declare -F image_ref >/dev/null; then ref="$(image_ref)"; fi
  value="$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null)" || return 1
  value="${value#sha256:}"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$value"
}

scaleset_bound_identity() {
  local plugin image dockerfile entrypoint installation host_id
  plugin="$(scaleset_plugin_digest)" || return 1
  image="$(scaleset_image_digest)" || return 1
  dockerfile="$(sha256sum "$CFGDIR/Dockerfile" 2>/dev/null | cut -d' ' -f1)" || return 1
  entrypoint="$(sha256sum "$SCRIPT_DIR/runner-entrypoint.sh" 2>/dev/null | cut -d' ' -f1)" || return 1
  installation="$(scaleset_installation_id)" || return 1
  host_id="$(sha256sum /etc/machine-id 2>/dev/null | cut -d' ' -f1)" || return 1
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$plugin" "$image" "$dockerfile" "$entrypoint" "$GH_OWNER" "$installation" "$host_id"
}

scaleset_record_identity_matches() {
  local identity="$1"
  php -r '
    $j=json_decode(file_get_contents($argv[1]),true);$v=explode("|",$argv[2]);
    if(!is_array($j)||count($v)!==7)exit(2);
    $keys=["plugin_digest","image_digest","dockerfile_digest","entrypoint_digest",
      "owner","installation_id","host_id"];
    foreach($keys as $i=>$key)if(!hash_equals((string)($j[$key]??""),(string)$v[$i]))exit(3);
  ' "$SCALESET_COMPAT" "$identity"
}

scaleset_record_fresh() {
  [ "$(scaleset_record_reason)" = valid ]
}

scaleset_record_valid() {
  [ "$(scaleset_record_reason)" = valid ]
}

scaleset_record_reason() {
  local output reason identity
  [ -f "$SCALESET_COMPAT" ] || { printf 'compatibility_record_missing\n'; return; }
  [ ! -L "$SCALESET_COMPAT" ] || { printf 'compatibility_record_symlink\n'; return; }
  [ -x "$SCALESET_HELPER" ] || { printf 'helper_unavailable\n'; return; }
  if output="$("$SCALESET_HELPER" check-compatibility --path "$SCALESET_COMPAT" 2>/dev/null)"; then
    identity="$(scaleset_bound_identity 2>/dev/null)" ||
      { printf 'bound_identity_unavailable\n'; return; }
    scaleset_record_identity_matches "$identity" ||
      { printf 'bound_identity_mismatch\n'; return; }
    printf 'valid\n'; return
  fi
  reason="$(printf '%s' "$output" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $v=is_array($j)?($j["error"]??""):"";
    echo is_string($v)&&preg_match("/^[A-Za-z0-9_.:-]{1,128}$/",$v)?$v:"invalid_compatibility_record";
  ' 2>/dev/null)" || reason=invalid_compatibility_record
  printf '%s\n' "${reason:-invalid_compatibility_record}"
}

scaleset_quarantine_identity() {
  local installation suffix
  [ "${GH_SCOPE:-}" = org ] && [ -n "${GH_OWNER:-}" ] || return 1
  installation="$(scaleset_installation_id)" || return 1
  suffix="$(printf '%s' "$GH_OWNER|$installation|scaleset" | sha256sum | cut -c1-16)"
  SCALESET_QUARANTINE_GROUP_NAME="crf-scaleset-quarantine-$suffix"
}

scaleset_quarantine_state_load() {
  local values _owner _installation
  [ -f "$SCALESET_QUARANTINE_STATE" ] && [ ! -L "$SCALESET_QUARANTINE_STATE" ] &&
    [ "$(stat -c %a "$SCALESET_QUARANTINE_STATE" 2>/dev/null)" = 600 ] &&
    [ "$(stat -c %s "$SCALESET_QUARANTINE_STATE" 2>/dev/null)" -le 16384 ] || return 1
  values="$(php -r '
    $j=json_decode(file_get_contents($argv[1]),true);
    $keys=["schema_version","owner","installation_id","group_name","group_id","phase"];
    if(!is_array($j)||array_keys($j)!==$keys||($j["schema_version"]??0)!==1||
      !is_string($j["owner"]??null)||!is_string($j["installation_id"]??null)||
      !is_string($j["group_name"]??null)||!is_int($j["group_id"]??null)||
      $j["group_id"]<0||!in_array($j["phase"]??null,["create_intent","active"],true))exit(2);
    foreach(["owner","installation_id","group_name","phase"] as $k)
      if(str_contains($j[$k],"|")||preg_match("/[\x00-\x1f]/",$j[$k]))exit(3);
    echo $j["owner"],"|",$j["installation_id"],"|",$j["group_name"],"|",
      $j["group_id"],"|",$j["phase"],"|";
  ' "$SCALESET_QUARANTINE_STATE" 2>/dev/null)" || return 1
  IFS='|' read -r _owner _installation SCALESET_QUARANTINE_GROUP_NAME \
    SCALESET_QUARANTINE_GROUP_ID SCALESET_QUARANTINE_PHASE _ <<<"$values"
  [ "$_owner" = "$GH_OWNER" ] &&
    [ "$_installation" = "$(scaleset_installation_id)" ] &&
    [[ "$SCALESET_QUARANTINE_GROUP_ID" =~ ^[0-9]+$ ]]
}

scaleset_quarantine_state_write() {
  local phase="$1" group_id="$2" installation tmp
  case "$phase" in create_intent|active) ;; *) return 1 ;; esac
  [[ "$group_id" =~ ^[0-9]+$ ]] || return 1
  [ "$phase" = create_intent ] || [ "$group_id" -gt 0 ] || return 1
  installation="$(scaleset_installation_id)" || return 1
  mkdir -p "$(dirname "$SCALESET_QUARANTINE_STATE")" || return 1
  tmp="$SCALESET_QUARANTINE_STATE.tmp.$$"
  php -r '
    $j=["schema_version"=>1,"owner"=>$argv[2],"installation_id"=>$argv[3],
      "group_name"=>$argv[4],"group_id"=>(int)$argv[5],"phase"=>$argv[6]];
    $h=fopen($argv[1],"xb");if(!$h)exit(2);
    if(fwrite($h,json_encode($j,JSON_UNESCAPED_SLASHES)."\n")===false||!fflush($h))exit(3);
    if(function_exists("fsync")&&!fsync($h))exit(4);
    fclose($h);
  ' "$tmp" "$GH_OWNER" "$installation" "$SCALESET_QUARANTINE_GROUP_NAME" \
    "$group_id" "$phase" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f "$tmp" "$SCALESET_QUARANTINE_STATE" ||
    { rm -f "$tmp"; return 1; }
  scaleset_quarantine_state_load
}

scaleset_quarantine_group_find() {
  local name="$1" page=1 parsed count found
  SCALESET_QUARANTINE_FOUND_ID=0
  while [ "$page" -le 100 ]; do
    gh_api_request GET "/orgs/$GH_OWNER/actions/runner-groups?per_page=100&page=$page" ||
      return 1
    parsed="$(printf '%s' "$GH_RESPONSE" | php -r '
      $j=json_decode(stream_get_contents(STDIN),true);
      if(!is_array($j)||!is_array($j["runner_groups"]??null))exit(2);
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
    if [ "$found" -gt 0 ]; then SCALESET_QUARANTINE_FOUND_ID="$found"; return 0; fi
    [ "$count" -lt 100 ] && return 0
    page=$((page + 1))
  done
  return 1
}

scaleset_production_group_policy_prove() {
  local page=1 parsed count found
  SCALESET_PRODUCTION_GROUP_ID=0
  while [ "$page" -le 100 ]; do
    gh_api_request GET "/orgs/$GH_OWNER/actions/runner-groups?per_page=100&page=$page" ||
      return 1
    parsed="$(printf '%s' "$GH_RESPONSE" | php -r '
      $j=json_decode(stream_get_contents(STDIN),true);
      if(!is_array($j)||!is_array($j["runner_groups"]??null))exit(2);
      $found=[];
      foreach($j["runner_groups"] as $g)if(($g["name"]??null)===$argv[1])$found[]=$g;
      if(count($found)>1)exit(3);
      $id=0;
      if(count($found)===1){
        $g=$found[0];
        if(!is_int($g["id"]??null)||$g["id"]<=0||
          ($g["visibility"]??"")!=="selected"||
          !is_bool($g["allows_public_repositories"]??null))exit(4);
        $id=$g["id"];
      }
      echo count($j["runner_groups"]),"|",$id;
    ' "$RUNNER_GROUP" 2>/dev/null)" || return 1
    IFS='|' read -r count found <<<"$parsed"
    [[ "$count" =~ ^[0-9]+$ ]] && [[ "$found" =~ ^[0-9]+$ ]] || return 1
    if [ "$found" -gt 0 ]; then
      SCALESET_PRODUCTION_GROUP_ID="$found"
      return 0
    fi
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  err "runner group $RUNNER_GROUP must use selected visibility"
  return 1
}

scaleset_quarantine_prove_no_repositories() {
  local id="$1"
  gh_api_request GET "/orgs/$GH_OWNER/actions/runner-groups/$id/repositories?per_page=1&page=1" ||
    return 1
  printf '%s' "$GH_RESPONSE" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    if(!is_array($j)||($j["total_count"]??null)!==0||
      !is_array($j["repositories"]??null)||count($j["repositories"])!==0)exit(2);
  '
}

scaleset_quarantine_ensure() {
  local expected_name body
  scaleset_quarantine_identity || return 1
  expected_name="$SCALESET_QUARANTINE_GROUP_NAME"
  if [ -e "$SCALESET_QUARANTINE_STATE" ]; then
    scaleset_quarantine_state_load ||
      { err "scale-set quarantine ownership state is invalid"; return 1; }
    [ "$SCALESET_QUARANTINE_GROUP_NAME" = "$expected_name" ] ||
      { err "scale-set quarantine ownership identity changed"; return 1; }
  else
    scaleset_quarantine_group_find "$expected_name" || return 1
    [ "$SCALESET_QUARANTINE_FOUND_ID" -eq 0 ] ||
      { err "refusing to adopt unowned scale-set quarantine group"; return 1; }
    SCALESET_QUARANTINE_GROUP_NAME="$expected_name"
    scaleset_quarantine_state_write create_intent 0 || return 1
  fi
  if [ "$SCALESET_QUARANTINE_PHASE" = create_intent ]; then
    scaleset_quarantine_group_find "$SCALESET_QUARANTINE_GROUP_NAME" || return 1
    if [ "$SCALESET_QUARANTINE_FOUND_ID" -eq 0 ]; then
      body="$(php -r 'echo json_encode(["name"=>$argv[1],"visibility"=>"selected",
        "allows_public_repositories"=>false],JSON_UNESCAPED_SLASHES);' \
        "$SCALESET_QUARANTINE_GROUP_NAME")" || return 1
      gh_api_request POST "/orgs/$GH_OWNER/actions/runner-groups" "$body" || true
      scaleset_quarantine_group_find "$SCALESET_QUARANTINE_GROUP_NAME" || return 1
    fi
    [ "$SCALESET_QUARANTINE_FOUND_ID" -gt 0 ] ||
      { err "GitHub did not create the scale-set quarantine group"; return 1; }
    scaleset_quarantine_state_write active "$SCALESET_QUARANTINE_FOUND_ID" || return 1
  fi
  [ "$SCALESET_QUARANTINE_PHASE" = active ] || return 1
  scaleset_quarantine_group_find "$SCALESET_QUARANTINE_GROUP_NAME" || return 1
  [ "$SCALESET_QUARANTINE_FOUND_ID" -eq "$SCALESET_QUARANTINE_GROUP_ID" ] ||
    { err "owned scale-set quarantine group is missing or changed"; return 1; }
  scaleset_quarantine_prove_no_repositories "$SCALESET_QUARANTINE_GROUP_ID" ||
    { err "scale-set quarantine group is routable to repositories"; return 1; }
}

scaleset_probe_config_write() {
  local identity plugin image dockerfile entrypoint owner installation host_id tmp
  [ "${GH_SCOPE:-}" = org ] && [ -n "${GH_OWNER:-}" ] && [ -n "${RUNNER_GROUP:-}" ] ||
    { err "compatibility testing requires organization scope and a restricted runner group"; return 1; }
  [ -f "$SCALESET_WORKLOAD_EVIDENCE" ] && [ ! -L "$SCALESET_WORKLOAD_EVIDENCE" ] &&
    [ "$(stat -c %a "$SCALESET_WORKLOAD_EVIDENCE" 2>/dev/null)" = 600 ] ||
    { err "fresh mode-0600 workload evidence is required"; return 1; }
  identity="$(scaleset_bound_identity)" || { err "could not resolve packaged identity"; return 1; }
  IFS='|' read -r plugin image dockerfile entrypoint owner installation host_id <<<"$identity"
  [ "$owner" = "$GH_OWNER" ] || return 1
  # REVIEW(crf-v3q.13.2, MUST-CHECK): Resolve the production group through the
  # GitHub REST policy surface immediately before the probe, prove selected
  # repository visibility, then bind that ID into the mode-0600 probe config.
  # Public-repository permission is an explicit GitHub policy for the selected
  # production repositories; quarantine groups remain deny-public and empty.
  scaleset_production_group_policy_prove ||
    { err "production runner-group policy is not restricted"; return 1; }
  scaleset_quarantine_ensure ||
    { err "could not establish the scale-set quarantine runner group"; return 1; }
  mkdir -p "$SCALESET_STATE_DIR" && chmod 0700 "$SCALESET_STATE_DIR" || return 1
  tmp="$SCALESET_PROBE_CONFIG.tmp.$$"
  php -r '
    $e=json_decode(file_get_contents($argv[1]),true);
    $required=["total_assigned_jobs","zero_to_one","cancel_reassign","ack_replay",
      "nested_cgroup_charging","classic_quarantine_barrier"];
    if(!is_array($e)||($e["schema_version"]??0)!==1||($e["owner"]??"")!==$argv[2]||
      ($e["runner_group_name"]??"")!==$argv[3]||
      ($e["runner_group_policy"]??"")!=="selected_repositories"||
      !is_int($e["observed_at"]??null)||$e["observed_at"]>time()+300||
      time()-$e["observed_at"]>86400)exit(2);
    foreach($required as $key)if(($e["workload"][$key]??false)!==true)exit(3);
    $auth=["mode"=>$argv[12]];
    if($argv[12]==="pat")$auth["token_file"]=$argv[13];
    else{$auth["app_client_id"]=$argv[14];$auth["installation_id"]=(int)$argv[15];
      $auth["private_key_file"]=$argv[16];}
    $runtime=["owner"=>$argv[2],"github_config_url"=>"https://github.com/".$argv[2],"auth"=>$auth];
    $live=["owner"=>$argv[2],"runner_group_name"=>$argv[3],
      "runner_group_id"=>(int)$argv[18],
      "quarantine_runner_group_name"=>$argv[17],
      "runner_group_policy"=>"selected_repositories","installation_id"=>$argv[4],
      "host_id"=>$argv[5],"plugin_digest"=>$argv[6],"helper_digest"=>str_repeat("0",64),
      "module_revision"=>"pending","go_version"=>"pending","image_digest"=>$argv[7],
      "dockerfile_digest"=>$argv[8],"entrypoint_digest"=>$argv[9],"workload"=>$e["workload"]];
    file_put_contents($argv[11],json_encode(["runtime"=>$runtime,"live"=>$live],
      JSON_UNESCAPED_SLASHES)."\n");
  ' "$SCALESET_WORKLOAD_EVIDENCE" "$GH_OWNER" "$RUNNER_GROUP" "$installation" "$host_id" \
    "$plugin" "$image" "$dockerfile" "$entrypoint" "$SCALESET_COMPAT" "$tmp" \
    "$AUTH_MODE" "$TOKEN_FILE" "${GITHUB_APP_ID:-}" "${GITHUB_APP_INSTALLATION_ID:-0}" \
    "$GITHUB_APP_KEY_FILE" "$SCALESET_QUARANTINE_GROUP_NAME" "$SCALESET_PRODUCTION_GROUP_ID" ||
    { rm -f "$tmp"; err "workload evidence is stale, incomplete, or identity-mismatched"; return 1; }
  chmod 0600 "$tmp" && mv "$tmp" "$SCALESET_PROBE_CONFIG"
}

scaleset_supervisor_start() {
  local helper_log="$SCALESET_STATE_DIR/supervisor.log" response reason
  [ -x "$SCALESET_HELPER" ] || { err "scale-set helper is unavailable"; return 1; }
  scaleset_record_valid || { err "scale-set compatibility evidence is missing, stale, incomplete, or mismatched"; return 1; }
  mkdir -p "$SCALESET_STATE_DIR" && chmod 0700 "$SCALESET_STATE_DIR" || return 1
  if [ -f "$SCALESET_PID" ] && kill -0 "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null; then return 0; fi
  scaleset_import_bootstrap_durable_state ||
    { err "could not migrate scale-set durable state to the configured cache root"; return 1; }
  if [ -f "$helper_log" ] &&
    [ "$(stat -c %s "$helper_log" 2>/dev/null || echo 0)" -ge "$SCALESET_HELPER_LOG_MAX_BYTES" ]; then
    mv "$helper_log" "$helper_log.1" || return 1
    chmod 0600 "$helper_log.1" || return 1
  fi
  scaleset_runtime_config_write || { err "could not write scale-set runtime configuration"; return 1; }
  # Start/Restart invokes this while fd 8 owns the fleet lock. The detached
  # supervisor must not inherit that descriptor or it will hold the mutation
  # lock forever after the parent command exits.
  nohup "$SCALESET_HELPER" supervise --socket "$SCALESET_SOCKET" --compatibility "$SCALESET_COMPAT" \
    --runtime-config "$SCALESET_RUNTIME_CONFIG" \
    8>&- 7>&- 9>&- >>"$helper_log" 2>&1 &
  printf '%s\n' "$!" > "$SCALESET_PID"
  chmod 0600 "$SCALESET_PID"
  local i
  for i in $(seq 1 100); do
    if [ -S "$SCALESET_SOCKET" ]; then
      local eligible=false
      if declare -F migration_load >/dev/null && migration_load &&
        [ "$MIGRATION_EFFECTIVE_BACKEND:$MIGRATION_PHASE" = scaleset:scaleset_active ]; then
        eligible=true
      fi
      if ! response="$(scaleset_request apply_sessions "{\"eligible\":$eligible}")"; then
        reason="$(printf '%s' "$response" | php -r '
          $j=json_decode(stream_get_contents(STDIN),true);
          $code=is_array($j)?($j["code"]??""):"";$error=is_array($j)?($j["error"]??""):"";
          foreach([$code,$error] as $v)if(is_string($v)&&preg_match("/^[A-Za-z0-9_.: -]{1,256}$/",$v))echo $v," ";
        ' 2>/dev/null)" || reason=""
        err "scale-set supervisor could not restore message sessions${reason:+: $reason}"
        scaleset_supervisor_stop
        return 1
      fi
      return 0
    fi
    kill -0 "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null || break
    sleep 0.1
  done
  err "scale-set supervisor did not create its control socket"
  scaleset_supervisor_stop
  return 1
}

scaleset_supervisor_stop() {
  local pid="" i
  [ -f "$SCALESET_PID" ] && pid="$(cat "$SCALESET_PID" 2>/dev/null)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$SCALESET_PID" "$SCALESET_SOCKET"
}

scaleset_credentials_invalidate() {
  scaleset_supervisor_stop
  rm -f "$GITHUB_APP_TOKEN_FILE" "$SCALESET_STATE_DIR"/session.* "$SCALESET_STATE_DIR"/snapshot.* 2>/dev/null || true
}

github_app_token_store() {
  local token="$1" expires="$2" tmp
  [ -n "$token" ] && [[ "$expires" =~ ^[0-9]+$ ]] || return 1
  mkdir -p "$SCALESET_STATE_DIR" && chmod 0700 "$SCALESET_STATE_DIR" || return 1
  tmp="$GITHUB_APP_TOKEN_FILE.tmp.$$"
  ( umask 077; printf 'expires=%s\ntoken=%s\n' "$expires" "$token" >"$tmp" ) &&
    chmod 0600 "$tmp" && mv "$tmp" "$GITHUB_APP_TOKEN_FILE"
}

scaleset_operation_id_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

scaleset_operation_write() {
  local id="$1" state="$2" code="$3" message="$4" dir="$SCALESET_STATE_DIR/operations" tmp
  scaleset_operation_id_valid "$id" || return 1
  case "$state" in running|passed|failed) ;; *) return 1 ;; esac
  [ "${#message}" -le 4096 ] || message="${message:0:4096}"
  mkdir -p "$dir" && chmod 0700 "$SCALESET_STATE_DIR" "$dir" || return 1
  find "$dir" -maxdepth 1 -type f -name '*.json' -mtime +1 -delete 2>/dev/null || true
  find "$dir" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | awk -v keep="$SCALESET_OPERATION_MAX_FILES" 'NR>keep{sub(/^[^ ]+ /,"");print}' |
    xargs -r rm -f --
  tmp="$dir/$id.json.tmp.$$"
  php -r '$j=["schema_version"=>1,"operation_id"=>$argv[2],"kind"=>"compatibility_test",
    "state"=>$argv[3],"code"=>$argv[4],"message"=>$argv[5],"updated_at"=>gmdate("c")];
    file_put_contents($argv[1],json_encode($j,JSON_UNESCAPED_SLASHES)."\n");' \
    "$tmp" "$id" "$state" "$code" "$message" &&
    chmod 0600 "$tmp" && mv "$tmp" "$dir/$id.json"
}

scaleset_compatibility_start() {
  local id
  id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || return 1
  scaleset_operation_write "$id" running started "Compatibility test started." || return 1
  nohup "$0" compatibility-worker "$id" >/dev/null 2>&1 &
  printf '{"ok":true,"operation_id":"%s"}\n' "$id"
}

scaleset_compatibility_worker() {
  local id="$1" output rc=0
  scaleset_operation_id_valid "$id" || return 1
  if ! scaleset_probe_config_write; then
    scaleset_operation_write "$id" failed evidence_invalid \
      "Compatibility gate requires fresh, complete live workload evidence for this owner and restricted runner group."
    return
  fi
  if output="$("$SCALESET_HELPER" probe --config "$SCALESET_PROBE_CONFIG" \
    --output "$SCALESET_COMPAT" --timeout 10m 2>&1)"; then
    scaleset_operation_write "$id" passed compatible "Packaged compatibility gate passed."
  else
    rc=$?
    # The helper returns structured JSON; do not reflect unbounded/raw command
    # output into the UI operation record.
    scaleset_operation_write "$id" failed probe_failed \
      "Compatibility gate did not pass (helper exit $rc). Configure disposable restricted probe inputs and retry."
  fi
}

scaleset_operation_status() {
  local id="$1" path
  path="$SCALESET_STATE_DIR/operations/$id.json"
  scaleset_operation_id_valid "$id" && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cat "$path"
}

scaleset_supervisor_status() {
  if [ -f "$SCALESET_PID" ] && kill -0 "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null; then
    printf 'running\n'
  else printf 'stopped\n'; fi
}

scaleset_installation_id() {
  local value tmp
  if [ -n "${SCALESET_INSTALLATION_ID:-}" ]; then
    value="$SCALESET_INSTALLATION_ID"
  elif [ -f "$SCALESET_INSTALLATION_FILE" ] && [ ! -L "$SCALESET_INSTALLATION_FILE" ]; then
    value="$(cat "$SCALESET_INSTALLATION_FILE" 2>/dev/null)"
  else
    value="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || return 1
    mkdir -p "$(dirname "$SCALESET_INSTALLATION_FILE")" || return 1
    tmp="$SCALESET_INSTALLATION_FILE.tmp.$$"
    ( umask 077; printf '%s\n' "$value" >"$tmp" ) &&
      chmod 0600 "$tmp" && mv "$tmp" "$SCALESET_INSTALLATION_FILE" || return 1
  fi
  [[ "$value" =~ ^[0-9a-fA-F-]{16,64}$ ]] || return 1
  printf '%s\n' "$value"
}

scaleset_ownership_revision() {
  local group_ids production_group_id quarantine_group_id installation host_id
  group_ids="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);
    echo (int)($j["runner_group_id"]??0),"|",(int)($j["quarantine_runner_group_id"]??0);' \
    "$SCALESET_COMPAT" 2>/dev/null)" || return 1
  IFS='|' read -r production_group_id quarantine_group_id <<<"$group_ids"
  [ "$production_group_id" -gt 0 ] && [ "$quarantine_group_id" -gt 0 ] &&
    [ "$production_group_id" -ne "$quarantine_group_id" ] || return 1
  installation="$(scaleset_installation_id)" || return 1
  host_id="$(sha256sum /etc/machine-id 2>/dev/null | cut -d' ' -f1)"
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s' "$GH_OWNER" "$AUTH_MODE" \
    "${GITHUB_APP_INSTALLATION_ID:-pat}" "$production_group_id" \
    "$quarantine_group_id" "$installation" "$host_id" |
    sha256sum | cut -d' ' -f1
}

scaleset_runtime_config_write() {
  local config_rev ownership_rev installation group_ids group_id quarantine_group_id controller host_id pools tmp rec pool route labels
  local identity plugin image dockerfile entrypoint _owner _installation _host
  [ "${GH_SCOPE:-}" = org ] || { err "scale sets require organization scope"; return 1; }
  pool_snapshot_load && pool_is_v2 || { err "scale sets require V2 runner pools"; return 1; }
  config_rev="$(config_revision)" || return 1
  ownership_rev="$(scaleset_ownership_revision)" || return 1
  installation="$(scaleset_installation_id)" || return 1
  group_ids="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);
    echo (int)($j["runner_group_id"]??0),"|",(int)($j["quarantine_runner_group_id"]??0);' \
    "$SCALESET_COMPAT" 2>/dev/null)" || return 1
  IFS='|' read -r group_id quarantine_group_id <<<"$group_ids"
  [ "$group_id" -gt 0 ] && [ "$quarantine_group_id" -gt 0 ] &&
    [ "$group_id" -ne "$quarantine_group_id" ] || return 1
  controller="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || return 1
  controller="crf-$controller"
  host_id="$(sha256sum /etc/machine-id 2>/dev/null | cut -d' ' -f1)"
  identity="$(scaleset_bound_identity)" || return 1
  IFS='|' read -r plugin image dockerfile entrypoint _owner _installation _host <<<"$identity"
  [ "$_owner:$_installation:$_host" = "$GH_OWNER:$installation:$host_id" ] || return 1
  mkdir -p "$SCALESET_STATE_DIR" && chmod 0700 "$SCALESET_STATE_DIR" || return 1
  mkdir -p "$SCALESET_DURABLE_STATE_DIR" &&
    chmod 0700 "$SCALESET_DURABLE_STATE_DIR" || return 1
  pools="$SCALESET_STATE_DIR/runtime-pools.$$.tsv"
  : >"$pools" || return 1
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    pool="${rec%%|*}"
    route="$(pool_routing_label "$pool")" || { rm -f "$pools"; return 1; }
    # Scale-set capacity is matched by every label attached to the set. Keep
    # the universal self-hosted/platform labels out of this list or legacy
    # `runs-on: self-hosted` work can enter every specialized pool. Workflows
    # target the unique routing label directly; classic runners support that
    # same selector, so the contract remains backend-independent.
    labels="$route"
    [ -z "$(pool_additional_labels "$pool")" ] ||
      labels="$labels,$(pool_additional_labels "$pool")"
    printf '%s|%s|%s\n' "$pool" "$route" "$labels" >>"$pools"
  done < <(pool_records)
  tmp="$SCALESET_RUNTIME_CONFIG.tmp.$$"
  php -r '
    $pools=[];
    foreach(file($argv[1],FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
      $parts=explode("|",$line);
      if(count($parts)!==3)exit(2);
      $labels=array_values(array_filter(explode(",",$parts[2]),fn($v)=>$v!==""));
      $pools[]=["id"=>$parts[0],"routing_label"=>$parts[1],"labels"=>$labels];
    }
    $auth=["mode"=>$argv[12]];
    if($argv[12]==="pat")$auth["token_file"]=$argv[13];
    else{
      $auth["app_client_id"]=$argv[14];
      $auth["installation_id"]=(int)$argv[15];
      $auth["private_key_file"]=$argv[16];
    }
    $j=["schema_version"=>1,"controller_instance_id"=>$argv[2],
      "config_revision"=>$argv[3],"ownership_revision"=>$argv[4],
      "installation_id"=>$argv[5],"owner"=>$argv[6],
      "github_config_url"=>"https://github.com/".$argv[6],
      "runner_group_id"=>(int)$argv[7],
      "quarantine_runner_group_id"=>(int)$argv[21],"state_dir"=>$argv[22],
      "ownership_path"=>$argv[9],"heartbeat_seconds"=>10,
      "host_id"=>$argv[10],"plugin_digest"=>$argv[17],"image_digest"=>$argv[18],
      "dockerfile_digest"=>$argv[19],"entrypoint_digest"=>$argv[20],
      "auth"=>$auth,"pools"=>$pools];
    file_put_contents($argv[11],json_encode($j,JSON_UNESCAPED_SLASHES)."\n");
  ' "$pools" "$controller" "$config_rev" "$ownership_rev" "$installation" "$GH_OWNER" \
    "$group_id" "$SCALESET_STATE_DIR" "$SCALESET_OWNERSHIP" "$host_id" "$tmp" \
    "$AUTH_MODE" "$TOKEN_FILE" "${GITHUB_APP_ID:-}" "${GITHUB_APP_INSTALLATION_ID:-0}" \
    "$GITHUB_APP_KEY_FILE" "$plugin" "$image" "$dockerfile" "$entrypoint" \
    "$quarantine_group_id" "$SCALESET_DURABLE_STATE_DIR" ||
    { rm -f "$pools" "$tmp"; return 1; }
  rm -f "$pools"
  chmod 0600 "$tmp" && mv "$tmp" "$SCALESET_RUNTIME_CONFIG"
}

_scaleset_request_locked() {
  local operation="$1" payload="${2-}" sequence request_id controller config_rev ownership_rev
  local seq_file seq_tmp output request_timeout="${SCALESET_REQUEST_IO_TIMEOUT_SECONDS:-20}"
  [[ "$request_timeout" =~ ^[1-9][0-9]*$ ]] && [ "$request_timeout" -le 120 ] || return 1
  [ -n "$payload" ] || payload='{}'
  [ -S "$SCALESET_SOCKET" ] && [ -f "$SCALESET_RUNTIME_CONFIG" ] || return 1
  controller="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);echo $j["controller_instance_id"]??"";' \
    "$SCALESET_RUNTIME_CONFIG" 2>/dev/null)" || return 1
  config_rev="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);echo $j["config_revision"]??"";' \
    "$SCALESET_RUNTIME_CONFIG" 2>/dev/null)" || return 1
  ownership_rev="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);echo $j["ownership_revision"]??"";' \
    "$SCALESET_RUNTIME_CONFIG" 2>/dev/null)" || return 1
  seq_file="$SCALESET_STATE_DIR/request.sequence"
  sequence="$(cat "$seq_file" 2>/dev/null || echo 0)"
  [[ "$sequence" =~ ^[0-9]+$ ]] || sequence=0
  sequence=$((sequence + 1))
  seq_tmp="$seq_file.tmp.$$"
  if ! ( umask 077; printf '%s\n' "$sequence" >"$seq_tmp" ) ||
     ! chmod 0600 "$seq_tmp" || ! mv "$seq_tmp" "$seq_file"; then
    rm -f "$seq_tmp"
    return 1
  fi
  request_id="request-$sequence"
  output="$(php -r '
    $payload=json_decode($argv[7],true);
    if(!is_array($payload))exit(2);
    echo json_encode(["schema_version"=>1,"request_id"=>$argv[1],"operation"=>$argv[2],
      "config_revision"=>$argv[3],"ownership_revision"=>$argv[4],
      "controller_instance_id"=>$argv[5],"sequence"=>(int)$argv[6],"payload"=>$payload],
      JSON_UNESCAPED_SLASHES),"\n";
  ' "$request_id" "$operation" "$config_rev" "$ownership_rev" "$controller" "$sequence" "$payload")" ||
    return 1
  command -v timeout >/dev/null 2>&1 || return 1
  printf '%s' "$output" | timeout --foreground --signal=TERM --kill-after=5s \
    "${request_timeout}s" "$SCALESET_HELPER" request --socket "$SCALESET_SOCKET" 6>&-
}

scaleset_request() {
  local lock_timeout="${SCALESET_REQUEST_LOCK_TIMEOUT_SECONDS:-35}"
  [[ "$lock_timeout" =~ ^[1-9][0-9]*$ ]] && [ "$lock_timeout" -le 120 ] || return 1
  mkdir -p "$SCALESET_STATE_DIR" && chmod 0700 "$SCALESET_STATE_DIR" || return 1
  (
    exec 6>"$SCALESET_STATE_DIR/request.lock" || exit 1
    chmod 0600 "$SCALESET_STATE_DIR/request.lock" || exit 1
    flock -w "$lock_timeout" 6 || exit 1
    _scaleset_request_locked "$@"
  )
}

scaleset_snapshot_refresh() {
  local output tmp
  output="$(scaleset_request read_snapshot '{}')" || return 1
  tmp="$SCALESET_SNAPSHOT.tmp.$$"
  printf '%s' "$output" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $s=$j["result"]??null;
    if(($j["ok"]??false)!==true||!is_array($s)||($s["schema_version"]??0)!==1||
      !is_array($s["pools"]??null))exit(2);
    file_put_contents($argv[1],json_encode($s,JSON_UNESCAPED_SLASHES)."\n");
  ' "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv "$tmp" "$SCALESET_SNAPSHOT"
}

scaleset_snapshot_tsv() {
  local max_ttl="$SCALESET_DEMAND_TTL_MAX_SECONDS"
  [[ "$max_ttl" =~ ^[1-9][0-9]*$ ]] && [ "$max_ttl" -le 300 ] || return 1
  php -r '
    $j=json_decode(file_get_contents($argv[1]),true);
    $max=(int)$argv[2];
    if(!is_array($j)||!is_array($j["pools"]??null)||$max<=0||$max>300)exit(2);
    $now=time();
    foreach($j["pools"] as $p){
      $id=$p["pool_id"]??"";$assigned=$p["assigned_jobs"]??-1;
      $healthy=($p["session_healthy"]??false)===true?1:0;
      $handles=$p["acquired_handles"]??[];
      $observed=strtotime((string)($p["observed_at"]??""));
      $valid=strtotime((string)($p["valid_until"]??""));
      $fresh=$observed!==false&&$valid!==false&&$observed<=$now+5&&
        $valid>$now&&$valid-$observed<=$max?1:0;
      if(!is_string($id)||!is_int($assigned)||$assigned<0||!is_array($handles))exit(3);
      foreach($handles as $h)if(!is_int($h)||$h<=0)exit(4);
      echo $id,"|",$assigned,"|",$healthy,"|",implode(",",$handles),"|",$fresh,"\n";
    }
  ' "$SCALESET_SNAPSHOT" "$max_ttl"
}

scaleset_publish_zero_capacity() {
  local pools payload
  pools="$(mktemp "$SCALESET_STATE_DIR/zero-capacity.XXXXXX")" || return 1
  trap 'rm -f "$pools"' RETURN
  while IFS= read -r rec; do
    [ -n "$rec" ] && printf '%s\n' "${rec%%|*}" >>"$pools"
  done < <(pool_records)
  payload="$(php -r '
    $leases=[];foreach(file($argv[1],FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $pool)
      $leases[$pool]=0;
    echo json_encode(["leases"=>$leases],JSON_UNESCAPED_SLASHES);
  ' "$pools")" || return 1
  scaleset_request publish_capacity_leases "$payload" >/dev/null
}

scaleset_activation_prove_effective() {
  local expected deadline="${SCALESET_ACTIVATION_TIMEOUT_SECONDS:-30}"
  [[ "$deadline" =~ ^[1-9][0-9]*$ ]] && [ "$deadline" -le 120 ] || return 1
  expected="$(mktemp "$SCALESET_STATE_DIR/activation-pools.XXXXXX")" || return 1
  trap 'rm -f "$expected"' RETURN
  while IFS= read -r rec; do
    [ -n "$rec" ] && printf '%s\n' "${rec%%|*}" >>"$expected"
  done < <(pool_records)
  deadline=$(( $(date +%s) + deadline ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if scaleset_snapshot_refresh && php -r '
      $j=json_decode(file_get_contents($argv[1]),true);
      $expected=array_values(array_filter(file($argv[2],FILE_IGNORE_NEW_LINES)));
      $now=time();$seen=[];$advertised=0;
      if(!is_array($j)||!is_array($j["pools"]??null))exit(2);
      foreach($j["pools"] as $p){
        $id=$p["pool_id"]??null;$observed=strtotime((string)($p["observed_at"]??""));
        $valid=strtotime((string)($p["valid_until"]??""));
        if(!is_string($id)||!in_array($id,$expected,true)||isset($seen[$id])||
          ($p["session_healthy"]??false)!==true||$observed===false||$valid===false||
          $observed>$now+5||$valid<=$now||$valid-$observed>30)exit(3);
        $capacity=$p["advertised_capacity"]??-1;
        if(!is_int($capacity)||$capacity<0)exit(4);
        $advertised+=$capacity;$seen[$id]=true;
      }
      if(count($seen)!==count($expected)||$advertised<1)exit(5);
    ' "$SCALESET_SNAPSHOT" "$expected"; then
      return 0
    fi
    sleep 1
  done
  err "scale-set activation is waiting for fresh healthy sessions and leased capacity"
  return 1
}

scaleset_reservation_count() {
  local pool="$1" phases="$2" file phase count=0
  reservation_dir_ensure || return 1
  for file in "$RESERVATION_DIR"/*.state; do
    [ -f "$file" ] || continue
    [ "$(reservation_field "$file" pool_id)" = "$pool" ] || continue
    phase="$(reservation_field "$file" phase)"
    case ",$phases," in *",$phase,"*) count=$((count + 1)) ;; esac
  done
  printf '%s\n' "$count"
}

scaleset_jit_service_count() {
  local pool="$1"
  [ -f "$INVENTORY_FILE" ] || { printf '0\n'; return; }
  awk -F'|' -v p="$pool" '$7==p && $11=="valid" && $12=="scaleset" &&
    ($2=="running" || $2=="created") {n++} END{print n+0}' "$INVENTORY_FILE"
}

scaleset_offer_for_pool() {
  local pool="$1" file phase
  reservation_dir_ensure || return 1
  for file in "$RESERVATION_DIR"/*.state; do
    [ -f "$file" ] || continue
    [ "$(reservation_field "$file" pool_id)" = "$pool" ] || continue
    phase="$(reservation_field "$file" phase)"
    [ "$phase" = offered ] || continue
    basename "$file" .state
    return 0
  done
  return 1
}

scaleset_jit_runner_name() {
  local pool="$1" handle="$2" reservation="$3" digest
  digest="$(printf '%s' "$pool|$handle|$reservation" | sha256sum | cut -c1-20)"
  printf '%s-jit-%s-%s\n' "$NAME_PREFIX" "$pool" "$digest"
}

scaleset_prewarm_target() {
  local pool="$1" expected_revision="$2" path value
  path="$RUNDIR/prewarm.$pool"
  [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c %a "$path" 2>/dev/null)" = 600 ] ||
    return 1
  value="$(php -r '
    $lines=file($argv[1],FILE_IGNORE_NEW_LINES);
    $v=[];
    foreach($lines?:[] as $line){
      $parts=explode("=",$line,2);
      if(count($parts)!==2||isset($v[$parts[0]]))exit(2);
      $v[$parts[0]]=$parts[1];
    }
    if(array_keys($v)!==["target","config_revision","expires"]||
      !preg_match("/^(0|[1-9][0-9]*)$/",$v["target"])||
      !preg_match("/^[0-9a-f]{64}$/",$v["config_revision"])||
      !preg_match("/^[1-9][0-9]*$/",$v["expires"])||
      !hash_equals($argv[2],$v["config_revision"])||(int)$v["expires"]<=time())exit(3);
    echo $v["target"];
  ' "$path" "$expected_revision" 2>/dev/null)" || {
    # REVIEW(crf-v3q.13.8): Prewarm is temporary configuration-bound intent.
    # Invalid, expired, or old-revision records are removed atomically from
    # effective scheduling rather than silently surviving forever.
    rm -f "$path"
    return 1
  }
  printf '%s\n' "$value"
}

_scaleset_autoscale_tick_locked() {
  local snapshot_tsv plan_input plan_output leases_tsv cursor=0 sequence rec pool assigned healthy handles
  local warm service charged pending leases max cpu memory desired admitted blocked order removals advertised target fresh
  local current add epoch spec config_rev reservation handle container remote payload response descriptor
  scaleset_snapshot_refresh || { err "scale-set demand snapshot is unavailable"; return 1; }
  fleet_inventory_refresh || { err "scale-set Docker inventory is unavailable"; return 1; }
  resource_snapshot_refresh "$INVENTORY_FILE" || { err "scale-set resource budget is unavailable"; return 1; }
  snapshot_tsv="$SCALESET_STATE_DIR/snapshot.$$.tsv"
  plan_input="$SCALESET_STATE_DIR/scheduler.$$.in"
  plan_output="$SCALESET_STATE_DIR/scheduler.$$.out"
  leases_tsv="$SCALESET_STATE_DIR/leases.$$.tsv"
  # RETURN traps are dynamically scoped in Bash. Clear this trap on its first
  # invocation so it cannot fire again when autoscale_tick returns after these
  # local variables have gone out of scope under `set -u`.
  trap 'trap - RETURN; rm -f "$snapshot_tsv" "$plan_input" "$plan_output" "$leases_tsv"' RETURN
  scaleset_snapshot_tsv >"$snapshot_tsv" || return 1
  sequence="$(php -r '$j=json_decode(file_get_contents($argv[1]),true);echo (int)($j["sequence"]??0);' \
    "$SCALESET_SNAPSHOT")"
  config_rev="$(config_revision)" || return 1
  : >"$plan_input"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    pool="${rec%%|*}"
    IFS='|' read -r _ assigned healthy handles fresh < <(awk -F'|' -v p="$pool" '$1==p{print;exit}' "$snapshot_tsv")
    [ -n "${assigned:-}" ] || { assigned=0; healthy=0; handles=""; fresh=0; }
    warm="$(pool_idle "$pool")"
    target="$(scaleset_prewarm_target "$pool" "$config_rev" 2>/dev/null)" && warm="$target"
    service=$(( $(scaleset_jit_service_count "$pool") +
      $(scaleset_reservation_count "$pool" assigned,acting,observed) ))
    charged="$service"
    pending="$(scaleset_reservation_count "$pool" reserved)"
    leases="$(scaleset_reservation_count "$pool" offered)"
    max="$(pool_max "$pool")"; cpu="$(pool_cpu_milli "$pool")"; memory="$(pool_memory_bytes "$pool")"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$pool" "$assigned" "$warm" "$service" "$charged" "$pending" "$leases" \
      "$max" "$cpu" "$memory" "$healthy" "$fresh" >>"$plan_input"
  done < <(pool_records)
  [ -f "$RUNDIR/scaleset.scheduler.cursor" ] &&
    cursor="$(cat "$RUNDIR/scaleset.scheduler.cursor" 2>/dev/null || echo 0)"
  scheduler_plan "$plan_input" "$RESOURCE_CPU_ADMISSIBLE_MILLI" \
    "$RESOURCE_MEMORY_ADMISSIBLE_BYTES" "$cursor" 1 >"$plan_output" || return 1
  cp "$plan_output" "$SCALESET_STATE_DIR/last-plan.tmp.$$" &&
    chmod 0600 "$SCALESET_STATE_DIR/last-plan.tmp.$$" &&
    mv "$SCALESET_STATE_DIR/last-plan.tmp.$$" "$SCALESET_STATE_DIR/last-plan.tsv" || return 1
  printf '%s\n' "$SCHEDULER_CURSOR" >"$RUNDIR/scaleset.scheduler.cursor"
  : >"$leases_tsv"
  while IFS='|' read -r pool desired admitted blocked order removals advertised target; do
    current="$(scaleset_reservation_count "$pool" offered)"
    add=$((target - current)); [ "$add" -gt 0 ] || add=0
    cpu="$(pool_cpu_milli "$pool")"; memory="$(pool_memory_bytes "$pool")"
    spec="$(pool_runner_spec_hash "$pool")" || return 1
    for epoch in $(seq 1 "$add"); do
      offer_lease_create "$pool" "${sequence:-0}" "$epoch-$RANDOM" "$cpu" "$memory" \
        "$spec" "$config_rev" "$(( $(date +%s) + 90 ))" || return 1
    done
    printf '%s|%s\n' "$pool" "$advertised" >>"$leases_tsv"
  done <"$plan_output"
  payload="$(php -r '
    $leases=[];foreach(file($argv[1],FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
      [$pool,$count]=explode("|",$line,2);$leases[$pool]=(int)$count;
    } echo json_encode(["leases"=>$leases],JSON_UNESCAPED_SLASHES);
  ' "$leases_tsv")" || return 1
  scaleset_request publish_capacity_leases "$payload" >/dev/null || return 1

  while IFS='|' read -r pool assigned healthy handles fresh; do
    [ -n "$handles" ] || continue
    IFS=',' read -r -a handle_list <<<"$handles"
    for handle in "${handle_list[@]}"; do
      [[ "$handle" =~ ^[1-9][0-9]*$ ]] || continue
      reservation="$(scaleset_offer_for_pool "$pool" 2>/dev/null)" || continue
      container="$(scaleset_jit_runner_name "$pool" "$handle" "$reservation")"
      offer_lease_assign "$reservation" "$container" || return 1
      remote="$(hostname -s)-$container"
      payload="$(php -r 'echo json_encode(["pool_id"=>$argv[1],"work_handle"=>(int)$argv[2],
        "runner_name"=>$argv[3],"work_folder"=>"_work"],JSON_UNESCAPED_SLASHES);' \
        "$pool" "$handle" "$remote")" || return 1
      if ! response="$(scaleset_request issue_jit "$payload")"; then
        reservation_set_phase "$reservation" failed || true
        continue
      fi
      descriptor="$(printf '%s' "$response" | php -r '
        $j=json_decode(stream_get_contents(STDIN),true);$v=$j["result"]["descriptor"]??"";
        if(($j["ok"]??false)!==true||!is_string($v)||strlen($v)>65536||
          !preg_match("/^[A-Za-z0-9._+\\/=:-]+$/",$v))exit(2);
        echo $v;
      ')" || { reservation_set_phase "$reservation" failed || true; continue; }
      spec="$(pool_runner_spec_hash "$pool")" || return 1
      printf '%s\n' "$descriptor" | jit_execute "$pool" "$reservation" "$handle" "$spec" "$config_rev" ||
        reservation_set_phase "$reservation" failed || true
      descriptor=""; unset descriptor
    done
  done <"$snapshot_tsv"
}

scaleset_autoscale_tick() {
  local lock="$RUNDIR/scaleset.tick.lock" wait_seconds="${SCALESET_TICK_LOCK_TIMEOUT_SECONDS:-30}" rc
  [[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] && [ "$wait_seconds" -le 60 ] || return 1
  mkdir -p "$RUNDIR" || return 1
  # REVIEW(crf-v3q.13.7): Daemon, UI, and migration ticks share sequence,
  # scheduler cursor, offer leases, and plan publication. Serialize the full
  # snapshot-plan-commit transaction, not just individual file writes.
  exec 7>"$lock" || return 1
  if ! flock -w "$wait_seconds" 7; then
    exec 7>&-
    err "another scale-set scheduling transaction is still running"
    return 1
  fi
  if _scaleset_autoscale_tick_locked; then rc=0; else rc=$?; fi
  flock -u 7 || rc=1
  exec 7>&-
  return "$rc"
}

scaleset_prepare_ineligible() {
  [ "$1" = "$(scaleset_ownership_revision)" ] ||
    { err "scale-set ownership identity changed"; return 1; }
  scaleset_request apply_sessions '{"eligible":false}'
}
scaleset_activate_eligible() {
  [ "$1" = "$(scaleset_ownership_revision)" ] ||
    { err "scale-set ownership identity changed"; return 1; }
  scaleset_request reconcile_owned '{"eligible":true}'
}
scaleset_make_ineligible() {
  [ "$1" = "$(scaleset_ownership_revision)" ] ||
    { err "scale-set ownership identity changed"; return 1; }
  scaleset_request reconcile_owned '{"eligible":false}'
}
scaleset_delete_owned() {
  [ "$1" = "$(scaleset_ownership_revision)" ] ||
    { err "scale-set ownership identity changed"; return 1; }
  scaleset_request delete_owned '{}'
}
