#!/bin/bash
# Durable workers for low-frequency GraphQL-facing operations. High-volume
# output remains beneath RUNDIR; only bounded metadata is committed to flash.

OPERATION_RUNTIME_DIR="${OPERATION_RUNTIME_DIR:-${RUNDIR:-/run/ci-runner-farm}/operations}"
OPERATION_COMPATIBILITY_TIMEOUT_SECONDS="${OPERATION_COMPATIBILITY_TIMEOUT_SECONDS:-660}"
OPERATION_PROVISIONING_TIMEOUT_SECONDS="${OPERATION_PROVISIONING_TIMEOUT_SECONDS:-300}"
OPERATION_IMAGE_BUILD_TIMEOUT_SECONDS="${OPERATION_IMAGE_BUILD_TIMEOUT_SECONDS:-3600}"
OPERATION_KILL_AFTER_SECONDS="${OPERATION_KILL_AFTER_SECONDS:-5}"
OPERATION_COMMAND_LAUNCHER="${CRF_OPERATION_COMMAND_LAUNCHER:-$0}"

operation_run_bounded() {
  local seconds="$1" pid deadline kill_deadline now rc=0
  shift
  case "$seconds" in ''|*[!0-9]*) return 125 ;; esac
  [ "$seconds" -ge 1 ] && [ "$seconds" -le 86400 ] || return 125
  case "$OPERATION_KILL_AFTER_SECONDS" in ''|*[!0-9]*) return 125 ;; esac
  [ "$OPERATION_KILL_AFTER_SECONDS" -ge 1 ] && [ "$OPERATION_KILL_AFTER_SECONDS" -le 60 ] || return 125
  setsid "$@" &
  pid=$!
  deadline=$(($(date +%s) + seconds))
  while kill -0 -- "-$pid" 2>/dev/null; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      kill_deadline=$((now + OPERATION_KILL_AFTER_SECONDS))
      while kill -0 -- "-$pid" 2>/dev/null && [ "$(date +%s)" -lt "$kill_deadline" ]; do
        sleep 0.1
      done
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  wait "$pid" || rc=$?
  return "$rc"
}

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
    image_build_log) printf '%s/build.log' "${RUNDIR:-$OPERATION_RUNTIME_DIR}" ;;
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
  if operation_run_bounded "$OPERATION_COMPATIBILITY_TIMEOUT_SECONDS" \
      "$SCALESET_HELPER" probe --config "$SCALESET_PROBE_CONFIG" \
      --output "$evidence_tmp" --timeout 10m >>"$log_path" 2>&1; then
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
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      operation_finish "$id" failed timed_out 'Compatibility test exceeded its wall-clock limit.' "$log_path"
    else
      operation_finish "$id" failed probe_failed 'Compatibility gate did not pass.' "$log_path"
    fi
  fi
}


cmd_provisioning_operation_start() {
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
  if id="$(operation_create_unique provisioning_validation "$current" provisioning_log)"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ] && operation_id_valid "$id"; then
      operation_start_error operation_running 'a provisioning validation is already active' "$id"
      return 4
    fi
    operation_start_error backend_unavailable 'could not create provisioning operation'
    return 5
  fi
  if ! operation_worker_launch provisioning-operation-worker "$id"; then
    operation_finish "$id" failed launch_failed 'Provisioning worker could not be launched.' >/dev/null 2>&1 || true
    operation_start_error backend_unavailable 'provisioning worker could not be launched' "$id"
    return 5
  fi
  operation_start_success "$id"
}

