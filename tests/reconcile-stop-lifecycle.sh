#!/usr/bin/env bash
# Reconcile Stop owns one exact worker session and leaves no lock-holding descendants.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"

extract_function() {
  local name="$1" output="$2"
  sed -n "/^${name}()/,/^}/p" "$ENGINE" >>"$output"
}

if [ "${1:-}" = reconcile-drain ] && [ -n "${CRF_RECONCILE_STOP_TMPDIR:-}" ]; then
  tmpdir="$CRF_RECONCILE_STOP_TMPDIR"
  worker_functions="$tmpdir/reconcile-worker.sh"
  : >"$worker_functions"
  extract_function with_fleet_lock "$worker_functions"
  extract_function reconcile_identity_clear "$worker_functions"
  extract_function cmd_reconcile_drain "$worker_functions"
  # shellcheck disable=SC1090
  . "$worker_functions"

  load_cfg() { :; }
  count_reconcile_work() { echo 1; }
  mutation_owner_guard() { return 0; }
  reconcile_stale_runners() {
    if [ "${CRF_RECONCILE_HOLD_FLEET_LOCK:-0}" = 1 ]; then
      : >"$tmpdir/fleet-lock-held"
      sleep 120
      return
    fi
    if [ -e "$tmpdir/stop-issued" ]; then
      : >"$tmpdir/capacity-recreated-after-stop"
    fi
  }
  managed_names() { echo ci-runner-retiring; }
  runner_pool() { echo removed-pool; }
  pool_mode_enabled() { return 0; }
  pool_record() { return 1; }
  count_pool_desired_drift() { echo 0; }
  count_pool_missing_capacity() { echo 0; }
  count_stale_runners() { echo 1; }
  log() {
    case "$*" in
      *'retries continue every 120s'*) : >"$tmpdir/post-timeout-retry" ;;
    esac
  }
  # Advance the synthetic deadline immediately while preserving the production
  # external `sleep 120` process and real inherited lock descriptors.
  date() {
    if [ -e "$tmpdir/date-called" ]; then echo 2
    else : >"$tmpdir/date-called"; echo 0
    fi
  }

  RUNDIR="$tmpdir/run"
  RECONCILE_PID="$RUNDIR/reconcile.pid"
  RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
  ACCESS_TOKEN="test"
  IMAGE_DRAIN_TIMEOUT=1
  ( flock -w 5 7 || exit 1; cmd_reconcile_drain ) 7>"$RUNDIR/reconcile.lock"
  exit 0
fi

