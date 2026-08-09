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
  extract_function reconcile_identity_read "$worker_functions"
  extract_function reconcile_identity_clear "$worker_functions"
  extract_function cmd_reconcile_drain "$worker_functions"
  # shellcheck disable=SC1090
  . "$worker_functions"

  load_cfg() { :; }
  count_reconcile_work() { [ "${CRF_RECONCILE_ZERO_WORK:-0}" = 1 ] && echo 0 || echo 1; }
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

  RUNDIR="${CRF_RECONCILE_TEST_RUNDIR:-$tmpdir/run}"
  RECONCILE_PID="$RUNDIR/reconcile.pid"
  RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
  ACCESS_TOKEN="test"
  IMAGE_DRAIN_TIMEOUT=1
  ( flock -w 5 7 || exit 1; cmd_reconcile_drain ) 7>"$RUNDIR/reconcile.lock"
  exit 0
fi

if [ "${1:-}" = reconcile-drain-ready ] && [ -n "${CRF_RECONCILE_STOP_TMPDIR:-}" ]; then
  tmpdir="$CRF_RECONCILE_STOP_TMPDIR"
  ready_functions="$tmpdir/reconcile-ready.sh"
  : >"$ready_functions"
  extract_function reconcile_proc_record "$ready_functions"
  extract_function reconcile_identity_read "$ready_functions"
  extract_function reconcile_identity_clear "$ready_functions"
  extract_function reconcile_pid_active "$ready_functions"
  extract_function cmd_reconcile_drain_ready "$ready_functions"
  # shellcheck disable=SC1090
  . "$ready_functions"
  RUNDIR="${CRF_RECONCILE_TEST_RUNDIR:-$tmpdir/run}"
  RECONCILE_PID="$RUNDIR/reconcile.pid"
  RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
  if [ "${CRF_RECONCILE_PAUSE_READY:-0}" = 1 ]; then
    mv() {
      : >"$tmpdir/ready-publication-paused"
      while :; do sleep 1; done
    }
  fi
  cmd_reconcile_drain_ready "${2:-}" "${3:-}"
  exit $?
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
extract_function with_mutation_owner_lock "$controller_functions"
extract_function with_fleet_lock "$controller_functions"
extract_function cmd_stop_fenced "$controller_functions"
extract_function cmd_stop_fenced_owned "$controller_functions"
extract_function cmd_restart_fenced "$controller_functions"
extract_function cmd_restart_fenced_owned "$controller_functions"
# shellcheck disable=SC1090
. "$controller_functions"

RUNDIR="$tmpdir/run"
RECONCILE_PID="$RUNDIR/reconcile.pid"
RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
mkdir -p "$RUNDIR"
export CRF_RECONCILE_STOP_TMPDIR="$tmpdir"
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

# The detached identity gate must not outlive a launcher that dies after the
# child owns its session but before reconcile.identity is published. Pause the
# real launcher at the atomic publication boundary, prove the exact child is a
# token-bearing session leader, then crash only the launcher.
bootstrap_dir="$tmpdir/bootstrap-launcher-death"
mkdir -p "$bootstrap_dir/run"
bootstrap_marker="$bootstrap_dir/before-identity-publication"
(
  RUNDIR="$bootstrap_dir/run"
  RECONCILE_PID="$RUNDIR/reconcile.pid"
  RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
  mv() {
    if [ "${2:-}" = "$RECONCILE_IDENTITY" ]; then
      : >"$bootstrap_marker"
      while :; do sleep 1; done
    fi
    command mv "$@"
  }
  reconcile_start
) &
launcher_pid=$!
for _ in $(seq 1 200); do
  [ -e "$bootstrap_marker" ] && break
  sleep 0.01
done
[ -e "$bootstrap_marker" ] || {
  echo 'FAIL: launcher did not reach the pre-publication crash boundary' >&2
  exit 1
}

