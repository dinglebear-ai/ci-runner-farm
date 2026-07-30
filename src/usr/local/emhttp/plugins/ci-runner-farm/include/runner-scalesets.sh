#!/bin/bash
# Scale-set helper lifecycle. The helper remains fail-closed until a fresh,
# packaged-identity-bound compatibility record exists.

SCALESET_HELPER="${SCALESET_HELPER:-$SCRIPT_DIR/../bin/crf-scaleset}"
SCALESET_STATE_DIR="${SCALESET_STATE_DIR:-$RUNDIR/scalesets}"
SCALESET_PID="${SCALESET_PID:-$SCALESET_STATE_DIR/supervisor.pid}"
SCALESET_SOCKET="${SCALESET_SOCKET:-$SCALESET_STATE_DIR/supervisor.sock}"
SCALESET_COMPAT="${SCALESET_COMPAT:-$CFGDIR/scaleset-compatibility.json}"
GITHUB_APP_TOKEN_FILE="${GITHUB_APP_TOKEN_FILE:-$SCALESET_STATE_DIR/github-app-installation.token}"

scaleset_record_fresh() {
  [ "$(scaleset_record_reason)" = valid ]
}

scaleset_record_valid() {
  [ "$(scaleset_record_reason)" = valid ]
}

scaleset_record_reason() {
  local output reason
  [ -f "$SCALESET_COMPAT" ] || { printf 'compatibility_record_missing\n'; return; }
  [ ! -L "$SCALESET_COMPAT" ] || { printf 'compatibility_record_symlink\n'; return; }
  [ -x "$SCALESET_HELPER" ] || { printf 'helper_unavailable\n'; return; }
  if output="$("$SCALESET_HELPER" check-compatibility --path "$SCALESET_COMPAT" 2>/dev/null)"; then
    printf 'valid\n'
    return
  fi
  reason="$(printf '%s' "$output" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $v=is_array($j)?($j["error"]??""):"";
    echo is_string($v)&&preg_match("/^[A-Za-z0-9_.:-]{1,128}$/",$v)?$v:"invalid_compatibility_record";
  ' 2>/dev/null)" || reason=invalid_compatibility_record
  printf '%s\n' "${reason:-invalid_compatibility_record}"
}

scaleset_supervisor_start() {
  [ -x "$SCALESET_HELPER" ] || { err "scale-set helper is unavailable"; return 1; }
  scaleset_record_valid || { err "scale-set compatibility evidence is missing, stale, incomplete, or mismatched"; return 1; }
  mkdir -p "$SCALESET_STATE_DIR" && chmod 0700 "$SCALESET_STATE_DIR" || return 1
  if [ -f "$SCALESET_PID" ] && kill -0 "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null; then return 0; fi
  nohup "$SCALESET_HELPER" supervise --socket "$SCALESET_SOCKET" --compatibility "$SCALESET_COMPAT" \
    >>"$SCALESET_STATE_DIR/supervisor.log" 2>&1 &
  printf '%s\n' "$!" > "$SCALESET_PID"
  chmod 0600 "$SCALESET_PID"
}

scaleset_supervisor_stop() {
  [ -f "$SCALESET_PID" ] && kill "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null || true
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
  if output="$("$SCALESET_HELPER" probe 2>&1)"; then
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
  local id="$1" path="$SCALESET_STATE_DIR/operations/$id.json"
  scaleset_operation_id_valid "$id" && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cat "$path"
}

scaleset_supervisor_status() {
  if [ -f "$SCALESET_PID" ] && kill -0 "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null; then
    printf 'running\n'
  else printf 'stopped\n'; fi
}

scaleset_prepare_ineligible() {
  [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ] || {
    err "scale-set remote ineligibility operation is not yet compatibility-proven"
    return 1
  }
}
scaleset_activate_eligible() {
  [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ] || {
    err "scale-set eligibility operation is not yet compatibility-proven"
    return 1
  }
}
scaleset_make_ineligible() {
  [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ] || {
    err "scale-set remote ineligibility operation is unavailable"
    return 1
  }
}
scaleset_delete_owned() {
  [ "${CRF_MIGRATION_TEST_GATES:-0}" = 1 ] || {
    err "exact-ID scale-set deletion is unavailable"
    return 1
  }
}