tmpdir="$(mktemp -d)"
worker_pid=""
unrelated_pid=""
test_pgid="$(ps -o pgid= -p "$$" | tr -d '[:space:]')"
assert_worker_isolated() {
  local target="$1" actual_pgid actual_sid
  actual_pgid="$(ps -o pgid= -p "$target" 2>/dev/null | tr -d '[:space:]')"
  actual_sid="$(ps -o sid= -p "$target" 2>/dev/null | tr -d '[:space:]')"
  [ "$actual_pgid" = "$target" ] && [ "$actual_sid" = "$target" ] &&
    [ "$actual_pgid" != "$test_pgid" ] || {
      echo "FAIL: reconcile worker $target is not isolated from test process group $test_pgid" >&2
      exit 1
    }
}
kill_tree() {
  local target="$1" child
  for child in $(pgrep -P "$target" 2>/dev/null || true); do kill_tree "$child"; done
  kill -KILL "$target" 2>/dev/null || true
}
cleanup() {
  local holder actual_pgid
  if [ -n "$worker_pid" ]; then
    actual_pgid="$(ps -o pgid= -p "$worker_pid" 2>/dev/null | tr -d '[:space:]')"
    if [ "$actual_pgid" = "$worker_pid" ] && [ "$actual_pgid" != "$test_pgid" ]; then
      kill -KILL -- "-$worker_pid" 2>/dev/null || true
    fi
    kill_tree "$worker_pid"
    wait "$worker_pid" 2>/dev/null || true
  fi
  for holder in $(fuser "$RUNDIR/reconcile.lock" 2>/dev/null || true); do
    [ "$holder" = "$$" ] || kill -KILL "$holder" 2>/dev/null || true
  done
  if [ -n "$unrelated_pid" ]; then
    kill_tree "$unrelated_pid"
    wait "$unrelated_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

controller_functions="$tmpdir/reconcile-functions.sh"
: >"$controller_functions"
extract_function reconcile_proc_record "$controller_functions"
extract_function reconcile_identity_read "$controller_functions"
extract_function reconcile_group_live "$controller_functions"
extract_function reconcile_group_owned "$controller_functions"
extract_function reconcile_identity_clear "$controller_functions"
extract_function reconcile_pid_active "$controller_functions"
extract_function reconcile_start "$controller_functions"
extract_function reconcile_stop "$controller_functions"
extract_function with_fleet_lock "$controller_functions"
extract_function cmd_stop_fenced "$controller_functions"
# shellcheck disable=SC1090
. "$controller_functions"

RUNDIR="$tmpdir/run"
RECONCILE_PID="$RUNDIR/reconcile.pid"
RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
mkdir -p "$RUNDIR"
log() { :; }
err() { printf '%s\n' "$*" >&2; }
mutation_owner_guard() { return 0; }
cmd_stop() { : >"$tmpdir/stop-completed"; }

declare -F cmd_stop_fenced >/dev/null || {
  echo 'FAIL: Stop has no pre-lock reconcile fence' >&2
  exit 1
}

if [ "${CRF_RECONCILE_TEST_CASE:-all}" != process-group ]; then
  # Similar text in another executable's argv is not ownership. Stop must never
  # discover or signal it by a substring scan.
  cat >"$tmpdir/not-runner-farm.sh" <<'SH'
#!/usr/bin/env bash
while :; do :; done
SH
  chmod +x "$tmpdir/not-runner-farm.sh"
  "$tmpdir/not-runner-farm.sh" reconcile-drain &
  unrelated_pid=$!
  reconcile_stop
  if ! kill -0 "$unrelated_pid" 2>/dev/null; then
    echo 'FAIL: Stop signaled a similar but unrelated reconcile command line' >&2
    exit 1
  fi
  kill -KILL "$unrelated_pid" 2>/dev/null || true
  wait "$unrelated_pid" 2>/dev/null || true
  unrelated_pid=""
  echo 'reconcile-stop-exact-process: OK'
fi

[ "${CRF_RECONCILE_TEST_CASE:-all}" != exact-process ] || exit 0

# Start through the production launcher and dispatch topology. The worker enters
# a real external sleep while its descendants inherit reconcile.lock.
export CRF_RECONCILE_STOP_TMPDIR="$tmpdir"
reconcile_start
worker_pid="$(cat "$RECONCILE_PID")"
assert_worker_isolated "$worker_pid"

for _ in $(seq 1 100); do
  [ -e "$tmpdir/post-timeout-retry" ] && break
  sleep 0.05
done
[ -e "$tmpdir/post-timeout-retry" ] || {
  sed 's/^/worker: /' "$RUNDIR/autoscale.log" >&2 || true
  echo 'FAIL: reconcile worker did not reach its post-timeout external sleep' >&2
  exit 1
}

worker_sid="$(ps -o sid= -p "$worker_pid" 2>/dev/null | tr -d '[:space:]')"

: >"$tmpdir/stop-issued"
reconcile_stop

if kill -0 -- "-$worker_pid" 2>/dev/null; then
  echo 'FAIL: Stop returned with reconcile process-group members still alive' >&2
  exit 1
fi
if ! flock -n "$RUNDIR/reconcile.lock" true; then
  echo 'FAIL: Stop returned while a reconcile descendant retained reconcile.lock' >&2
  exit 1
fi
[ "$worker_sid" = "$worker_pid" ] || {
  echo 'FAIL: reconcile worker does not own a dedicated session/process group' >&2
  exit 1
}
if [ -e "$tmpdir/capacity-recreated-after-stop" ]; then
  echo 'FAIL: reconcile worker recreated capacity after Stop began' >&2
  exit 1
fi
wait "$worker_pid" 2>/dev/null || true
worker_pid=""

echo 'reconcile-stop-process-group: OK'

# Stop must terminate/fence reconciliation before it waits for fleet.lock. A
# reconcile mutation can legitimately hold that lock around a slow Docker or
# GitHub operation; taking the lock first makes Stop time out before it reaches
# reconcile_stop and leaves the worker free to mutate after teardown returns.
export CRF_RECONCILE_HOLD_FLEET_LOCK=1
rm -f "$tmpdir/fleet-lock-held" "$tmpdir/stop-completed"
reconcile_start
worker_pid="$(cat "$RECONCILE_PID")"
assert_worker_isolated "$worker_pid"
for _ in $(seq 1 100); do
  [ -e "$tmpdir/fleet-lock-held" ] && break
  sleep 0.05
done
[ -e "$tmpdir/fleet-lock-held" ] || {
  echo 'FAIL: reconcile worker did not hold fleet.lock for the Stop ordering test' >&2
  exit 1
}
cmd_stop_fenced
[ -e "$tmpdir/stop-completed" ] || {
  echo 'FAIL: Stop did not complete after fencing the fleet-lock holder' >&2
  exit 1
}
if reconcile_group_live "$worker_pid"; then
  echo 'FAIL: Stop waited on fleet.lock before terminating reconciliation' >&2
  exit 1
fi
wait "$worker_pid" 2>/dev/null || true
worker_pid=""
unset CRF_RECONCILE_HOLD_FLEET_LOCK

echo 'reconcile-stop-before-fleet-lock: OK'

# If the session leader dies independently, its descendants still carry the
# per-launch identity token and may retain reconcile.lock or finish a mutation.
# Stop must prove and terminate that owned group without treating a reused or
# unrelated PGID/SID as owned.
rm -f "$tmpdir/post-timeout-retry" "$tmpdir/date-called"
reconcile_start
worker_pid="$(cat "$RECONCILE_PID")"
assert_worker_isolated "$worker_pid"
for _ in $(seq 1 100); do
  [ -e "$tmpdir/post-timeout-retry" ] && break
  sleep 0.05
done
[ -e "$tmpdir/post-timeout-retry" ] || {
  echo 'FAIL: reconcile worker did not reach its descendant sleep' >&2
  exit 1
}
kill -KILL "$worker_pid"
for _ in $(seq 1 50); do
  reconcile_pid_active || break
  sleep 0.02
done
reconcile_group_live "$worker_pid" || {
  echo 'FAIL: leader death did not leave the owned descendant group alive' >&2
  exit 1
}
reconcile_stop
if reconcile_group_live "$worker_pid"; then
  echo 'FAIL: Stop abandoned owned descendants after their leader died' >&2
  exit 1
fi
if ! flock -n "$RUNDIR/reconcile.lock" true; then
  echo 'FAIL: leader-dead reconcile descendant retained reconcile.lock after Stop' >&2
  exit 1
fi
wait "$worker_pid" 2>/dev/null || true
worker_pid=""

echo 'reconcile-stop-leader-dead-group: OK'

# The token-bearing identity record is authoritative. If reconcile.pid is lost
# after the worker passes its launch gate, a later reconcile_start must recover
# that same owned session rather than erase its identity and launch a duplicate.
rm -f "$tmpdir/post-timeout-retry" "$tmpdir/date-called"
reconcile_start
worker_pid="$(cat "$RECONCILE_PID")"
assert_worker_isolated "$worker_pid"
for _ in $(seq 1 100); do
  [ -e "$tmpdir/post-timeout-retry" ] && break
  sleep 0.05
done
[ -e "$tmpdir/post-timeout-retry" ] || {
  echo 'FAIL: reconcile worker did not reach its descendant sleep for PID-file recovery' >&2
  exit 1
}
rm -f "$RECONCILE_PID"
reconcile_start
recovered_identity="$(reconcile_identity_read)"
read -r recovered_pid _ <<<"$recovered_identity"
[ "$recovered_pid" = "$worker_pid" ] || {
  echo 'FAIL: missing reconcile.pid caused a duplicate worker to replace the authoritative identity' >&2
  exit 1
}
reconcile_stop
if reconcile_group_live "$worker_pid"; then
  echo 'FAIL: Stop left the recovered token-bearing reconcile session alive' >&2
  exit 1
fi
if ! flock -n "$RUNDIR/reconcile.lock" true; then
  echo 'FAIL: recovered reconcile session retained reconcile.lock after Stop' >&2
  exit 1
fi
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] || {
  echo 'FAIL: Stop did not clear recovered reconcile identity files' >&2
  exit 1
}
wait "$worker_pid" 2>/dev/null || true
worker_pid=""

