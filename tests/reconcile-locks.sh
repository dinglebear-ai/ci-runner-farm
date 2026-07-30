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

sed -n '/^reconcile_start()/,/^}/p' "$ENGINE" > "$tmpdir/reconcile-start.sh"
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
