#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmpdir="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

# Exercise the live reconcile functions with a fake Docker surface. A valid
# running container that lost only kache-supervise.sh must be repaired once;
# healthy, stopped, invalid, and incompatible containers must be untouched.
sed -n '/^kache_supervisor_pids()/,/^}/p' "$ENGINE" >"$tmpdir/functions.sh"
sed -n '/^kache_supervisor_running()/,/^}/p' "$ENGINE" >>"$tmpdir/functions.sh"
sed -n '/^kache_daemon_running()/,/^}/p' "$ENGINE" >>"$tmpdir/functions.sh"
sed -n '/^kache_daemon_identity_valid()/,/^}/p' "$ENGINE" >>"$tmpdir/functions.sh"
sed -n '/^kache_daemon_reset()/,/^}/p' "$ENGINE" >>"$tmpdir/functions.sh"
sed -n '/^kache_supervisor_reconcile()/,/^}/p' "$ENGINE" >>"$tmpdir/functions.sh"
# shellcheck disable=SC1090
. "$tmpdir/functions.sh"

declare -A supervisor=(
  [runner-ok]=1
  [runner-missing]=0
  [runner-stopped]=0
  [runner-invalid]=0
  [runner-no-script]=0
  [runner-foreign]=1
)
declare -A daemon=(
  [runner-ok]=1
  [runner-missing]=1
  [runner-stopped]=0
  [runner-invalid]=0
  [runner-no-script]=0
  [runner-foreign]=1
)
launches="$tmpdir/launches"
resets="$tmpdir/resets"
logs="$tmpdir/logs"

fleet_inventory_refresh() { return 0; }
managed_names() { printf '%s\n' runner-ok runner-missing runner-stopped runner-invalid runner-no-script runner-foreign; }
runner_identity_validate() { [ "$1" != runner-invalid ]; }
log() { printf '%s\n' "$*" >>"$logs"; }
kache_daemon_miss_reset() { :; }
kache_daemon_miss_increment() { printf '1\n'; }
docker() {
  local cmd="$1" c operation
  shift
  case "$cmd" in
    top)
      c="$1"
      printf 'PID COMMAND\n'
      [ "${supervisor[$c]:-0}" = 1 ] && printf '123 bash /usr/local/bin/kache-supervise.sh   \n'
      [ "${daemon[$c]:-0}" = 1 ] && printf '900 /opt/hostedtoolcache/kache/0.13.0/x64/kache daemon run   \n'
      ;;
    inspect)
      c="${@: -1}"
      [ "$c" = runner-stopped ] && printf 'false\n' || printf 'true\n'
      ;;
    exec)
      if [ "${1:-}" = -d ]; then
        printf '%s\n' "$*" >>"$launches"
        c="${4:-}"
        supervisor[$c]=1
        daemon[$c]=1
        return 0
      fi
      if [ "${1:-}" = -i ]; then
        c="${2:-}"; operation="${6:-}"
        case "$operation" in
          identity) [ "$c" != runner-foreign ] ;;
          reset) printf '%s\n' "$c" >>"$resets"; daemon[$c]=0 ;;
          *) return 99 ;;
        esac
        return
      fi
      c="${1:-}"
      [ "$c" != runner-no-script ]
      ;;
    *) return 99 ;;
  esac
}

kache_supervisor_reconcile
kache_supervisor_reconcile
[ "$(wc -l <"$launches")" -eq 1 ] || {
  echo 'FAIL: missing Kache supervisor was not repaired exactly once' >&2
  cat "$launches" >&2
  exit 1
}
grep -Fxq -- '-d -u runner runner-missing env -i HOME=/home/runner PATH=/usr/local/bin:/usr/bin:/bin KACHE_CACHE_DIR=/_work/.kache /bin/bash /usr/local/bin/kache-supervise.sh' "$launches" || {
  echo 'FAIL: watchdog launch did not use the clean runner-owned environment' >&2
  cat "$launches" >&2
  exit 1
}
grep -Fxq 'kache-watchdog: restored supervisor in runner-missing' "$logs"
crf_reset="$(cat "$resets" 2>/dev/null)"
[ "$crf_reset" = runner-foreign ] || {
  echo 'FAIL: foreign Kache daemon was not reset exactly once' >&2
  cat "$resets" >&2 2>/dev/null || true
  exit 1
}
grep -Fxq 'kache-watchdog: reset foreign or duplicate daemon in runner-foreign' "$logs"