echo 'reconcile-start-missing-pid-recovery: OK'

# A stale PID file pointing at another process must not be accepted as worker
# identity, even when its argv contains an exact reconcile-drain token and its
# PID is also its PGID/SID (the shape a reused session-leader PID would have).
setsid bash -c 'while :; do :; done' reconcile-drain &
unrelated_pid=$!
for _ in $(seq 1 100); do
  unrelated_pgid="$(ps -o pgid= -p "$unrelated_pid" 2>/dev/null | tr -d '[:space:]')"
  unrelated_sid="$(ps -o sid= -p "$unrelated_pid" 2>/dev/null | tr -d '[:space:]')"
  [ "$unrelated_pgid" = "$unrelated_pid" ] && [ "$unrelated_sid" = "$unrelated_pid" ] && break
  sleep 0.01
done
assert_worker_isolated "$unrelated_pid"
printf '%s\n' "$unrelated_pid" >"$RECONCILE_PID"
printf '%s %s %s %s\n' "$unrelated_pid" 0 0123456789abcdef0123456789abcdef "$PWD/not-the-engine" >"$RECONCILE_IDENTITY"
reconcile_stop
if ! kill -0 "$unrelated_pid" 2>/dev/null; then
  echo 'FAIL: Stop signaled a PID whose recorded process identity was stale' >&2
  exit 1
fi
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] || {
  echo 'FAIL: Stop did not clear stale reconcile identity files' >&2
  exit 1
}
kill -KILL "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=""

echo 'reconcile-stop-pid-reuse: OK'