bootstrap_pid=""
for candidate in $(pgrep -P "$launcher_pid" 2>/dev/null || true); do
  candidate_pgid="$(ps -o pgid= -p "$candidate" 2>/dev/null | tr -d '[:space:]')"
  candidate_sid="$(ps -o sid= -p "$candidate" 2>/dev/null | tr -d '[:space:]')"
  [ "$candidate_pgid" = "$candidate" ] && [ "$candidate_sid" = "$candidate" ] || continue
  [ -r "/proc/$candidate/environ" ] || continue
  tr '\0' '\n' <"/proc/$candidate/environ" 2>/dev/null |
    grep -Eq '^CRF_RECONCILE_SESSION_TOKEN=[0-9a-f]{32}$' || continue
  bootstrap_pid="$candidate"
  break
done
[ -n "$bootstrap_pid" ] || {
  echo 'FAIL: pre-publication child was not an isolated token-bearing session leader' >&2
  exit 1
}
worker_pid="$bootstrap_pid"
assert_worker_isolated "$bootstrap_pid"
[ ! -e "$bootstrap_dir/run/reconcile.identity" ] || {
  echo 'FAIL: crash probe ran after authoritative identity publication' >&2
  exit 1
}

kill -KILL "$launcher_pid"
wait "$launcher_pid" 2>/dev/null || true
for _ in $(seq 1 100); do
  reconcile_group_live "$bootstrap_pid" || break
  sleep 0.02
done
if reconcile_group_live "$bootstrap_pid"; then
  echo 'FAIL: launcher death leaked an untracked token-bearing reconcile session' >&2
  exit 1
fi
wait "$bootstrap_pid" 2>/dev/null || true
worker_pid=""

echo 'reconcile-start-launcher-death-cleanup: OK'
[ "${CRF_RECONCILE_TEST_CASE:-all}" != launcher-death ] || exit 0

# Readiness must come from the final worker stage. An immediate, successful
# zero-work drain may disappear, but it must clear both ownership files rather
# than leave a PID published after the worker exited.
zero_dir="$tmpdir/zero-work"
mkdir -p "$zero_dir"
RUNDIR="$zero_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_STOP_TMPDIR="$tmpdir" CRF_RECONCILE_TEST_RUNDIR="$zero_dir" CRF_RECONCILE_ZERO_WORK=1
reconcile_start || { echo 'FAIL: zero-work final worker activation failed' >&2; exit 1; }
zero_pid="$(cat "$RECONCILE_PID" 2>/dev/null || true)"
for _ in $(seq 1 100); do
  [ -z "$zero_pid" ] || reconcile_group_live "$zero_pid" || break
  sleep 0.01
done
for _ in $(seq 1 100); do
  [ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] && break
  sleep 0.01
done
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] || {
  echo 'FAIL: immediate zero-work exit left stale reconcile ownership' >&2
  exit 1
}
unset CRF_RECONCILE_ZERO_WORK

# If the final executable cannot start, reconcile_start must fail and retain no
# compatibility or authoritative identity for the dead bootstrap session.
exec_dir="$tmpdir/exec-failure"
mkdir -p "$exec_dir"
RUNDIR="$exec_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$exec_dir"
if ( readlink() { printf '%s\n' "$exec_dir/missing-engine"; }; reconcile_start ); then
  echo 'FAIL: reconcile_start reported success when final exec failed' >&2
  exit 1
fi
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] || {
  echo 'FAIL: final exec failure left stale reconcile ownership' >&2
  exit 1
}

