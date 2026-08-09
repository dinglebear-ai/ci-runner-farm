#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmpdir="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

for fn in kache_supervisor_pids kache_daemon_running kache_daemon_identity_valid kache_daemon_reset kache_daemon_miss_file kache_daemon_miss_reset kache_daemon_miss_increment kache_supervisor_reconcile; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >>"$tmpdir/health-functions.sh"
done
# shellcheck disable=SC1090
. "$tmpdir/health-functions.sh"

declare -A supervisor_state=([healthy]=1 [stuck]=1 [duplicate]=3 [flaky]=1)
declare -A daemon_state=([healthy]=1 [stuck]=0 [duplicate]=1 [flaky]=0)
launches="$tmpdir/launches"
kills="$tmpdir/kills"
logs="$tmpdir/logs"
RUNDIR="$tmpdir/run"
KACHE_WATCHDOG_DAEMON_MISS_THRESHOLD=3
mkdir -p "$RUNDIR"

fleet_inventory_refresh() { return 0; }
managed_names() { printf '%s\n' healthy stuck duplicate flaky; }
runner_identity_validate() { return 0; }
log() { printf '%s\n' "$*" >>"$logs"; }
kill() {
  local pid="${1:-}"
  printf '%s\n' "$pid" >>"$kills"
  case "$pid" in
    201) supervisor_state[stuck]=0 ;;
    302|303) supervisor_state[duplicate]=$((supervisor_state[duplicate] - 1)) ;;
  esac
  return 0
}
docker() {
  local cmd="$1" c count base i
  shift
  case "$cmd" in
    top)
      c="$1"
      printf 'PID COMMAND\n'
      count="${supervisor_state[$c]}"
      case "$c" in healthy) base=100 ;; stuck) base=200 ;; duplicate) base=300 ;; flaky) base=400 ;; esac
      for i in $(seq 1 "$count"); do
        printf '%s /bin/bash /usr/local/bin/kache-supervise.sh   \n' "$((base + i))"
      done
      if [ "${daemon_state[$c]}" = 1 ]; then
        printf '900 /opt/hostedtoolcache/kache/0.13.0/x64/kache daemon run   \n'
      fi
      return 0
      ;;
    inspect) printf 'true\n' ;;
    exec)
      if [ "${1:-}" = -d ]; then
        printf '%s\n' "$*" >>"$launches"
        c="${4:-}"
        supervisor_state[$c]=1
        daemon_state[$c]=1
        return 0
      fi
      return 0
      ;;
    *) return 99 ;;
  esac
}

kache_supervisor_reconcile
[ ! -e "$launches" ] || { echo 'FAIL: one daemon miss restarted a supervisor' >&2; exit 1; }
grep -Fxq 'kache-watchdog: daemon missing in stuck; waiting for 3 consecutive samples' "$logs"
grep -Fxq 'kache-watchdog: daemon missing in flaky; waiting for 3 consecutive samples' "$logs"
daemon_state[flaky]=1
kache_supervisor_reconcile
[ ! -e "$launches" ] || { echo 'FAIL: two daemon misses restarted a supervisor' >&2; exit 1; }
[ ! -e "$RUNDIR/kache-daemon-misses/flaky" ] || { echo 'FAIL: recovered daemon retained a miss counter' >&2; exit 1; }
kache_supervisor_reconcile
kache_supervisor_reconcile
[ "$(wc -l <"$launches")" -eq 1 ]
grep -Fxq -- '-d -u runner stuck env -i HOME=/home/runner PATH=/usr/local/bin:/usr/bin:/bin KACHE_CACHE_DIR=/_work/.kache /bin/bash /usr/local/bin/kache-supervise.sh' "$launches"
[ "$(sort -n "$kills" | tr '\n' ' ' | xargs)" = '201 302 303' ] || {
  echo 'FAIL: watchdog killed the wrong supervisor PIDs' >&2
  cat "$kills" >&2
  exit 1
}
[ ! -e "$RUNDIR/kache-daemon-misses/stuck" ] || { echo 'FAIL: restarted daemon retained a miss counter' >&2; exit 1; }
grep -Fxq 'kache-watchdog: restarting unhealthy supervisor in stuck after 3 daemon misses' "$logs"
grep -Fxq 'kache-watchdog: restored supervisor in stuck' "$logs"
grep -Fxq 'kache-watchdog: removed 2 duplicate supervisor(s) from duplicate' "$logs"
unset -f docker kill

# TERM must end the daemon loop; merely removing the PID file is not a stop.
sed -n '/^kache_watchdog_daemon()/,/^}/p' "$ENGINE" >"$tmpdir/daemon-function.sh"
# shellcheck disable=SC1090
. "$tmpdir/daemon-function.sh"
KACHE_WATCHDOG_PID="$tmpdir/watchdog.pid"
KACHE_WATCHDOG_INTERVAL=0.1
daemon_log="$tmpdir/daemon.log"
load_cfg() { :; }
kache_supervisor_reconcile() { :; }
watchdog_calls="$tmpdir/watchdog-calls"
with_fleet_lock() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >>"$watchdog_calls"; }
log() { printf '%s\n' "$*" >>"$daemon_log"; }
( kache_watchdog_daemon ) &
daemon_pid=$!
printf '%s\n' "$daemon_pid" >"$KACHE_WATCHDOG_PID"
for _ in $(seq 1 20); do
  grep -Fq 'kache-watchdog: daemon started' "$daemon_log" 2>/dev/null && break
  sleep 0.05
done
grep -Fq 'kache-watchdog: daemon started' "$daemon_log"
for _ in $(seq 1 20); do
  [ -s "$watchdog_calls" ] && break
  sleep 0.05
done
grep -Fxq 'try|recover_stalled_credential_handoffs|reuse' "$watchdog_calls" || {
  echo 'FAIL: watchdog did not run credential recovery under the nonblocking fleet lock' >&2
  exit 1
}
command kill -TERM "$daemon_pid"
for _ in $(seq 1 20); do
  command kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.05
done
if command kill -0 "$daemon_pid" 2>/dev/null; then
  echo 'FAIL: watchdog daemon ignored TERM' >&2
  command kill -KILL "$daemon_pid" 2>/dev/null || true
  exit 1
fi
wait "$daemon_pid" 2>/dev/null || true
[ ! -f "$KACHE_WATCHDOG_PID" ]

echo 'kache-supervisor-health: OK'
