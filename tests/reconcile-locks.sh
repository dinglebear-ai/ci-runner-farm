#!/usr/bin/env bash
# Regression for detached reconciliation launched while the caller owns fd 8.
set -euo pipefail

# reconcile_start launches "$0 reconcile-drain". This probe deliberately keeps
# the outer child shell alive while an inner worker closes its inherited fd 8
# and tries to acquire the same lock, matching the real dispatch structure.
if [ "${1:-}" = "reconcile-drain" ] && [ -n "${CRF_RECONCILE_PROBE_DIR:-}" ]; then
  (
    exec 8>&- 9>&-
    (
      if flock -w 1 8; then
        : > "$CRF_RECONCILE_PROBE_DIR/acquired"
      fi
    ) 8>"$CRF_RECONCILE_PROBE_DIR/fleet.lock"
  )
  exit 0
fi

cd "$(dirname "$0")/.."
ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmpdir="$(mktemp -d)"
trap 'if [ -f "$tmpdir/reconcile.pid" ]; then kill "$(cat "$tmpdir/reconcile.pid")" 2>/dev/null || true; fi; rm -rf "$tmpdir"' EXIT

sed -n '/^reconcile_pid_active()/,/^}/p' "$ENGINE" > "$tmpdir/reconcile-start.sh"
sed -n '/^reconcile_start()/,/^}/p' "$ENGINE" >> "$tmpdir/reconcile-start.sh"
# shellcheck disable=SC1090,SC1091 # extracted from the tested engine above
. "$tmpdir/reconcile-start.sh"

export CRF_RECONCILE_PROBE_DIR="$tmpdir"
RUNDIR="$tmpdir"
RECONCILE_PID="$tmpdir/reconcile.pid"

# Model with_fleet_lock: the caller owns fd 8 when reconcile_start detaches its
# child, then returns and closes its own descriptor. The detached child must not
# retain that lock across its outer dispatch shell.
exec 8>"$tmpdir/fleet.lock"
flock 8
reconcile_start
exec 8>&-

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$tmpdir/acquired" ] && break
  sleep 0.2
done
[ -f "$tmpdir/acquired" ] || {
  echo "FAIL: detached reconcile child inherited fd 8 and deadlocked on fleet.lock" >&2
  exit 1
}

echo 'reconcile-locks: OK'

# A live but unrelated/reused PID must not suppress a new drain.
rm -f "$tmpdir/acquired"
sleep 30 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" > "$RECONCILE_PID"
reconcile_start
replacement_pid="$(cat "$RECONCILE_PID")"
[ "$replacement_pid" != "$unrelated_pid" ] || {
  echo 'FAIL: unrelated live PID was accepted as the reconcile worker' >&2
  exit 1
}
kill "$unrelated_pid" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$tmpdir/acquired" ] && break
  sleep 0.2
done
[ -f "$tmpdir/acquired" ] || {
  echo 'FAIL: stale/reused reconcile PID prevented a replacement worker' >&2
  exit 1
}
grep -Fq "trap 'rm -f \"\$RECONCILE_PID\"' EXIT INT TERM" "$ENGINE" || {
  echo 'FAIL: reconcile worker does not clean its PID file on abnormal exit' >&2
  exit 1
}

echo 'reconcile-pid-identity: OK'

# The resource-aware start path must release fd 8 around slow Docker/GitHub
# work, then reacquire it before finalizing the reservation.
sed -n '/^fleet_lock_suspend()/,/^}/p' "$ENGINE" > "$tmpdir/lock-suspend.sh"
sed -n '/^fleet_lock_resume()/,/^}/p' "$ENGINE" >> "$tmpdir/lock-suspend.sh"
# shellcheck disable=SC1090
. "$tmpdir/lock-suspend.sh"
RUNDIR="$tmpdir"
err() { printf '%s\n' "$*" >&2; }
(
  exec 8>"$tmpdir/fleet.lock"
  flock 8
  fleet_lock_suspend
  ( flock -w 1 9 ) 9>"$tmpdir/fleet.lock" || exit 8
  fleet_lock_resume
  if ( flock -n 9 ) 9>"$tmpdir/fleet.lock"; then exit 9; fi
) || {
  echo "FAIL: fleet lock was not suspended/resumed around slow work" >&2
  exit 1
}

echo 'resource-locks: OK'