# Exec failure must be self-cleaning even if the launcher cannot perform its
# own fallback. First fail the gate-to-helper exec after identity publication.
gate_exec_dir="$tmpdir/gate-exec-failure"
mkdir -p "$gate_exec_dir"
rm -f "$tmpdir/gate-identity-published"
RUNDIR="$gate_exec_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$gate_exec_dir"
(
  readlink() { printf '%s\n' "$gate_exec_dir/missing-engine"; }
  mv() {
    command mv "$@"
    if [ "${2:-}" = "$RECONCILE_IDENTITY" ]; then
      : >"$tmpdir/gate-identity-published"
      while :; do sleep 1; done
    fi
  }
  reconcile_start
) &
gate_launcher_pid=$!
for _ in $(seq 1 200); do [ -e "$tmpdir/gate-identity-published" ] && break; sleep 0.01; done
[ -e "$tmpdir/gate-identity-published" ] || { echo 'FAIL: gate exec fixture did not publish identity' >&2; exit 1; }
kill -KILL "$gate_launcher_pid"
wait "$gate_launcher_pid" 2>/dev/null || true
for _ in $(seq 1 200); do [ ! -e "$RECONCILE_IDENTITY" ] && break; sleep 0.01; done
[ ! -e "$RECONCILE_IDENTITY" ] && ! compgen -G "$RUNDIR/reconcile.ready.*" >/dev/null &&
  ! compgen -G "$RUNDIR/reconcile.cancel.*" >/dev/null || {
    echo 'FAIL: failed gate exec required its launcher to clean ownership' >&2; exit 1;
  }

# A gate that never received its own identity must not delete a newer launch's
# shared identity when its bounded cleanup finally runs.
stale_gate_dir="$tmpdir/stale-gate-cleanup"
mkdir -p "$stale_gate_dir"
rm -f "$tmpdir/stale-gate-before-identity"
RUNDIR="$stale_gate_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$stale_gate_dir" CRF_RECONCILE_TEST_READY_ATTEMPTS=20
export CRF_RECONCILE_TEST_PAUSE_GATE_CLEANUP=1
(
  mv() {
    if [ "${2:-}" = "$RECONCILE_IDENTITY" ]; then
      : >"$tmpdir/stale-gate-before-identity"
      while :; do sleep 1; done
    fi
    command mv "$@"
  }
  reconcile_start
) &
stale_gate_launcher=$!
for _ in $(seq 1 200); do [ -e "$tmpdir/stale-gate-before-identity" ] && break; sleep 0.01; done
[ -e "$tmpdir/stale-gate-before-identity" ] || { echo 'FAIL: stale gate did not pause before identity' >&2; exit 1; }
kill -KILL "$stale_gate_launcher"
wait "$stale_gate_launcher" 2>/dev/null || true
stale_cleanup_marker=""
for _ in $(seq 1 200); do
  stale_cleanup_marker="$(compgen -G "$RUNDIR/reconcile.ready.*.cleanup-paused" | head -n1 || true)"
  [ -n "$stale_cleanup_marker" ] && break
  sleep 0.01
done
[ -n "$stale_cleanup_marker" ] || { echo 'FAIL: stale gate did not pause inside cleanup' >&2; exit 1; }
stale_cleanup_state="${stale_cleanup_marker%.cleanup-paused}"
newer_token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
setsid env "CRF_RECONCILE_SESSION_TOKEN=$newer_token" sleep 30 &
newer_pid=$!
for _ in $(seq 1 100); do
  newer_record="$(reconcile_proc_record "$newer_pid" 2>/dev/null || true)"
  read -r _ newer_pgid newer_sid newer_starttime <<<"$newer_record"
  [ "${newer_pgid:-}" = "$newer_pid" ] && [ "${newer_sid:-}" = "$newer_pid" ] && break
  sleep 0.01
done
printf '%s %s %s %s\n' "$newer_pid" "$newer_starttime" "$newer_token" /bin/sleep >"$RECONCILE_IDENTITY"
: >"$stale_cleanup_state.cleanup-release"
for _ in $(seq 1 200); do
  [ ! -e "$stale_cleanup_marker" ] && break
  sleep 0.01
