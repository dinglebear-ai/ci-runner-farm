#!/bin/bash
# Durable, fail-closed classic <-> scale-set backend migration.
# POOL_BACKEND is requested intent only. Effective state is read exclusively
# from the persisted transition record.

MIGRATION_STATE="${MIGRATION_STATE:-$CFGDIR/backend-transition.json}"
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
  migration_load && [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ] &&
    [ "$MIGRATION_PHASE" = classic_active ]
}

backend_scaleset_admission_allowed() {
  migration_load && [ "$MIGRATION_EFFECTIVE_BACKEND" = scaleset ] &&
    [ "$MIGRATION_PHASE" = scaleset_active ]
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

# These barriers are intentionally fail-closed. Production implementations must
# be supplied by the compatibility-proven GitHub operations. Tests inject exact
# hooks; absence can pause a migration but can never overlap eligible backends.
migration_classic_quiesce() { [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ]; }
migration_classic_prove_ineligible() { [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ]; }
migration_classic_activate() { [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ]; }
migration_classic_prove_effective() { [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ]; }
migration_jit_drained() {
  ! find "$JIT_STATE_DIR" -type f -name '*.state' -exec grep -lE '^phase=(running|secret_consumed|container_observed)$' {} + 2>/dev/null |
    grep -q .
}
