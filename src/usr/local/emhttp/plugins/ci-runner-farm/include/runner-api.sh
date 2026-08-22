#!/bin/bash

RUNNER_API_SCHEMA_VERSION=1
RUNNER_API_MAX_REQUEST_BYTES=1048576
RUNNER_API_MAX_RESPONSE_BYTES=1048576
RUNNER_API_MAX_LOG_BYTES=65536
RUNNER_API_REQUEST_FILE=""

runner_api_cleanup_request() {
  local path="${RUNNER_API_REQUEST_FILE:-}"
  [ -n "$path" ] || return 0
  case "$path" in "$RUNDIR"/api-requests/request.*) ;; *) RUNNER_API_REQUEST_FILE=""; return 1 ;; esac
  rm -f -- "$path"
  RUNNER_API_REQUEST_FILE=""
}

runner_api_capture_request() {
  local request_dir="$RUNDIR/api-requests" request_file rc size mode
  runner_api_cleanup_request || return 5
  mkdir -p -- "$request_dir" || return 5
  [ -d "$request_dir" ] && [ ! -L "$request_dir" ] || return 5
  chmod 0700 "$request_dir" || return 5
  request_file="$(mktemp "$request_dir/request.XXXXXX")" || return 5
  chmod 0600 "$request_file" || { rm -f -- "$request_file"; return 5; }
  RUNNER_API_REQUEST_FILE="$request_file"
  /usr/bin/php -r '
    $path=$argv[1];$max=(int)$argv[2];$total=0;
    $out=@fopen($path,"wb");if(!is_resource($out))exit(3);
    while(!feof(STDIN)&&$total<=$max){
      $remaining=$max+1-$total;
      $chunk=fread(STDIN,min(8192,$remaining));
      if($chunk===false){fclose($out);exit(4);}
      if($chunk===""){if(feof(STDIN))break;continue;}
      $written=fwrite($out,$chunk);
      if($written===false||$written!==strlen($chunk)){fclose($out);exit(5);}
      $total+=$written;
    }
    if(!fflush($out)){fclose($out);exit(5);}
    fclose($out);
    exit($total>$max?2:0);
  ' "$request_file" "$RUNNER_API_MAX_REQUEST_BYTES"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    runner_api_cleanup_request || true
    [ "$rc" -eq 2 ] && return 2
    return 5
  fi
  size="$(stat -c %s "$request_file" 2>/dev/null || echo invalid)"
  mode="$(stat -c %a "$request_file" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$RUNNER_API_MAX_REQUEST_BYTES" ] && [ "$mode" = 600 ] || {
    runner_api_cleanup_request || true
    return 5
  }
}

runner_api_uuid_valid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

runner_api_sha256_valid() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

runner_api_pool_valid() {
  [[ "$1" =~ ^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$ ]]
}