done
[ ! -e "$stale_cleanup_marker" ] || { echo 'FAIL: stale gate did not finish cleanup' >&2; exit 1; }
[ -s "$RECONCILE_IDENTITY" ] && kill -0 "$newer_pid" 2>/dev/null || {
  echo 'FAIL: stale gate cleanup deleted or disrupted the newer launch identity' >&2; exit 1;
}
read -r preserved_pid _ <"$RECONCILE_IDENTITY"
[ "$preserved_pid" = "$newer_pid" ] || { echo 'FAIL: newer identity was replaced by stale gate cleanup' >&2; exit 1; }
kill -KILL -- "-$newer_pid" 2>/dev/null || true
wait "$newer_pid" 2>/dev/null || true
rm -f "$RECONCILE_IDENTITY"
unset CRF_RECONCILE_TEST_READY_ATTEMPTS CRF_RECONCILE_TEST_PAUSE_GATE_CLEANUP

# The cleanup pause is itself bounded: an aborted fixture (or accidentally
# inherited test hook) cannot strand an untracked gate forever.
bounded_gate_dir="$tmpdir/bounded-gate-cleanup"
mkdir -p "$bounded_gate_dir"
rm -f "$tmpdir/bounded-gate-before-identity"
RUNDIR="$bounded_gate_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$bounded_gate_dir" CRF_RECONCILE_TEST_READY_ATTEMPTS=20
export CRF_RECONCILE_TEST_PAUSE_GATE_CLEANUP=1
(
  mv() {
    if [ "${2:-}" = "$RECONCILE_IDENTITY" ]; then
      : >"$tmpdir/bounded-gate-before-identity"
      while :; do sleep 1; done
    fi
    command mv "$@"
  }
  reconcile_start
) &
bounded_gate_launcher=$!
for _ in $(seq 1 200); do [ -e "$tmpdir/bounded-gate-before-identity" ] && break; sleep 0.01; done
[ -e "$tmpdir/bounded-gate-before-identity" ] || { echo 'FAIL: bounded gate did not pause before identity' >&2; exit 1; }
kill -KILL "$bounded_gate_launcher"
wait "$bounded_gate_launcher" 2>/dev/null || true
bounded_cleanup_seen=0
for _ in $(seq 1 200); do
  compgen -G "$RUNDIR/reconcile.ready.*.cleanup-paused" >/dev/null && { bounded_cleanup_seen=1; break; }
  sleep 0.01
done
[ "$bounded_cleanup_seen" = 1 ] || { echo 'FAIL: bounded cleanup hook was not exercised' >&2; exit 1; }
for _ in $(seq 1 200); do
  compgen -G "$RUNDIR/reconcile.ready.*.cleanup-paused" >/dev/null || break
  sleep 0.01
done
[ ! -e "$RECONCILE_IDENTITY" ] && ! compgen -G "$RUNDIR/reconcile.ready.*" >/dev/null &&
  ! compgen -G "$RUNDIR/reconcile.cancel.*" >/dev/null || {
    echo 'FAIL: unreleased cleanup hook stranded gate ownership or token state' >&2; exit 1;
  }
unset CRF_RECONCILE_TEST_READY_ATTEMPTS CRF_RECONCILE_TEST_PAUSE_GATE_CLEANUP

