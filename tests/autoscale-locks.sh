#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

sed -n '/^autoscale_tick()/,/^}/p' "$ENGINE" >"$tmpdir/autoscale-tick.sh"
# shellcheck disable=SC1090
. "$tmpdir/autoscale-tick.sh"

RUNDIR="$tmpdir/run"
mkdir -p "$RUNDIR"
executions="$tmpdir/executions"
started="$tmpdir/started"
release="$tmpdir/release"
logfile="$tmpdir/log"

log() { printf '%s
' "$*" >>"$logfile"; }
_autoscale_tick() {
  printf 'start
' >>"$executions"
  : >"$started"
  for _ in $(seq 1 500); do
    [ -f "$release" ] && break
    sleep 0.01
  done
  [ -f "$release" ] || return 1
  printf 'done
' >>"$executions"
}

autoscale_tick &
first=$!
for _ in $(seq 1 100); do
  [ -f "$started" ] && break
  sleep 0.01
done
[ -f "$started" ] || { echo 'first autoscale tick did not start' >&2; exit 1; }

# A concurrent operator or daemon tick must skip immediately rather than queue
# behind remote IPC and later replay stale scheduling work. The first tick stays
# blocked behind an explicit test barrier so this assertion never depends on a
# scheduler-sized sleep window.
autoscale_tick
: >"$release"
wait "$first"

[ "$(grep -c '^start$' "$executions")" -eq 1 ] || {
  echo 'duplicate autoscale tick entered the critical section' >&2
  exit 1
}
[ "$(grep -c '^done$' "$executions")" -eq 1 ]
grep -Fq 'tick already running; skipping duplicate' "$logfile"
[ "$(stat -c %a "$RUNDIR/autoscale.tick.lock")" = 600 ]

echo 'autoscale-locks: OK'