runner_api_runner_valid() {
  [[ "$1" =~ ^ci-runner-([0-9]+|[a-z]([a-z0-9-]{0,22}[a-z0-9])?-[0-9]+|jit-[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{20})$ ]]
}

runner_api_repository_valid() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

runner_api_uint_between() {
  local value="$1" minimum="$2" maximum="$3"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}

runner_api_validate_decoded_fields() {
  local operation="$1" count="${#RUNNER_API_FIELDS[@]}"
  [ "$count" -ge 1 ] && runner_api_uuid_valid "${RUNNER_API_FIELDS[0]}" || return 2
  case "$operation" in
    start|stop|restart)
      [ "$count" -eq 3 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" &&
        runner_api_sha256_valid "${RUNNER_API_FIELDS[2]}" || return 2
      ;;
    scale)
      [ "$count" -eq 5 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" &&
        runner_api_sha256_valid "${RUNNER_API_FIELDS[2]}" || return 2
      [ "${RUNNER_API_FIELDS[3]}" = null ] || runner_api_pool_valid "${RUNNER_API_FIELDS[3]}" || return 2
      runner_api_uint_between "${RUNNER_API_FIELDS[4]}" 0 64 || return 2
      ;;
    prewarm)
      [ "$count" -eq 4 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" &&
        runner_api_pool_valid "${RUNNER_API_FIELDS[2]}" &&
        runner_api_uint_between "${RUNNER_API_FIELDS[3]}" 0 64 || return 2
      ;;
    recycle)
      [ "$count" -eq 4 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" &&
        runner_api_sha256_valid "${RUNNER_API_FIELDS[2]}" &&
        runner_api_runner_valid "${RUNNER_API_FIELDS[3]}" || return 2
      ;;
    maintenance)
      [ "$count" -eq 3 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" || return 2
      case "${RUNNER_API_FIELDS[2]}" in BEGIN|RESUME) ;; *) return 2 ;; esac
      ;;
    operation-read)
      [ "$count" -eq 2 ] && runner_api_uuid_valid "${RUNNER_API_FIELDS[1]}" || return 2
      ;;
    runner-log|history-log)
      [ "$count" -eq 3 ] && runner_api_runner_valid "${RUNNER_API_FIELDS[1]}" &&
        runner_api_uint_between "${RUNNER_API_FIELDS[2]}" 1 500 || return 2
      ;;
    controller-log)
      [ "$count" -eq 2 ] && runner_api_uint_between "${RUNNER_API_FIELDS[1]}" 1 500 || return 2
      ;;
    image-build-start)
      [ "$count" -eq 2 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" || return 2
      ;;
    provisioning-validation-start|compatibility-test-start|cache-clear)
      [ "$count" -eq 2 ] && runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" || return 2
      ;;
    backend-migration-start|backend-rollback)
      [ "$count" -eq 5 ] || return 2
      runner_api_sha256_valid "${RUNNER_API_FIELDS[1]}" &&
        runner_api_sha256_valid "${RUNNER_API_FIELDS[2]}" &&
        runner_api_sha256_valid "${RUNNER_API_FIELDS[3]}" &&
        runner_api_sha256_valid "${RUNNER_API_FIELDS[4]}" || return 2
      ;;
    queue-cancel)
      [ "$count" -eq 3 ] && runner_api_repository_valid "${RUNNER_API_FIELDS[1]}" || return 2
      [[ "${RUNNER_API_FIELDS[2]}" =~ ^[0-9]{1,20}$ ]] || return 2
      ;;
    *) return 2 ;;
  esac
}

runner_api_parse_fields() {
  local operation="$1" row token decoded
  local parser="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/api-request.php"
  RUNNER_API_FIELDS=()
  row="$(/usr/bin/php "$parser" fields "$operation" "$RUNNER_API_REQUEST_FILE")" || return 2
  case "$row" in *$'\n'*|*$'\r'*) return 2 ;; esac
  local -a encoded=()
  IFS=$'\t' read -r -a encoded <<<"$row"
  [ "${#encoded[@]}" -gt 0 ] || return 2
  for token in "${encoded[@]}"; do
    case "$token" in ''|*[!A-Za-z0-9+/=]*) return 2 ;; esac
    decoded="$(printf '%s' "$token" | base64 -d 2>/dev/null)" || return 2
    case "$decoded" in *$'\n'*|*$'\r'*) return 2 ;; esac
    RUNNER_API_FIELDS+=("$decoded")
  done
  runner_api_validate_decoded_fields "$operation"
}

runner_api_private_file_valid() {
  local path="$1" maximum="$2" size mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo invalid)"
  mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$maximum" ] && [ "$mode" = 600 ]
}

runner_api_revision_or_empty() {
  local value="$1"
  if runner_api_sha256_valid "$value"; then printf '%s' "$value"; fi
  return 0
}