# Then let the helper publish ready, remove the target before go, and kill the
# launcher after go publication. The helper's retained EXIT trap owns cleanup.
helper_exec_dir="$tmpdir/helper-exec-failure"
mkdir -p "$helper_exec_dir/tests" "$helper_exec_dir/run"
ln -s "$PWD/src" "$helper_exec_dir/src"
helper_exec_script="$helper_exec_dir/tests/reconcile-stop-lifecycle.sh"
cp "$0" "$helper_exec_script"; chmod +x "$helper_exec_script"
rm -f "$tmpdir/helper-before-go" "$tmpdir/helper-target-removed" "$tmpdir/helper-go-published"
RUNDIR="$helper_exec_dir/run"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$RUNDIR"
(
  readlink() { printf '%s\n' "$helper_exec_script"; }
  mv() {
    case "${2:-}:$(cat "${1:-}" 2>/dev/null)" in
      "$RUNDIR"/reconcile.ready.*:go)
        : >"$tmpdir/helper-before-go"
        while [ ! -e "$tmpdir/helper-target-removed" ]; do sleep 0.01; done
        command mv "$@"
        : >"$tmpdir/helper-go-published"
        while :; do sleep 1; done
        ;;
    esac
    command mv "$@"
  }
  reconcile_start
) &
helper_launcher_pid=$!
for _ in $(seq 1 200); do [ -e "$tmpdir/helper-before-go" ] && break; sleep 0.01; done
[ -e "$tmpdir/helper-before-go" ] || {
  cat "$RUNDIR/autoscale.log" >&2 || true
  echo 'FAIL: helper exec fixture did not reach go' >&2; exit 1;
}
rm -f "$helper_exec_script"; : >"$tmpdir/helper-target-removed"
for _ in $(seq 1 200); do [ -e "$tmpdir/helper-go-published" ] && break; sleep 0.01; done
[ -e "$tmpdir/helper-go-published" ] || { echo 'FAIL: helper exec fixture did not publish go' >&2; exit 1; }
kill -KILL "$helper_launcher_pid"
wait "$helper_launcher_pid" 2>/dev/null || true
for _ in $(seq 1 200); do [ ! -e "$RECONCILE_IDENTITY" ] && break; sleep 0.01; done
[ ! -e "$RECONCILE_IDENTITY" ] && ! compgen -G "$RUNDIR/reconcile.ready.*" >/dev/null &&
  ! compgen -G "$RUNDIR/reconcile.cancel.*" >/dev/null || {
    find "$RUNDIR" -maxdepth 1 -printf 'helper-exec-leftover: %f\n' >&2 || true
    cat "$RUNDIR/autoscale.log" >&2 || true
    echo 'FAIL: failed helper exec required its launcher to clean ownership' >&2; exit 1;
  }

# Pause the final process after it validates the published identity but before
# its ready rename. The launcher timeout must retain that identity while it
# fences the exact token-owned session, then clear it only after the group dies.
pause_dir="$tmpdir/paused-ready"
mkdir -p "$pause_dir"
rm -f "$tmpdir/ready-publication-paused" "$tmpdir/paused-launch-status"
RUNDIR="$pause_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$pause_dir" CRF_RECONCILE_PAUSE_READY=1
export CRF_RECONCILE_TEST_READY_ATTEMPTS=20
(
  # Keep the deterministic timeout bounded without changing production timing.
  # This launch has only one session leader before acknowledgement; /proc state
  # is therefore the exact liveness fact reconcile_start needs in this fixture.
  reconcile_group_live() {
    local stat rest state
    [ -r "/proc/$1/stat" ] || return 1
    stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${stat##*) }"; state="${rest%% *}"
    case "$state" in Z|X) return 1 ;; *) return 0 ;; esac
  }
  if reconcile_start; then printf '0\n' >"$tmpdir/paused-launch-status"
  else printf '%s\n' "$?" >"$tmpdir/paused-launch-status"; fi
) &
paused_launcher_pid=$!
for _ in $(seq 1 200); do
  [ -e "$tmpdir/ready-publication-paused" ] && break
  sleep 0.01
done
[ -e "$tmpdir/ready-publication-paused" ] && [ -s "$RECONCILE_IDENTITY" ] || {
  echo 'FAIL: final worker did not pause after authoritative identity validation' >&2
  exit 1
}
paused_identity="$(reconcile_identity_read)"
read -r paused_pid paused_starttime paused_token _ <<<"$paused_identity"
worker_pid="$paused_pid"
reconcile_group_owned "$paused_pid" "$paused_starttime" "$paused_token" || {
  echo 'FAIL: paused pre-ack session was not exactly token-owned' >&2
  exit 1
}
for _ in $(seq 1 300); do
  kill -0 "$paused_launcher_pid" 2>/dev/null || break
  sleep 0.02
done
if kill -0 "$paused_launcher_pid" 2>/dev/null; then
  echo 'FAIL: paused pre-ack launcher did not finish its bounded timeout cleanup' >&2
  exit 1
