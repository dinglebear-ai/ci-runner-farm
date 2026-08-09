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
  extract_function count_reconcile_work_locked "$worker_functions"
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
extract_function cmd_restart_fenced "$controller_functions"
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

# A bounded signal wait is not proof that an owned process group terminated.
# Model a token-proven group that remains live after both TERM and KILL (for
# example, a descendant blocked in uninterruptible I/O). Stop and Restart must
# retain the authoritative identity and abort before any fleet mutation. A new
# reconcile launch must likewise refuse to replace the still-owned group.
(
  stubborn_dir="$tmpdir/stubborn"
  mkdir -p "$stubborn_dir"
  RUNDIR="$stubborn_dir"
  RECONCILE_PID="$RUNDIR/reconcile.pid"
  RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
  stubborn_pid=4242
  stubborn_starttime=123456
  stubborn_token=0123456789abcdef0123456789abcdef
  stubborn_script="$PWD/$ENGINE"
  ( umask 077
    printf '%s\n' "$stubborn_pid" >"$RECONCILE_PID"
    printf '%s %s %s %s\n' "$stubborn_pid" "$stubborn_starttime" \
      "$stubborn_token" "$stubborn_script" >"$RECONCILE_IDENTITY"
  )

  group_stubborn=1
  reconcile_pid_active() { return 0; }
  reconcile_group_owned() { return 0; }
  reconcile_group_live() { [ "$group_stubborn" = 1 ]; }
  reconcile_proc_record() { printf 'S %s %s %s\n' "$1" "$1" "$stubborn_starttime"; }
  kill() { :; }
  sleep() { :; }
  nohup() { : >"$stubborn_dir/replacement-launched"; }
  mutation_owner_guard() { return 0; }
  cmd_stop() { : >"$stubborn_dir/stop-ran"; }
  cmd_restart() { : >"$stubborn_dir/restart-ran"; }

  if reconcile_stop; then
    echo 'FAIL: reconcile_stop succeeded while its owned process group remained live' >&2
    exit 1
  fi
  [ -s "$RECONCILE_PID" ] && [ -s "$RECONCILE_IDENTITY" ] || {
    echo 'FAIL: failed reconcile_stop discarded authoritative ownership files' >&2
    exit 1
  }
  [ "$(stat -c %a "$RECONCILE_PID")" = 600 ] &&
    [ "$(stat -c %a "$RECONCILE_IDENTITY")" = 600 ] || {
      echo 'FAIL: failed reconcile_stop weakened ownership-file permissions' >&2
      exit 1
    }

  if cmd_stop_fenced || [ -e "$stubborn_dir/stop-ran" ]; then
    echo 'FAIL: fenced Stop continued after reconcile fencing failed' >&2
    exit 1
  fi
  if cmd_restart_fenced || [ -e "$stubborn_dir/restart-ran" ]; then
    echo 'FAIL: fenced Restart continued after reconcile fencing failed' >&2
    exit 1
  fi
  # Exercise the real inner Stop/Restart functions too: callers inside the
  # engine must not be able to bypass the outer dispatch fence.
  (
    stop_functions="$stubborn_dir/stop-functions.sh"
    : >"$stop_functions"
    extract_function cmd_restart "$stop_functions"
    extract_function cmd_stop "$stop_functions"
    # shellcheck disable=SC1090
    . "$stop_functions"
    validate_runtime_config() { :; }
    reconcile_stop() { return 1; }
    kache_watchdog_stop() { : >"$stubborn_dir/teardown-ran"; }
    cmd_start() { : >"$stubborn_dir/start-ran"; }
    if cmd_stop || [ -e "$stubborn_dir/teardown-ran" ]; then
      echo 'FAIL: inner cmd_stop continued after reconcile fencing failed' >&2
      exit 1
    fi
    if cmd_restart || [ -e "$stubborn_dir/start-ran" ]; then
      echo 'FAIL: inner cmd_restart started after Stop failed' >&2
      exit 1
    fi
  )
  # Model the leader-dead case for replacement: the group is still token-owned,
  # but reconcile_pid_active can no longer prove a live leader.
  reconcile_pid_active() { return 1; }
  if reconcile_start || [ -e "$stubborn_dir/replacement-launched" ]; then
    echo 'FAIL: reconcile_start replaced a still-owned process group' >&2
    exit 1
  fi

  group_stubborn=0
  reconcile_pid_active() { return 1; }
  reconcile_group_owned() { return 1; }
  reconcile_stop || {
    echo 'FAIL: reconcile_stop retry failed after the owned group disappeared' >&2
    exit 1
  }
  [ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] || {
    echo 'FAIL: successful reconcile_stop retry retained stale ownership files' >&2
    exit 1
  }
)

echo 'reconcile-stop-stubborn-owned-group: OK'

