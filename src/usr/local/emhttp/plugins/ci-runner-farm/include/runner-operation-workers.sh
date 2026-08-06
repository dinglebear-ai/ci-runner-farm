#!/bin/bash
# Durable workers for low-frequency GraphQL-facing operations. High-volume
# output remains beneath RUNDIR; only bounded metadata is committed to flash.

OPERATION_RUNTIME_DIR="${OPERATION_RUNTIME_DIR:-${RUNDIR:-/run/ci-runner-farm}/operations}"

operation_runtime_dir_ensure() {
  if [ -e "$OPERATION_RUNTIME_DIR" ]; then
    [ -d "$OPERATION_RUNTIME_DIR" ] && [ ! -L "$OPERATION_RUNTIME_DIR" ] || return 1
  else
    mkdir -p -- "$OPERATION_RUNTIME_DIR" || return 1
  fi
  chmod 0700 "$OPERATION_RUNTIME_DIR" || return 1
}

operation_output_log_path() {
  local id="$1" source="$2"
  operation_id_valid "$id" || return 1
  case "$source" in
    compatibility_log) printf '%s/%s.compatibility.log' "$OPERATION_RUNTIME_DIR" "$id" ;;
    provisioning_log) printf '%s/%s.provisioning.log' "$OPERATION_RUNTIME_DIR" "$id" ;;
    image_build_log) printf '%s/%s.image-build.log' "$OPERATION_RUNTIME_DIR" "$id" ;;
    *) return 1 ;;
  esac
}

operation_output_log_prepare() {
  local path
  operation_runtime_dir_ensure || return 1
  path="$(operation_output_log_path "$1" "$2")" || return 1
  [ ! -L "$path" ] || return 1
  : >"$path" || return 1
  chmod 0600 "$path" || return 1
  printf '%s' "$path"
}

operation_worker_launch() {
  local launcher="${CRF_OPERATION_WORKER_LAUNCHER:-$0}" pid
  [ -f "$launcher" ] && [ ! -L "$launcher" ] && [ -x "$launcher" ] || return 1
  nohup "$launcher" "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  kill -0 "$pid" 2>/dev/null
}

operation_config_matches() {
  local id="$1" expected current
  expected="$(operation_config_revision_read "$id")" || return 1
  current="$(config_revision 2>/dev/null)" || return 1
  [ "$current" = "$expected" ]
}

operation_start_error() {
  local code="$1" message="$2" id="${3:-}"
  if operation_id_valid "$id"; then
    printf '{"ok":false,"code":"%s","message":"%s","operation_id":"%s"}
' "$code" "$message" "$id"
  else
    printf '{"ok":false,"code":"%s","message":"%s","operation_id":null}
' "$code" "$message"
  fi
}

operation_start_success() {
  printf '{"ok":true,"code":"ok","message":"operation queued","operation_id":"%s"}
' "$1"
}

cmd_compatibility_operation_start() {
  local expected="$1" current id rc
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    operation_start_error invalid_revision 'valid configuration revision required'
    return 2
  }
  current="$(config_revision 2>/dev/null)" || {
    operation_start_error backend_unavailable 'configuration revision is unavailable'
    return 5
  }
  if [ "$current" != "$expected" ]; then
    operation_start_error stale_config 'configuration changed'
    return 3
  fi
  if id="$(operation_create_unique compatibility_test "$current" compatibility_log)"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ] && operation_id_valid "$id"; then
      operation_start_error operation_running 'a compatibility test is already active' "$id"
      return 4
    fi
    operation_start_error backend_unavailable 'could not create compatibility operation'
    return 5
  fi
  if ! operation_worker_launch compatibility-operation-worker "$id"; then
    operation_finish "$id" failed launch_failed 'Compatibility worker could not be launched.' >/dev/null 2>&1 || true
    operation_start_error backend_unavailable 'compatibility worker could not be launched' "$id"
    return 5
  fi
  operation_start_success "$id"
}

operation_compatibility_evidence_valid() {
  local path="$1" log_path="$2" size identity
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo invalid)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 2 ] && [ "$size" -le 262144 ] || return 1
  chmod 0600 "$path" || return 1
  "$SCALESET_HELPER" check-compatibility --path "$path" >>"$log_path" 2>&1 || return 1
  identity="$(scaleset_bound_identity 2>/dev/null)" || return 1
  /usr/bin/php -r '
    $j=json_decode(file_get_contents($argv[1]),true);$v=explode("|",$argv[2]);
    if(!is_array($j)||count($v)!==7)exit(2);
    $keys=["plugin_digest","image_digest","dockerfile_digest","entrypoint_digest",
      "owner","installation_id","host_id"];
    foreach($keys as $i=>$key)if(!hash_equals((string)($j[$key]??""),(string)$v[$i]))exit(3);
  ' "$path" "$identity"
}

operation_compatibility_worker() {
  local id="$1" log_path evidence_tmp rc=0
  operation_id_valid "$id" || return 1
  operation_mark_running "$id" 'Compatibility test started.' || return 1
  log_path="$(operation_output_log_prepare "$id" compatibility_log)" || {
    operation_finish "$id" failed backend_unavailable 'Compatibility log could not be created.' >/dev/null 2>&1 || true
    return 1
  }
  if ! operation_config_matches "$id"; then
    printf '%s
' 'configuration changed before compatibility probe' >>"$log_path"
    operation_finish "$id" failed stale_config 'Configuration changed before compatibility test.' "$log_path"
    return
  fi
  if ! scaleset_probe_config_write >>"$log_path" 2>&1; then
    operation_finish "$id" failed evidence_invalid       'Compatibility test requires complete live workload evidence.' "$log_path"
    return
  fi
  evidence_tmp="${SCALESET_COMPAT}.operation.$id.tmp"
  rm -f -- "$evidence_tmp"
  if "$SCALESET_HELPER" probe --config "$SCALESET_PROBE_CONFIG"       --output "$evidence_tmp" --timeout 10m >>"$log_path" 2>&1; then
    if ! operation_config_matches "$id"; then
      rm -f -- "$evidence_tmp"
      operation_finish "$id" failed stale_config         'Configuration changed while compatibility test was running.' "$log_path"
      return
    fi
    if ! operation_compatibility_evidence_valid "$evidence_tmp" "$log_path"; then
      rm -f -- "$evidence_tmp"
      operation_finish "$id" failed evidence_invalid 'Compatibility evidence was invalid.' "$log_path"
      return
    fi
    if ! mv -f -- "$evidence_tmp" "$SCALESET_COMPAT"; then
      rm -f -- "$evidence_tmp"
      operation_finish "$id" failed backend_unavailable 'Compatibility evidence could not be committed.' "$log_path"
      return
    fi
    operation_finish "$id" succeeded compatible 'Packaged compatibility gate passed.' "$log_path"
  else
    rc=$?
    rm -f -- "$evidence_tmp"
    printf 'compatibility helper exit=%s
' "$rc" >>"$log_path"
    operation_finish "$id" failed probe_failed       'Compatibility gate did not pass.' "$log_path"
  fi
}