fi
wait "$paused_launcher_pid" 2>/dev/null || true
[ "$(cat "$tmpdir/paused-launch-status" 2>/dev/null)" != 0 ] || {
  echo 'FAIL: paused pre-ack worker was reported as a successful launch' >&2
  exit 1
}
if reconcile_group_live "$paused_pid"; then
  echo 'FAIL: readiness timeout left the token-bearing session alive' >&2
  exit 1
fi
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] || {
  echo 'FAIL: readiness timeout cleared ownership before exact stop completed' >&2
  exit 1
}
worker_pid=""
unset CRF_RECONCILE_PAUSE_READY CRF_RECONCILE_TEST_RUNDIR CRF_RECONCILE_TEST_READY_ATTEMPTS

# If the parent stalls after publishing go, the final process may time out and
# clear ownership before the parent resumes. The parent must not convert that
# expired handoff into success or leave a compatibility PID behind.
expired_dir="$tmpdir/expired-after-go"
mkdir -p "$expired_dir"
rm -f "$tmpdir/go-published" "$tmpdir/release-go-launcher" "$tmpdir/expired-launch-status"
RUNDIR="$expired_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$expired_dir" CRF_RECONCILE_TEST_READY_ATTEMPTS=20
(
  mv() {
    case "${2:-}:$(cat "${1:-}" 2>/dev/null)" in
      "$RUNDIR"/reconcile.ready.*:go)
        command mv "$@"
        : >"$tmpdir/go-published"
        while [ ! -e "$tmpdir/release-go-launcher" ]; do sleep 0.01; done
        return 0
        ;;
    esac
    command mv "$@"
  }
  if reconcile_start; then printf '0\n' >"$tmpdir/expired-launch-status"
  else printf '%s\n' "$?" >"$tmpdir/expired-launch-status"; fi
) &
expired_launcher_pid=$!
for _ in $(seq 1 200); do [ -e "$tmpdir/go-published" ] && break; sleep 0.01; done
[ -e "$tmpdir/go-published" ] || { echo 'FAIL: parent did not pause after publishing go' >&2; exit 1; }
for _ in $(seq 1 700); do [ ! -e "$RECONCILE_IDENTITY" ] && break; sleep 0.01; done
[ ! -e "$RECONCILE_IDENTITY" ] || { echo 'FAIL: expired final activation retained ownership' >&2; exit 1; }
: >"$tmpdir/release-go-launcher"
wait "$expired_launcher_pid" 2>/dev/null || true
[ "$(cat "$tmpdir/expired-launch-status" 2>/dev/null)" != 0 ] || {
  echo 'FAIL: parent reported success after the final activation expired' >&2; exit 1;
}
[ ! -e "$RECONCILE_PID" ] && ! compgen -G "$RUNDIR/reconcile.ready.*" >/dev/null &&
  ! compgen -G "$RUNDIR/reconcile.cancel.*" >/dev/null || {
    echo 'FAIL: expired activation left PID or handshake state' >&2; exit 1;
  }

# Killing the launcher after ready publication but before go must leave the
# bounded helper responsible for removing every token-specific artifact.
interrupt_dir="$tmpdir/interrupted-after-ready"
mkdir -p "$interrupt_dir"
rm -f "$tmpdir/before-go-publication"
RUNDIR="$interrupt_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$interrupt_dir"
(
  mv() {
    case "${2:-}:$(cat "${1:-}" 2>/dev/null)" in
      "$RUNDIR"/reconcile.ready.*:go)
        : >"$tmpdir/before-go-publication"
        while :; do sleep 1; done
        ;;
    esac
    command mv "$@"
  }
  reconcile_start
) &
interrupt_launcher_pid=$!
for _ in $(seq 1 200); do [ -e "$tmpdir/before-go-publication" ] && break; sleep 0.01; done
[ -e "$tmpdir/before-go-publication" ] || { echo 'FAIL: launcher did not pause before go publication' >&2; exit 1; }
kill -KILL "$interrupt_launcher_pid"
wait "$interrupt_launcher_pid" 2>/dev/null || true
for _ in $(seq 1 700); do [ ! -e "$RECONCILE_IDENTITY" ] && break; sleep 0.01; done
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] &&
  ! compgen -G "$RUNDIR/reconcile.ready.*" >/dev/null &&
  ! compgen -G "$RUNDIR/reconcile.cancel.*" >/dev/null || {
    find "$RUNDIR" -maxdepth 1 -printf 'leftover: %f\n' >&2 || true
    cat "$RUNDIR/autoscale.log" >&2 || true
    if [ -s "$RECONCILE_IDENTITY" ]; then
      read -r debug_pid _ <"$RECONCILE_IDENTITY" || true
      ps -o pid=,ppid=,pgid=,sid=,stat=,args= -p "${debug_pid:-0}" >&2 || true
    fi
    echo 'FAIL: interrupted post-ready launcher left ownership or token artifacts' >&2; exit 1;
  }