# A live PID is not enough to own the singleton PID file: argv must identify the
# exact runner-farm watchdog action, preventing stale PID reuse from suppressing
# watchdog startup.
sed -n '/^kache_watchdog_pid_active()/,/^}/p' "$ENGINE" >"$tmpdir/pid-functions.sh"
sed -n '/^kache_watchdog_daemon_pids()/,/^}/p' "$ENGINE" >>"$tmpdir/pid-functions.sh"
sed -n '/^kache_watchdog_stop()/,/^}/p' "$ENGINE" >>"$tmpdir/pid-functions.sh"
# shellcheck disable=SC1090
. "$tmpdir/pid-functions.sh"

KACHE_WATCHDOG_PROC_ROOT="$tmpdir/proc"
KACHE_WATCHDOG_PID="$tmpdir/watchdog.pid"
mkdir -p "$KACHE_WATCHDOG_PROC_ROOT"
sleep 30 &
live=$!
mkdir -p "$KACHE_WATCHDOG_PROC_ROOT/$live"
printf '/bin/bash\0/tmp/runner-farm.sh\0unrelated-action\0' >"$KACHE_WATCHDOG_PROC_ROOT/$live/cmdline"
printf '%s\n' "$live" >"$KACHE_WATCHDOG_PID"
if kache_watchdog_pid_active; then
  echo 'FAIL: unrelated live PID was accepted as Kache watchdog' >&2
  exit 1
fi
kache_watchdog_stop
kill -0 "$live" 2>/dev/null || {
  echo 'FAIL: watchdog stop killed an unrelated reused PID' >&2
  exit 1
}
[ ! -f "$KACHE_WATCHDOG_PID" ]
printf '%s\n' "$live" >"$KACHE_WATCHDOG_PID"
printf '/bin/bash\0/tmp/runner-farm.sh\0kache-watchdog-daemon\0' >"$KACHE_WATCHDOG_PROC_ROOT/$live/cmdline"
kache_watchdog_pid_active || {
  echo 'FAIL: exact live Kache watchdog PID was rejected' >&2
  exit 1
}
mkdir -p "$KACHE_WATCHDOG_PROC_ROOT/111" "$KACHE_WATCHDOG_PROC_ROOT/222"
printf '/bin/bash\0/tmp/runner-farm.sh\0kache-watchdog-daemon\0' >"$KACHE_WATCHDOG_PROC_ROOT/111/cmdline"
printf '/bin/bash\0/tmp/runner-farm.sh\0autoscale-daemon\0' >"$KACHE_WATCHDOG_PROC_ROOT/222/cmdline"
actual_pids="$(kache_watchdog_daemon_pids | sort -n | tr '\n' ' ' | xargs)"
expected_pids="$(printf '%s\n' 111 "$live" | sort -n | tr '\n' ' ' | xargs)"
[ "$actual_pids" = "$expected_pids" ] || {
  echo 'FAIL: watchdog process enumeration was not exact' >&2
  printf 'expected: %s\nactual:   %s\n' "$expected_pids" "$actual_pids" >&2
  exit 1
}
rm -rf "$KACHE_WATCHDOG_PROC_ROOT/111" "$KACHE_WATCHDOG_PROC_ROOT/222"
kache_watchdog_stop
wait "$live" 2>/dev/null || true
if kill -0 "$live" 2>/dev/null; then
  echo 'FAIL: exact watchdog process survived watchdog stop' >&2
  exit 1
fi

# Lifecycle contract: watchdog is independent of autoscaling, starts for both
# classic and scale-set fleets, stops before teardown, and is operator-visible.
[ "$(grep -Fc 'kache_watchdog_start || true' "$ENGINE")" -eq 2 ]
sed -n '/^cmd_stop()/,/^}/p' "$ENGINE" | grep -Fq 'kache_watchdog_stop'
grep -Fq 'kache-watchdog-daemon) kache_watchdog_daemon' "$ENGINE"
grep -Fq 'with_fleet_lock try recover_stalled_credential_handoffs reuse' "$ENGINE"
grep -Fq 'kache-watchdog-status) kache_watchdog_status' "$ENGINE"
grep -Fq 'flock -w 10 7' "$ENGINE"
grep -Fq '7>&- 8>&- 9>&-' "$ENGINE"
grep -Fq 'chmod 0600 "$KACHE_WATCHDOG_PID"' "$ENGINE"

echo 'kache-supervisor-watchdog: OK'