# A failed reconcile_start is a lifecycle fence, not an advisory daemon-start
# result. Every operational caller must return before the first subsequent
# override, admission, provisioning, scale, or success mutation.
(
  caller_dir="$tmpdir/start-failure-callers"
  mkdir -p "$caller_dir"

  # Apply commits the validated configuration first, but must preserve runtime
  # overrides and avoid daemon/admission changes when the reconcile fence fails.
  (
    functions="$caller_dir/apply-functions.sh"
    : >"$functions"; extract_function cmd_apply_config "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    CFGDIR="$caller_dir/apply-config"; RUNDIR="$caller_dir/apply-run"
    mkdir -p "$CFGDIR" "$RUNDIR"
    CFG="$CFGDIR/ci-runner-farm.cfg"
    staged="$CFGDIR/.apply.test"
    printf 'old\n' >"$CFG"; printf 'new\n' >"$staged"
    : >"$RUNDIR/scale-override.keep"
    expected="$(printf 'a%.0s' {1..64})"
    load_calls=0
    load_cfg() {
      load_calls=$((load_calls + 1))
      GH_SCOPE=org; GH_OWNER=test; GH_REPOS=''; RUNNER_GROUP=Default
      RUNNER_COUNT="$([ "$load_calls" -eq 1 ] && echo 1 || echo 2)"
      RUNNER_MODE=single; RUNNER_POOLS=''; AUTOSCALE=false; POOL_AUTOSCALE=inherit
      AUTOSCALE_MIN=0; AUTOSCALE_MAX=2; AUTOSCALE_MIN_IDLE=0; AUTOSCALE_STEP=1
      AUTOSCALE_INTERVAL=60; AUTOSCALE_IDLE_GRACE=60
      IMAGE_AUTOUPDATE=false; IMAGE_AUTOUPDATE_INTERVAL=300; IMAGE_DRAIN_TIMEOUT=60
      IMAGE_SOURCE=builtin; IMAGE=''; NETWORK_ISOLATION=off
    }
    config_revision() { printf '%s\n' "$expected"; }
    validate_settings_config() { return 0; }
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); [ "$reconcile_calls" -eq 1 ]; }
    managed_names() { : >"$caller_dir/apply-admission-ran"; }
    config_json() { printf '{}'; }
    SCALESET_PID="$RUNDIR/scaleset.pid"; AUTOSCALE_PID="$RUNDIR/autoscale.pid"
    IMAGEUPDATE_PID="$RUNDIR/imageupdate.pid"
    if output="$(cmd_apply_config "$expected" "$staged")"; then
      echo 'FAIL: cmd_apply_config accepted reconcile_start failure' >&2; exit 1
    fi
    [ -e "$RUNDIR/scale-override.keep" ] || {
      echo 'FAIL: cmd_apply_config cleared overrides after reconcile_start failed' >&2; exit 1;
    }
    [ ! -e "$caller_dir/apply-admission-ran" ] && [[ "$output" != *'"ok":true'* ]] || {
      echo 'FAIL: cmd_apply_config continued admission/success after reconcile_start failed' >&2; exit 1;
    }
  )

  (
    functions="$caller_dir/reconcile-config-functions.sh"
    : >"$functions"; extract_function cmd_reconcile_config "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    RUNDIR="$caller_dir/reconcile-config-run"; mkdir -p "$RUNDIR"
    : >"$RUNDIR/scale-override.keep"
    validate_runtime_config() { return 0; }
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); [ "$reconcile_calls" -eq 1 ]; }
    NETWORK_ISOLATION=off
    if output="$(cmd_reconcile_config)"; then
      echo 'FAIL: cmd_reconcile_config accepted reconcile_start failure' >&2; exit 1
    fi
    [ -e "$RUNDIR/scale-override.keep" ] && [ -z "$output" ] || {
      echo 'FAIL: cmd_reconcile_config mutated overrides or reported success after reconcile_start failed' >&2; exit 1;
    }
  )

  (
    functions="$caller_dir/maintenance-functions.sh"
    : >"$functions"; extract_function cmd_maintenance "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    MAINTENANCE_FILE="$caller_dir/maintenance.state"; : >"$MAINTENANCE_FILE"
    AUTOSCALE=true
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); [ "$reconcile_calls" -eq 1 ]; }
    autoscale_start() { : >"$caller_dir/maintenance-admission-ran"; }
    if output="$(cmd_maintenance resume)"; then
      echo 'FAIL: maintenance resume accepted reconcile_start failure' >&2; exit 1
    fi
    [ -e "$MAINTENANCE_FILE" ] && [ ! -e "$caller_dir/maintenance-admission-ran" ] && [ -z "$output" ] || {
      echo 'FAIL: maintenance resumed admissions/state after reconcile_start failed' >&2; exit 1;
    }
  )

  (
    functions="$caller_dir/start-functions.sh"
    : >"$functions"; extract_function cmd_start "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    RUNDIR="$caller_dir/start-run"; mkdir -p "$RUNDIR"; : >"$RUNDIR/scale-override.keep"
    SECURITY_CACHE="$RUNDIR/security.cache"
    validate_runtime_config() { return 0; }
    auth_credentials_configured() { return 0; }
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); [ "$reconcile_calls" -eq 1 ]; }
    provision_preflight() { : >"$caller_dir/start-provision-ran"; }
    public_repo_problem() { :; }
    org_runner_group_problem() { :; }
    managed_names() { :; }
    start_stopped_managed() { : >"$caller_dir/start-capacity-ran"; }
    pool_mode_enabled() { return 1; }
    current_count() { echo 0; }
    start_one() { : >"$caller_dir/start-capacity-ran"; }
    RUNNER_COUNT=1 AUTOSCALE=false AUTOSCALE_MIN=0
    if cmd_start; then
      echo 'FAIL: cmd_start accepted reconcile_start failure' >&2; exit 1
    fi
    [ -e "$RUNDIR/scale-override.keep" ] && [ ! -e "$caller_dir/start-provision-ran" ] &&
      [ ! -e "$caller_dir/start-capacity-ran" ] || {
      echo 'FAIL: cmd_start cleared overrides or provisioned after reconcile_start failed' >&2; exit 1;
    }
  )

  (
    functions="$caller_dir/scale-functions.sh"
    : >"$functions"; extract_function cmd_scale "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    validate_runtime_config() { return 0; }
    pool_mode_enabled() { return 1; }
    pool_autoscale_enabled() { return 1; }
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); [ "$reconcile_calls" -eq 1 ]; }
    cmd_scale_internal() { : >"$caller_dir/scale-mutation-ran"; }
    if cmd_scale 2; then
      echo 'FAIL: cmd_scale accepted reconcile_start failure' >&2; exit 1
    fi
    [ ! -e "$caller_dir/scale-mutation-ran" ] || {
      echo 'FAIL: cmd_scale mutated capacity after reconcile_start failed' >&2; exit 1;
    }
  )
)