runner_api_observed_refresh() {
  local value compatibility_file
  RUNNER_API_OBSERVED_CONFIG_REVISION=""
  RUNNER_API_OBSERVED_INVENTORY_REVISION=""
  RUNNER_API_OBSERVED_TRANSITION_REVISION=""
  RUNNER_API_OBSERVED_OWNERSHIP_REVISION=""
  RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID=""
  RUNNER_API_OBSERVED_CREDENTIAL_REVISION=null

  if declare -F config_revision >/dev/null; then
    value="$(config_revision 2>/dev/null || true)"
    RUNNER_API_OBSERVED_CONFIG_REVISION="$(runner_api_revision_or_empty "$value")"
  fi
  if [ -n "${INVENTORY_FILE:-}" ] && runner_api_private_file_valid "$INVENTORY_FILE" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    value="$(sha256sum "$INVENTORY_FILE" 2>/dev/null | cut -d' ' -f1)"
    RUNNER_API_OBSERVED_INVENTORY_REVISION="$(runner_api_revision_or_empty "$value")"
  fi
  if declare -F migration_load >/dev/null && migration_load >/dev/null 2>&1; then
    RUNNER_API_OBSERVED_TRANSITION_REVISION="$(runner_api_revision_or_empty "${MIGRATION_REVISION:-}")"
    RUNNER_API_OBSERVED_OWNERSHIP_REVISION="$(runner_api_revision_or_empty "${MIGRATION_OWNERSHIP_REVISION:-}")"
    RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID="$(runner_api_revision_or_empty "${MIGRATION_COMPATIBILITY_RECORD_ID:-}")"
  fi
  if [ -z "$RUNNER_API_OBSERVED_OWNERSHIP_REVISION" ] && declare -F scaleset_ownership_revision >/dev/null; then
    value="$(scaleset_ownership_revision 2>/dev/null || true)"
    RUNNER_API_OBSERVED_OWNERSHIP_REVISION="$(runner_api_revision_or_empty "$value")"
  fi
  compatibility_file="${SCALESET_COMPAT:-}"
  if [ -z "$RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID" ] && [ -n "$compatibility_file" ] && runner_api_private_file_valid "$compatibility_file" 262144; then
    value="$(/usr/bin/php -r '$j=json_decode(file_get_contents($argv[1]),true);$v=$j["compatibility_record_id"]??"";if(is_string($v))echo $v;' "$compatibility_file" 2>/dev/null || true)"
    RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID="$(runner_api_revision_or_empty "$value")"
  fi
}

runner_api_emit() {
  local request_id="$1" ok="$2" code="$3" message="$4" source="${5:-@null}" helper
  helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/api-response.php"
  runner_api_observed_refresh
  if /usr/bin/php "$helper" "$source" "$request_id" "$ok" "$code" "$message" \
    "$RUNNER_API_OBSERVED_CONFIG_REVISION" "$RUNNER_API_OBSERVED_INVENTORY_REVISION" \
    "$RUNNER_API_OBSERVED_TRANSITION_REVISION" "$RUNNER_API_OBSERVED_OWNERSHIP_REVISION" \
    "$RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID" "$RUNNER_API_OBSERVED_CREDENTIAL_REVISION"; then
    return 0
  fi
  /usr/bin/php "$helper" @null "$request_id" false backend_unavailable \
    'controller produced an invalid response' "$RUNNER_API_OBSERVED_CONFIG_REVISION" \
    "$RUNNER_API_OBSERVED_INVENTORY_REVISION" "$RUNNER_API_OBSERVED_TRANSITION_REVISION" \
    "$RUNNER_API_OBSERVED_OWNERSHIP_REVISION" "$RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID" \
    "$RUNNER_API_OBSERVED_CREDENTIAL_REVISION" || return 5
  return 5
}

runner_api_fail() {
  local code="$1" message="$2" exit_code="$3" request_id="${4:-${RUNNER_API_FIELDS[0]:-}}"
  runner_api_emit "$request_id" false "$code" "$message" @null || true
  return "$exit_code"
}