# A failed compatibility-PID write occurs only after final-process activation.
# It must cancel and fence that exact process rather than leave an incomplete
# identity that a retry can mistake for a successful launch.
pid_failure_dir="$tmpdir/pid-publication-failure"
mkdir -p "$pid_failure_dir"
RUNDIR="$pid_failure_dir"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
export CRF_RECONCILE_TEST_RUNDIR="$pid_failure_dir" CRF_RECONCILE_ZERO_WORK=1
rm -f "$tmpdir/pid-failure-status" "$tmpdir/pid-failure-armed"
(
  cat() {
    local output
    output="$(command cat "$@")" || return $?
    case "${1:-}:$output" in
      "$RUNDIR"/reconcile.ready.*:active)
        if [ ! -e "$tmpdir/pid-failure-armed" ]; then
          ln -s /dev/full "$RECONCILE_PID"
          : >"$tmpdir/pid-failure-armed"
        fi
        ;;
    esac
    printf '%s\n' "$output"
  }
  if reconcile_start; then printf '0\n' >"$tmpdir/pid-failure-status"
  else printf '%s\n' "$?" >"$tmpdir/pid-failure-status"; fi
) &
pid_failure_launcher=$!
pid_failure_worker=""
for _ in $(seq 1 200); do
  if [ -s "$RECONCILE_IDENTITY" ]; then
    read -r pid_failure_worker _ <"$RECONCILE_IDENTITY" || true
    break
  fi
  sleep 0.01
done
wait "$pid_failure_launcher" 2>/dev/null || true
[ "$(cat "$tmpdir/pid-failure-status" 2>/dev/null)" != 0 ] || {
  echo 'FAIL: failed PID publication was reported as successful' >&2; exit 1;
}
[ -z "$pid_failure_worker" ] || ! reconcile_group_live "$pid_failure_worker" || {
  echo 'FAIL: failed PID publication left its token-owned group alive' >&2; exit 1;
}
[ ! -e "$RECONCILE_PID" ] && [ ! -e "$RECONCILE_IDENTITY" ] &&
  ! compgen -G "$RUNDIR/reconcile.ready.*" >/dev/null &&
  ! compgen -G "$RUNDIR/reconcile.cancel.*" >/dev/null || {
    echo 'FAIL: failed PID publication left ownership or handshake state' >&2; exit 1;
  }
unset CRF_RECONCILE_ZERO_WORK CRF_RECONCILE_TEST_RUNDIR CRF_RECONCILE_TEST_READY_ATTEMPTS

echo 'reconcile-start-final-stage-results: OK'
[ "${CRF_RECONCILE_TEST_CASE:-all}" != final-stage ] || exit 0

unset CRF_RECONCILE_TEST_RUNDIR
RUNDIR="$tmpdir/run"; RECONCILE_PID="$RUNDIR/reconcile.pid"; RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
rm -f "$tmpdir/date-called" "$tmpdir/post-timeout-retry" "$tmpdir/stop-issued"

# Start through the production launcher and dispatch topology. The worker enters
# a real external sleep while its descendants inherit reconcile.lock.
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
  stubborn_token=cccccccccccccccccccccccccccccccc
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