operation_provisioning_worker() {
  local id="$1" log_path
  operation_id_valid "$id" || return 1
  operation_mark_running "$id" 'Provisioning validation started.' || return 1
  log_path="$(operation_output_log_prepare "$id" provisioning_log)" || {
    operation_finish "$id" failed backend_unavailable 'Provisioning log could not be created.' >/dev/null 2>&1 || true
    return 1
  }
  if ! operation_config_matches "$id"; then
    printf '%s\n' 'configuration changed before provisioning validation' >>"$log_path"
    operation_finish "$id" failed stale_config 'Configuration changed before provisioning validation.' "$log_path"
    return
  fi
  if operation_run_bounded "$OPERATION_PROVISIONING_TIMEOUT_SECONDS" \
      "$OPERATION_COMMAND_LAUNCHER" validate >>"$log_path" 2>&1; then
    if ! operation_config_matches "$id"; then
      operation_finish "$id" failed stale_config 'Configuration changed while provisioning validation was running.' "$log_path"
      return
    fi
    operation_finish "$id" succeeded provisioning_valid 'Provisioning mechanics were verified.' "$log_path"
  else
    local rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      operation_finish "$id" failed timed_out 'Provisioning validation exceeded its wall-clock limit.' "$log_path"
    else
      operation_finish "$id" failed provisioning_failed 'Provisioning mechanics did not pass.' "$log_path"
    fi
  fi
}


operation_image_source_path() {
  local source="${CFGDIR:-/boot/config/plugins/ci-runner-farm}/Dockerfile"
  [ -f "$source" ] || source="${CRF_DEFAULT_DOCKERFILE:-/usr/local/emhttp/plugins/${PLUGIN:-ci-runner-farm}/default.Dockerfile}"
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  printf '%s' "$source"
}

operation_image_source_hash() {
  local source size
  source="$(operation_image_source_path)" || return 1
  size="$(stat -c %s "$source" 2>/dev/null || echo invalid)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 1 ] && [ "$size" -le 1048576 ] || return 1
  sha256sum "$source" 2>/dev/null | awk '{print $1}'
}

operation_image_snapshot_path() {
  operation_id_valid "$1" || return 1
  mkdir -p -- "$RUNDIR" || return 1
  printf '%s/build.Dockerfile.%s' "$RUNDIR" "$1"
}

operation_image_snapshot_prepare() {
  local id="$1" expected="$2" source actual path tmp companion validator endpoint
  operation_id_valid "$id" && [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  source="$(operation_image_source_path)" || return 1
  actual="$(operation_image_source_hash)" || return 1
  [ "$actual" = "$expected" ] || return 2
  path="$(operation_image_snapshot_path "$id")" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp="$(mktemp "$RUNDIR/build.Dockerfile.$id.tmp.XXXXXX")" || return 1
  if ! cp -- "$source" "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  actual="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
  if [ "$actual" != "$expected" ] || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" "$path"
    return 2
  fi
  if build_context_needs_kache_supervisor "$path"; then
    companion="${source%/*}/kache-supervise.sh"
    build_context_copy_kache_supervisor "$companion" "${path}.kache-supervise.sh" || {
      operation_image_snapshot_cleanup "$path"; return 1;
    }
  fi
  if build_context_needs_endpoint_validator "$path"; then
    validator="${source%/*}/endpoint-validation.sh"
    build_context_copy_companion "$validator" "${path}.endpoint-validation.sh" || {
      operation_image_snapshot_cleanup "$path"; return 1;
    }
  fi
  if grep -Eq '^[[:space:]]*ARG[[:space:]]+KACHE_REMOTE_ENDPOINT([[:space:]]|=|$)' "$path"; then
    endpoint="${path}.kache-endpoint"
    kache_endpoint_load && (umask 077; printf '%s\n' "$KACHE_REMOTE_ENDPOINT" >"$endpoint") &&
      chmod 0600 "$endpoint" || { operation_image_snapshot_cleanup "$path"; return 1; }
  fi
  printf '%s' "$path"
}

operation_image_snapshot_cleanup() {
  local path="$1"
  rm -f -- "$path" "${path}.kache-supervise.sh" "${path}.endpoint-validation.sh" "${path}.kache-endpoint"
}

operation_image_snapshot_valid() {
  local id="$1" expected="$2" path size mode actual
  path="$(operation_image_snapshot_path "$id")" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo invalid)"
  mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 1 ] && [ "$size" -le 1048576 ] &&
    [ "$mode" = 600 ] || return 1
  actual="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