runner_api_fail_invalid_request() { runner_api_fail invalid_request "${1:-invalid request}" 2 "${2:-}"; }
runner_api_fail_invalid_revision() { runner_api_fail invalid_revision "${1:-invalid revision}" 2 "${2:-}"; }
runner_api_fail_stale_config() { runner_api_fail stale_config "${1:-configuration changed}" 3 "${2:-}"; }
runner_api_fail_stale_inventory() { runner_api_fail stale_inventory "${1:-inventory changed}" 3 "${2:-}"; }
runner_api_fail_stale_transition() { runner_api_fail stale_transition "${1:-transition changed}" 3 "${2:-}"; }
runner_api_fail_ownership_changed() { runner_api_fail ownership_changed "${1:-ownership changed}" 3 "${2:-}"; }
runner_api_fail_compatibility_changed() { runner_api_fail compatibility_changed "${1:-compatibility changed}" 3 "${2:-}"; }
runner_api_fail_backend_unavailable() { runner_api_fail backend_unavailable "${1:-backend unavailable}" 5 "${2:-}"; }
runner_api_fail_output_too_large() { runner_api_fail output_too_large "${1:-output too large}" 5 "${2:-}"; }
runner_api_fail_unsupported_schema() { runner_api_fail unsupported_schema "${1:-unsupported schema}" 2 "${2:-}"; }
runner_api_fail_invalid_runner() { runner_api_fail invalid_runner "${1:-invalid runner}" 4 "${2:-}"; }
runner_api_fail_operation_not_found() { runner_api_fail operation_not_found "${1:-operation not found}" 4 "${2:-}"; }
runner_api_fail_invalid_config() { runner_api_fail invalid_config "${1:-invalid configuration}" 4 "${2:-}"; }
runner_api_fail_backend_transition() { runner_api_fail backend_transition_in_progress "${1:-backend transition in progress}" 4 "${2:-}"; }
runner_api_fail_backend_not_ready() { runner_api_fail backend_not_ready "${1:-backend not ready}" 4 "${2:-}"; }
runner_api_fail_resource_capacity() { runner_api_fail resource_capacity "${1:-requested capacity was not reached}" 4 "${2:-}"; }

runner_api_config_guard() {
  local expected="$1" request_id="${2:-}" current
  runner_api_sha256_valid "$expected" || {
    runner_api_fail_invalid_revision 'configuration revision is invalid' "$request_id"
    return
  }
  if ! declare -F load_cfg >/dev/null || ! load_cfg; then
    runner_api_fail_backend_unavailable 'configuration authority is unavailable' "$request_id"
    return
  fi
  current="$(config_revision 2>/dev/null)" || {
    runner_api_fail_backend_unavailable 'configuration revision is unavailable' "$request_id"
    return
  }
  runner_api_sha256_valid "$current" || {
    runner_api_fail_backend_unavailable 'configuration revision is invalid' "$request_id"
    return
  }
  if [ "$current" != "$expected" ]; then
    runner_api_fail_stale_config 'configuration changed' "$request_id"
    return
  fi
}

runner_api_fleet_guard() {
  local expected_config="$1" expected_inventory="$2" request_id="${3:-}"
  local current_config current_inventory
  runner_api_sha256_valid "$expected_config" && runner_api_sha256_valid "$expected_inventory" || {
    runner_api_fail_invalid_revision 'fleet revisions are invalid' "$request_id"
    return
  }
  if ! declare -F load_cfg >/dev/null || ! load_cfg; then
    runner_api_fail_backend_unavailable 'configuration authority is unavailable' "$request_id"
    return
  fi
  if ! declare -F fleet_inventory_refresh >/dev/null || ! fleet_inventory_refresh; then
    runner_api_fail_backend_unavailable 'fleet inventory is unavailable' "$request_id"
    return
  fi
  current_config="$(config_revision 2>/dev/null)" || {
    runner_api_fail_backend_unavailable 'configuration revision is unavailable' "$request_id"
    return
  }
  if ! runner_api_private_file_valid "${INVENTORY_FILE:-}" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    runner_api_fail_backend_unavailable 'fleet inventory is unsafe' "$request_id"
    return
  fi
  current_inventory="$(sha256sum "$INVENTORY_FILE" 2>/dev/null | cut -d' ' -f1)"
  runner_api_sha256_valid "$current_config" && runner_api_sha256_valid "$current_inventory" || {
    runner_api_fail_backend_unavailable 'fleet authority revision is invalid' "$request_id"
    return
  }
  if [ "$current_config" != "$expected_config" ]; then
    runner_api_fail_stale_config 'configuration changed' "$request_id"
    return
  fi
  if [ "$current_inventory" != "$expected_inventory" ]; then
    runner_api_fail_stale_inventory 'fleet inventory changed' "$request_id"
    return
  fi
}

