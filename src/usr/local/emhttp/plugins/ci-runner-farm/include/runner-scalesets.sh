#!/bin/bash
# Scale-set helper lifecycle. The helper remains fail-closed until a fresh,
# packaged-identity-bound compatibility record exists.

SCALESET_HELPER="${SCALESET_HELPER:-$SCRIPT_DIR/../bin/crf-scaleset}"
SCALESET_STATE_DIR="${SCALESET_STATE_DIR:-$RUNDIR/scalesets}"
SCALESET_PID="${SCALESET_PID:-$SCALESET_STATE_DIR/supervisor.pid}"
SCALESET_SOCKET="${SCALESET_SOCKET:-$SCALESET_STATE_DIR/supervisor.sock}"
SCALESET_COMPAT="${SCALESET_COMPAT:-$CFGDIR/scaleset-compatibility.json}"

scaleset_record_fresh() {
  [ -f "$SCALESET_COMPAT" ] && [ "$(stat -c %a "$SCALESET_COMPAT" 2>/dev/null)" = 600 ] || return 1
  local age
  age=$(( $(date +%s) - $(stat -c %Y "$SCALESET_COMPAT" 2>/dev/null || echo 0) ))
  [ "$age" -ge 0 ] && [ "$age" -le 2592000 ] || return 1
  php -r '$j=json_decode(file_get_contents($argv[1]),true);exit(is_array($j)&&($j["cleanup"]["complete"]??false)===true&&($j["capabilities"]["eligibility_barrier"]??false)===true?0:1);' "$SCALESET_COMPAT"
}

scaleset_supervisor_start() {
  [ -x "$SCALESET_HELPER" ] || { err "scale-set helper is unavailable"; return 1; }
  scaleset_record_fresh || { err "scale-set compatibility evidence is missing, stale, or incomplete"; return 1; }
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

scaleset_supervisor_status() {
  if [ -f "$SCALESET_PID" ] && kill -0 "$(cat "$SCALESET_PID" 2>/dev/null)" 2>/dev/null; then
    printf 'running\n'
  else printf 'stopped\n'; fi
}