# A busy retiring identity must not block an idle retiring peer later in the
# inventory. Reconciliation still mutates at most one runner per pass.
sed -n '/^reconcile_stale_runners()/,/^}/p' "$ENGINE" > "$tmpdir/reconcile-stale.sh"
(
  # shellcheck disable=SC1090
  . "$tmpdir/reconcile-stale.sh"
  validate_runtime_config() { return 0; }
  cleanup_pool_runtime_state() { :; }
  fleet_inventory_refresh() { return 0; }
  crf_confgen_prepare() { :; }
  pool_mode_enabled() { return 0; }
  count_pool_missing_capacity() { echo 0; }
  managed_names() { printf '%s\n' ci-runner-old-busy ci-runner-old-idle; }
  runner_identity_validate() { return 0; }
  runner_pool() { echo removed-pool; }
  pool_record() { return 1; }
  inventory_field() { echo running; }
  runner_state() {
    case "$1" in
      ci-runner-old-busy) echo busy ;;
      ci-runner-old-idle) echo idle ;;
    esac
  }
  remove_runner() { printf '%s\n' "$1" >"$tmpdir/retired"; }
  start_one_missing_desired() { :; }
  log() { :; }
  reconcile_stale_runners
)
[ "$(cat "$tmpdir/retired" 2>/dev/null)" = ci-runner-old-idle ] || {
  echo "FAIL: busy retiring runner blocked an idle retiring peer" >&2
  exit 1
}

echo 'reconcile-retiring-fairness: OK'

# GitHub may transiently report an actively working stale runner as idle. Its
# graceful recycle must refuse without starving a later stale runner that is
# genuinely idle. Reconciliation still mutates at most one runner per pass.
(
  # shellcheck disable=SC1090
  . "$tmpdir/reconcile-stale.sh"
  validate_runtime_config() { return 0; }
  cleanup_pool_runtime_state() { :; }
  fleet_inventory_refresh() { return 0; }
  crf_confgen_prepare() { :; }
  pool_mode_enabled() { return 0; }
  count_pool_missing_capacity() { echo 0; }
  provision_base() { :; }
  managed_names() { printf '%s
' ci-runner-refused ci-runner-idle; }
  runner_identity_validate() { return 0; }
  runner_pool() { echo rust; }
  pool_record() { return 0; }
  pool_records() { :; }
  inventory_field() { echo running; }
  runner_state() { echo idle; }
  crf_confgen() { echo current; }
  runner_confgen() { echo stale; }
  runner_authoritatively_failed() { return 1; }
  recreate_runner() {
    printf '%s
' "$1" >>"$tmpdir/recycle-attempts"
    [ "$1" = ci-runner-refused ] && return 1
    printf '%s
' "$1" >"$tmpdir/recycled"
  }
  docker() {
    [ "$1" = ps ] && printf '%s
' ci-runner-refused
  }
  start_one_missing_desired() { :; }
  log() { :; }
  GH_OWNER=dinglebear-ai
  RUNDIR="$tmpdir"
  reconcile_stale_runners
)
[ "$(cat "$tmpdir/recycled" 2>/dev/null)" = ci-runner-idle ] || {
  echo "FAIL: refused stale runner blocked a later idle stale runner" >&2
  exit 1
}
[ "$(wc -l < "$tmpdir/recycle-attempts")" -eq 2 ] || {
  echo "FAIL: stale reconciliation did not inspect exactly the refused and idle runners" >&2
  exit 1
}

echo 'reconcile-stale-refusal-fairness: OK'


# A stale, reused, or unrelated PID must not suppress reconciliation. Only a
# live process whose argv contains the exact reconcile-drain subcommand owns the
# PID file.
sed -n '/^reconcile_pid_active()/,/^}/p' "$ENGINE" > "$tmpdir/reconcile-pid-active.sh"
# shellcheck disable=SC1090
. "$tmpdir/reconcile-pid-active.sh"
RECONCILE_PID="$tmpdir/reconcile.pid"

printf '99999999\n' > "$RECONCILE_PID"
if reconcile_pid_active; then
  echo "FAIL: dead reconcile PID was accepted" >&2
  exit 1
fi

sleep 30 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" > "$RECONCILE_PID"
if reconcile_pid_active; then
  kill "$unrelated_pid" 2>/dev/null || true
  echo "FAIL: unrelated live PID was accepted as reconcile worker" >&2
  exit 1
fi
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true

bash -c 'exec -a reconcile-drain sleep 30' &
worker_pid=$!
printf '%s\n' "$worker_pid" > "$RECONCILE_PID"
for _ in 1 2 3 4 5; do
  reconcile_pid_active && break
  sleep 0.05
done
if ! reconcile_pid_active; then
  kill "$worker_pid" 2>/dev/null || true
  echo "FAIL: live reconcile worker was rejected" >&2
  exit 1
fi
kill "$worker_pid" 2>/dev/null || true
wait "$worker_pid" 2>/dev/null || true

grep -Fq 'trap '\''rm -f "$RECONCILE_PID"'\'' EXIT INT TERM' "$ENGINE" || {
  echo "FAIL: reconcile drain does not clean its PID file on every exit" >&2
  exit 1
}

echo 'reconcile-pid-ownership: OK'