runner_api_guarded_config_action() {
  local expected="$1" request_id="$2"
  shift 2
  runner_api_config_guard "$expected" "$request_id" || return $?
  "$@"
}

# The caller must be the sole fleet-lock owner. This helper refreshes and guards
# both authorities inside that lock, then invokes one fixed internal action.
runner_api_guarded_fleet_action() {
  local expected_config="$1" expected_inventory="$2" request_id="$3"
  shift 3
  runner_api_fleet_guard "$expected_config" "$expected_inventory" "$request_id" || return $?
  "$@"
}

runner_api_result_file_create() {
  local prefix="$1" dir="$RUNDIR/api-results" path
  case "$prefix" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  mkdir -p -- "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  chmod 0700 "$dir" || return 1
  path="$(mktemp "$dir/$prefix.XXXXXX")" || return 1
  chmod 0600 "$path" || { rm -f -- "$path"; return 1; }
  printf '%s' "$path"
}

runner_api_result_file_cleanup() {
  local path="$1"
  case "$path" in "$RUNDIR"/api-results/*) rm -f -- "$path" ;; *) return 1 ;; esac
}

runner_api_normalizer_failure() {
  local rc="$1" request_id="${2:-}"
  case "$rc" in
    6) runner_api_fail_unsupported_schema 'controller schema is unsupported' "$request_id" ;;
    7) runner_api_fail_output_too_large 'controller output is too large' "$request_id" ;;
    8) runner_api_fail_backend_unavailable 'Docker inventory is unavailable' "$request_id" ;;
    *) runner_api_fail_backend_unavailable 'controller output is invalid' "$request_id" ;;
  esac
}

runner_api_status() {
  local raw strict helper normalize_rc emit_rc size
  raw="$(runner_api_result_file_create status.raw)" || { runner_api_fail_backend_unavailable 'could not create status buffer' ''; return; }
  strict="$(runner_api_result_file_create status.strict)" || {
    runner_api_result_file_cleanup "$raw" || true
    runner_api_fail_backend_unavailable 'could not create status buffer' ''
    return
  }
  if ! cmd_status_json >"$raw"; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_backend_unavailable 'Docker inventory is unavailable' ''
    return
  fi
  if ! runner_api_private_file_valid "$raw" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    size="$(stat -c %s "$raw" 2>/dev/null || echo 0)"
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$RUNNER_API_MAX_RESPONSE_BYTES" ]; then
      runner_api_fail_output_too_large 'status output is too large' ''
    else
      runner_api_fail_backend_unavailable 'status output is unsafe' ''
    fi
    return
  fi
  helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/api-status.php"
  if /usr/bin/php "$helper" status "$raw" "${INVENTORY_FILE:-}" >"$strict"; then
    :
  else
    normalize_rc=$?
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_normalizer_failure "$normalize_rc" ''
    return
  fi
  if ! runner_api_private_file_valid "$strict" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_output_too_large 'strict status output is too large' ''
    return
  fi
  if runner_api_emit '' true ok 'fleet status' "$strict"; then emit_rc=0; else emit_rc=$?; fi
  runner_api_result_file_cleanup "$raw" || true
  runner_api_result_file_cleanup "$strict" || true
  return "$emit_rc"
}

runner_api_readiness() {
  local raw strict helper normalize_rc emit_rc
  raw="$(runner_api_result_file_create readiness.raw)" || { runner_api_fail_backend_unavailable 'could not create readiness buffer' ''; return; }
  strict="$(runner_api_result_file_create readiness.strict)" || {
    runner_api_result_file_cleanup "$raw" || true
    runner_api_fail_backend_unavailable 'could not create readiness buffer' ''
    return
  }
  if ! cmd_readiness_json >"$raw"; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_backend_unavailable 'readiness is unavailable' ''
    return
  fi
  helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/api-status.php"
  if /usr/bin/php "$helper" readiness "$raw" >"$strict"; then
    :
  else
    normalize_rc=$?
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_normalizer_failure "$normalize_rc" ''
    return
  fi
  if ! runner_api_private_file_valid "$strict" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_output_too_large 'readiness output is too large' ''
    return
  fi
  if runner_api_emit '' true ok 'fleet readiness' "$strict"; then emit_rc=0; else emit_rc=$?; fi
  runner_api_result_file_cleanup "$raw" || true
  runner_api_result_file_cleanup "$strict" || true
  return "$emit_rc"
}

runner_api_auxiliary() {
  local mode="$1" raw strict helper normalize_rc emit_rc message size command_ok=0
  raw="$(runner_api_result_file_create "$mode.raw")" || { runner_api_fail_backend_unavailable 'could not create auxiliary buffer' ''; return; }
  strict="$(runner_api_result_file_create "$mode.strict")" || {
    runner_api_result_file_cleanup "$raw" || true
    runner_api_fail_backend_unavailable 'could not create auxiliary buffer' ''
    return
  }
  case "$mode" in
    queue) if cmd_queued_json >"$raw"; then command_ok=1; fi; message='queue snapshot' ;;
    statistics) if cmd_stats_json >"$raw"; then command_ok=1; fi; message='run statistics' ;;
    cache) if cmd_cache_usage_json >"$raw"; then command_ok=1; fi; message='cache usage' ;;
    image) if cmd_image_info_json >"$raw"; then command_ok=1; fi; message='runner image' ;;
    *) command_ok=0; message='auxiliary data' ;;
  esac
  if [ "$command_ok" -ne 1 ]; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_backend_unavailable "$message is unavailable" ''
    return
  fi
  if ! runner_api_private_file_valid "$raw" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    size="$(stat -c %s "$raw" 2>/dev/null || echo 0)"
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$RUNNER_API_MAX_RESPONSE_BYTES" ]; then
      runner_api_fail_output_too_large "$message output is too large" ''
    else
      runner_api_fail_backend_unavailable "$message output is unsafe" ''
    fi
    return
  fi
  helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/api-auxiliary.php"
  if /usr/bin/php "$helper" "$mode" "$raw" >"$strict"; then
    :
  else
    normalize_rc=$?
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_normalizer_failure "$normalize_rc" ''
    return
  fi
  if ! runner_api_private_file_valid "$strict" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_output_too_large "$message output is too large" ''
    return
  fi
  if runner_api_emit '' true ok "$message" "$strict"; then emit_rc=0; else emit_rc=$?; fi
  runner_api_result_file_cleanup "$raw" || true
  runner_api_result_file_cleanup "$strict" || true
  return "$emit_rc"
}

runner_api_prepare_request() {
  local operation="$1" rc
  if runner_api_capture_request; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      runner_api_fail_invalid_request 'request is too large' ''
    else
      runner_api_fail_backend_unavailable 'could not capture request' ''
    fi
    return
  fi
  if runner_api_parse_fields "$operation"; then
    return 0
  fi
  runner_api_fail_invalid_request 'request fields are invalid' ''
}

runner_api_log() {
  local operation="$1" request_id="${RUNNER_API_FIELDS[0]}" name="" lines mode source message
  local raw strict helper normalize_rc emit_rc command_ok=0 size
  case "$operation" in
    runner-log)
      name="${RUNNER_API_FIELDS[1]}"; lines="${RUNNER_API_FIELDS[2]}"
      mode=plain; source="runner:$name"; message='runner log'
      ;;
    history-log)
      name="${RUNNER_API_FIELDS[1]}"; lines="${RUNNER_API_FIELDS[2]}"
      mode=json; source="history:$name"; message='runner history log'
      ;;
    controller-log)
      lines="${RUNNER_API_FIELDS[1]}"
      mode=json; source=controller; message='controller log'
      ;;
    *) runner_api_fail_invalid_request 'unsupported log operation' "$request_id"; return ;;
  esac
  raw="$(runner_api_result_file_create "$operation.raw")" || {
    runner_api_fail_backend_unavailable 'could not create log buffer' "$request_id"
    return
  }
  strict="$(runner_api_result_file_create "$operation.strict")" || {
    runner_api_result_file_cleanup "$raw" || true
    runner_api_fail_backend_unavailable 'could not create log buffer' "$request_id"
    return
  }
  case "$operation" in
    runner-log) if cmd_logs_tail "$name" "$lines" >"$raw"; then command_ok=1; fi ;;
    history-log) if cmd_history_log "$name" "$lines" >"$raw"; then command_ok=1; fi ;;
    controller-log) if cmd_farm_log "$lines" >"$raw"; then command_ok=1; fi ;;
  esac
  if [ "$command_ok" -ne 1 ]; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    if [ "$operation" = controller-log ]; then
      runner_api_fail_backend_unavailable "$message is unavailable" "$request_id"
    else
      runner_api_fail_invalid_runner "$message is unavailable" "$request_id"
    fi
    return
  fi
  if ! runner_api_private_file_valid "$raw" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    size="$(stat -c %s "$raw" 2>/dev/null || echo 0)"
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$RUNNER_API_MAX_RESPONSE_BYTES" ]; then
      runner_api_fail_output_too_large "$message input is too large" "$request_id"
    else
      runner_api_fail_backend_unavailable "$message input is unsafe" "$request_id"
    fi
    return
  fi
  helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/api-log.php"
  if /usr/bin/php "$helper" "$mode" "$raw" "$lines" "$source" >"$strict"; then
    :
  else
    normalize_rc=$?
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_normalizer_failure "$normalize_rc" "$request_id"
    return
  fi
  if ! runner_api_private_file_valid "$strict" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    runner_api_result_file_cleanup "$raw" || true
    runner_api_result_file_cleanup "$strict" || true
    runner_api_fail_output_too_large "$message output is too large" "$request_id"
    return
  fi
  if runner_api_emit "$request_id" true ok "$message" "$strict"; then emit_rc=0; else emit_rc=$?; fi
  runner_api_result_file_cleanup "$raw" || true
  runner_api_result_file_cleanup "$strict" || true
  return "$emit_rc"
}

runner_api_lifecycle_preflight() {
  local operation="$1" request_id="$2"
  if ! validate_runtime_config >/dev/null 2>&1; then
    runner_api_fail_invalid_config 'runner configuration is invalid' "$request_id"
    return
  fi
  case "$operation" in
    start|restart)
      if ! auth_credentials_configured >/dev/null 2>&1; then
        runner_api_fail_backend_not_ready 'valid GitHub credentials are required' "$request_id"
        return
      fi
      if declare -F migration_load >/dev/null && migration_load >/dev/null 2>&1; then
        case "${MIGRATION_PHASE:-}" in
          classic_active|scaleset_active) ;;
          activating_classic)
            if [ "${MIGRATION_EFFECTIVE_BACKEND:-}" = scaleset ] &&
               [ "${MIGRATION_LAST_BARRIER:-}" = jit_drained ] &&
               declare -F backend_classic_admission_allowed >/dev/null &&
               backend_classic_admission_allowed >/dev/null 2>&1; then
              :
            else
              runner_api_fail_backend_transition 'backend transition blocks fleet start' "$request_id"
              return
            fi
            ;;
          *)
            runner_api_fail_backend_transition 'backend transition blocks fleet start' "$request_id"
            return
            ;;
        esac
      fi
      ;;
  esac
}

runner_api_lifecycle_capture() {
  local log_path="$1"
  shift
  "$@" 2>&1 | tail -c "$RUNNER_API_MAX_LOG_BYTES" >"$log_path"
  return "${PIPESTATUS[0]}"
}

# Called only beneath the dispatch-owned fleet lock.
runner_api_lifecycle_locked() {
  local operation="$1" expected_config="$2" expected_inventory="$3" request_id="$4"
  local log_path rc=0 refresh_ok=0 message
  runner_api_fleet_guard "$expected_config" "$expected_inventory" "$request_id" || return $?
  runner_api_lifecycle_preflight "$operation" "$request_id" || return $?
  log_path="$(runner_api_result_file_create "$operation.lifecycle")" || {
    runner_api_fail_backend_unavailable 'could not create lifecycle log buffer' "$request_id"
    return
  }
  case "$operation" in
    start) runner_api_lifecycle_capture "$log_path" cmd_start || rc=$?; message='fleet started' ;;
    stop) runner_api_lifecycle_capture "$log_path" cmd_stop || rc=$?; message='fleet stopped' ;;
    restart) runner_api_lifecycle_capture "$log_path" cmd_restart || rc=$?; message='fleet restarted' ;;
    *)
      runner_api_result_file_cleanup "$log_path" || true
      runner_api_fail_invalid_request 'unsupported lifecycle operation' "$request_id"
      return
      ;;
  esac
  if fleet_inventory_refresh >/dev/null 2>&1; then refresh_ok=1; fi
  runner_api_result_file_cleanup "$log_path" || true
  if [ "$rc" -eq 0 ] && [ "$refresh_ok" -eq 1 ]; then
    runner_api_emit "$request_id" true ok "$message" @null
    return
  fi
  if [ "$refresh_ok" -ne 1 ]; then
    runner_api_fail_backend_unavailable 'fleet inventory could not be refreshed after lifecycle action' "$request_id"
    return
  fi
  case "$operation:$rc" in
    start:*|restart:11)
      runner_api_fail_resource_capacity 'fleet started with partial capacity' "$request_id"
      ;;
    restart:10)
      runner_api_fail_backend_unavailable 'fleet restart stopped before start phase' "$request_id"
      ;;
    stop:*|restart:*)
      runner_api_fail_backend_unavailable 'fleet lifecycle action failed' "$request_id"
      ;;
    *) runner_api_fail_backend_unavailable 'fleet lifecycle action failed' "$request_id" ;;
  esac
}

runner_api_operation_read() {
  local request_id="${RUNNER_API_FIELDS[0]}" id="${RUNNER_API_FIELDS[1]}" path result emit_rc
  path="$(operation_record_path "$id")" || {
    runner_api_fail_invalid_request 'operation ID is invalid' "$request_id"
    return
  }
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    runner_api_fail_operation_not_found 'operation was not found' "$request_id"
    return
  fi
  result="$(runner_api_result_file_create operation-read.strict)" || {
    runner_api_fail_backend_unavailable 'could not create operation buffer' "$request_id"
    return
  }
  if ! operation_read_public "$id" >"$result"; then
    runner_api_result_file_cleanup "$result" || true
    runner_api_fail_backend_unavailable 'operation record is unavailable' "$request_id"
    return
  fi
  if ! runner_api_private_file_valid "$result" "$RUNNER_API_MAX_RESPONSE_BYTES"; then
    runner_api_result_file_cleanup "$result" || true
    runner_api_fail_output_too_large 'operation output is too large' "$request_id"
    return
  fi
  if runner_api_emit "$request_id" true ok 'operation' "$result"; then emit_rc=0; else emit_rc=$?; fi
  runner_api_result_file_cleanup "$result" || true
  return "$emit_rc"
}

runner_api_reject() {
  runner_api_fail_invalid_request 'unsupported API operation' ''
}

runner_api_dispatch() {
  local operation="${1:-}"
  trap runner_api_cleanup_request EXIT
  case "$operation" in
    status) runner_api_status ;;
    readiness) runner_api_readiness ;;
    queue) runner_api_auxiliary queue ;;
    statistics) runner_api_auxiliary statistics ;;
    cache-usage) runner_api_auxiliary cache ;;
    image) runner_api_auxiliary image ;;
    start|stop|restart)
      runner_api_prepare_request "$operation" || return $?
      with_fleet_lock wait runner_api_lifecycle_locked "$operation" \
        "${RUNNER_API_FIELDS[1]}" "${RUNNER_API_FIELDS[2]}" "${RUNNER_API_FIELDS[0]}"
      ;;
    operation-read)
      runner_api_prepare_request "$operation" || return $?
      runner_api_operation_read
      ;;
    runner-log|history-log|controller-log)
      runner_api_prepare_request "$operation" || return $?
      runner_api_log "$operation"
      ;;
    *) runner_api_reject ;;
  esac
}
