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

runner_api_reject() {
  printf '%s\n' '{"schema_version":1,"request_id":"","ok":false,"code":"invalid_request","message":"unsupported API operation","result":null,"observed":{"config_revision":"","inventory_revision":"","transition_revision":"","ownership_revision":"","compatibility_record_id":"","credential_revision":null}}'
  return 2
}

runner_api_dispatch() {
  local operation="${1:-}"
  trap runner_api_cleanup_request EXIT
  case "$operation" in
    *) runner_api_reject ;;
  esac
}
