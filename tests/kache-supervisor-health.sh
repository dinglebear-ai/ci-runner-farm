#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmpdir="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

sed -n '/^kache_supervisor_pids()/,/^}/p' "$ENGINE" >"$tmpdir/health-functions.sh"
sed -n '/^kache_daemon_running()/,/^}/p' "$ENGINE" >>"$tmpdir/health-functions.sh"
sed -n '/^kache_supervisor_reconcile()/,/^}/p' "$ENGINE" >>"$tmpdir/health-functions.sh"
# shellcheck disable=SC1090
. "$tmpdir/health-functions.sh"

declare -A supervisor_state=([healthy]=1 [stuck]=1 [duplicate]=3)
declare -A daemon_state=([healthy]=1 [stuck]=0 [duplicate]=1)
launches="$tmpdir/launches"
kills="$tmpdir/kills"
logs="$tmpdir/logs"

fleet_inventory_refresh() { return 0; }
managed_names() { printf '%s\n' healthy stuck duplicate; }
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
      case "$c" in healthy) base=100 ;; stuck) base=200 ;; duplicate) base=300 ;; esac
      for i in $(seq 1 "$count"); do
        printf '%s /bin/bash /usr/local/bin/kache-supervise.sh   \n' "$((base + i))"
      done
      [ "${daemon_state[$c]}" = 1 ] &&
        printf '900 /opt/hostedtoolcache/kache/0.13.0/x64/kache daemon run   \n'
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
kache_supervisor_reconcile
[ "$(wc -l <"$launches")" -eq 1 ]
grep -Fxq -- '-d -u runner stuck env -i HOME=/home/runner PATH=/usr/local/bin:/usr/bin:/bin KACHE_CACHE_DIR=/_work/.kache /bin/bash /usr/local/bin/kache-supervise.sh' "$launches"
[ "$(sort -n "$kills" | tr '\n' ' ' | xargs)" = '201 302 303' ] || {
  echo 'FAIL: watchdog killed the wrong supervisor PIDs' >&2
  cat "$kills" >&2
  exit 1
}
grep -Fxq 'kache-watchdog: restarting unhealthy supervisor in stuck (daemon missing)' "$logs"
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
log() { printf '%s\n' "$*" >>"$daemon_log"; }
( kache_watchdog_daemon ) &
daemon_pid=$!
printf '%s\n' "$daemon_pid" >"$KACHE_WATCHDOG_PID"
for _ in $(seq 1 20); do
  grep -Fq 'kache-watchdog: daemon started' "$daemon_log" 2>/dev/null && break
  sleep 0.05
done
grep -Fq 'kache-watchdog: daemon started' "$daemon_log"
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