echo 'reconcile-start-failure-callers: OK'

# Fence mode must leave a proven healthy worker running. Otherwise a later
# read-only validation failure (invalid Scale, failed Start preflight) strands
# unrelated reconciliation even though no requested mutation occurred.
(
  healthy_dir="$tmpdir/healthy-fence"
  mkdir -p "$healthy_dir"
  RUNDIR="$healthy_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
  reconcile_pid_active() { return 0; }
  reconcile_stop() { : >"$healthy_dir/worker-stopped"; }
  reconcile_start fence || { echo 'FAIL: healthy reconcile fence failed' >&2; exit 1; }
  [ ! -e "$healthy_dir/worker-stopped" ] || {
    echo 'FAIL: fence mode stopped a proven healthy reconcile worker' >&2
    exit 1
  }
)

echo 'reconcile-fence-preserves-healthy-worker: OK'

(
  invalid_dir="$tmpdir/invalid-after-healthy"
  mkdir -p "$invalid_dir"

  # Start validates the lifecycle twice (healthy fence + existing launch) before
  # provisioning. A later preflight failure must not have stopped that worker.
  (
    functions="$invalid_dir/start-functions.sh"
    : >"$functions"; extract_function cmd_start "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    RUNDIR="$invalid_dir/start-run"; mkdir -p "$RUNDIR"; SECURITY_CACHE="$RUNDIR/security"
    validate_runtime_config() { return 0; }
    auth_credentials_configured() { return 0; }
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); return 0; }
    public_repo_problem() { :; }; org_runner_group_problem() { :; }
    provision_preflight() { return 1; }
    if cmd_start; then echo 'FAIL: invalid Start preflight succeeded' >&2; exit 1; fi
    [ "$reconcile_calls" -eq 2 ] || {
      echo 'FAIL: invalid Start did not preserve/confirm the healthy reconcile worker before preflight' >&2; exit 1;
    }
  )

  # Autoscale bounds are read-only and must reject before even fencing a healthy
  # worker, so an invalid request cannot interrupt unrelated reconciliation.
  (
    functions="$invalid_dir/scale-functions.sh"
    : >"$functions"; extract_function cmd_scale "$functions"
    # shellcheck disable=SC1090
    . "$functions"
    validate_runtime_config() { return 0; }
    pool_mode_enabled() { return 1; }
    pool_autoscale_enabled() { return 0; }
    current_count() { echo 2; }
    reconcile_calls=0
    reconcile_start() { reconcile_calls=$((reconcile_calls + 1)); return 0; }
    AUTOSCALE_MAX=4
    if cmd_scale 2; then echo 'FAIL: invalid autoscale request succeeded' >&2; exit 1; fi
    [ "$reconcile_calls" -eq 0 ] || {
      echo 'FAIL: invalid Scale fenced a healthy reconcile worker before read-only validation' >&2; exit 1;
    }
  )
)

echo 'reconcile-invalid-commands-preserve-healthy-worker: OK'