cmd_image_build_operation_start() {
  local expected="$1" actual config id snapshot rc
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    operation_start_error invalid_revision 'valid Dockerfile SHA-256 required'
    return 2
  }
  actual="$(operation_image_source_hash 2>/dev/null)" || {
    operation_start_error backend_unavailable 'saved Dockerfile is unavailable'
    return 5
  }
  if [ "$actual" != "$expected" ]; then
    operation_start_error stale_dockerfile 'Dockerfile changed after it was saved'
    return 3
  fi
  config="$(config_revision 2>/dev/null)" || {
    operation_start_error backend_unavailable 'configuration revision is unavailable'
    return 5
  }
  if id="$(operation_create_unique image_build "$config" image_build_log)"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ] && operation_id_valid "$id"; then
      operation_start_error operation_running 'an image build is already active' "$id"
      return 4
    fi
    operation_start_error backend_unavailable 'could not create image build operation'
    return 5
  fi
  if snapshot="$(operation_image_snapshot_prepare "$id" "$expected")"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      operation_finish "$id" failed stale_dockerfile 'Dockerfile changed while the build was queued.' >/dev/null 2>&1 || true
      operation_start_error stale_dockerfile 'Dockerfile changed while the build was queued' "$id"
      return 3
    fi
    operation_finish "$id" failed backend_unavailable 'Dockerfile snapshot could not be created.' >/dev/null 2>&1 || true
    operation_start_error backend_unavailable 'Dockerfile snapshot could not be created' "$id"
    return 5
  fi
  if ! operation_worker_launch image-build-operation-worker "$id" "$expected"; then
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed launch_failed 'Image build worker could not be launched.' >/dev/null 2>&1 || true
    operation_start_error backend_unavailable 'image build worker could not be launched' "$id"
    return 5
  fi
  operation_start_success "$id"
}

operation_image_build_worker() {
  local id="$1" expected="$2" snapshot lock log_path rc
  operation_id_valid "$id" && [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  operation_mark_running "$id" 'Image build started.' || return 1
  snapshot="$(operation_image_snapshot_path "$id")" || return 1
  if ! operation_image_snapshot_valid "$id" "$expected"; then
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed stale_dockerfile 'Dockerfile snapshot did not match the requested SHA-256.' >/dev/null 2>&1 || true
    return
  fi
  mkdir -p -- "$RUNDIR" || {
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed backend_unavailable 'Build runtime directory is unavailable.' >/dev/null 2>&1 || true
    return
  }
  lock="$RUNDIR/build.lock"
  [ ! -L "$lock" ] || {
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed backend_unavailable 'Build lock is unsafe.' >/dev/null 2>&1 || true
    return
  }
  exec 9>"$lock" || {
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed backend_unavailable 'Build lock could not be opened.' >/dev/null 2>&1 || true
    return
  }
  chmod 0600 "$lock" || {
    exec 9>&-
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed backend_unavailable 'Build lock could not be secured.' >/dev/null 2>&1 || true
    return
  }
  if ! flock -n 9; then
    exec 9>&-
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed operation_running 'Another image build is already running.' >/dev/null 2>&1 || true
    return
  fi
  log_path="$(operation_output_log_prepare "$id" image_build_log)" || {
    flock -u 9 || true
    exec 9>&-
    operation_image_snapshot_cleanup "$snapshot"
    operation_finish "$id" failed backend_unavailable 'Build log could not be created.' >/dev/null 2>&1 || true
    return
  }
  if operation_run_bounded "$OPERATION_IMAGE_BUILD_TIMEOUT_SECONDS" \
      "$OPERATION_COMMAND_LAUNCHER" build-image "$snapshot" >>"$log_path" 2>&1; then rc=0; else rc=$?; fi
  operation_image_snapshot_cleanup "$snapshot"
  printf '__BUILD_RC__=%s\n' "$rc" >>"$log_path"
  chmod 0600 "$log_path" || true
  flock -u 9 || true
  exec 9>&-
  if [ "$rc" -eq 0 ]; then
    operation_finish "$id" succeeded image_built 'Runner image build completed.' "$log_path"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    operation_finish "$id" failed timed_out 'Runner image build exceeded its wall-clock limit.' "$log_path"
  else
    operation_finish "$id" failed build_failed 'Runner image build failed.' "$log_path"
  fi
}
