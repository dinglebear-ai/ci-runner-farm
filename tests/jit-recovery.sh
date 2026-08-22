#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables are consumed by sourced production modules
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"
CFGDIR="$tmp/cfg"
CACHE_ROOT="$tmp/bootstrap"
SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
NAME_PREFIX=ci-runner
LABEL_NS=net.unraid.ci-runner-farm
RESERVATION_DIR="$RUNDIR/reservations"
JIT_LEGACY_STATE_DIR="$RUNDIR/jit"
JIT_HANDOFF_GRACE_SECONDS=300
mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT" "$RESERVATION_DIR" "$JIT_LEGACY_STATE_DIR"

pool_id_valid(){ [[ "${1:-}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }
safe_cache_root_mode=success
detach_failure_runner=
gc_remove_failure=
slow_gc_rm_seconds=0
gc_rm_started="$tmp/gc-rm-started"
gc_rm_finished="$tmp/gc-rm-finished"
gc_rm_gate="$tmp/gc-rm-gate"
gc_rm_active="$tmp/gc-rm-active"
gc_rm_max_active="$tmp/gc-rm-max-active"
gc_inherited_fd5="$tmp/gc-inherited-fd5"
gc_inherited_fd8="$tmp/gc-inherited-fd8"
crf_safe_cache_root(){
  [ "$safe_cache_root_mode" = success ] || return 1
  printf '%s' "$CACHE_ROOT"
}
mv(){
  local arg
  if [ -n "$detach_failure_runner" ]; then
    for arg in "$@"; do
      [[ "$arg" == *"/$detach_failure_runner" ]] && return 1
    done
  fi
  command mv "$@"
}
rm(){
  local arg active max
  for arg in "$@"; do
    if [[ "$arg" == *"/.jit-gc/"* ]]; then
      [ ! -e "/proc/$BASHPID/fd/5" ] || printf '%s\n' "$BASHPID" >>"$gc_inherited_fd5"
      [ ! -e "/proc/$BASHPID/fd/8" ] || printf '%s\n' "$BASHPID" >>"$gc_inherited_fd8"
      printf '%s\n' "$arg" >>"$gc_rm_started"
      (
        flock -x 9
        active=$(( $(cat "$gc_rm_active" 2>/dev/null || printf 0) + 1 ))
        printf '%s\n' "$active" >"$gc_rm_active"
        max="$(cat "$gc_rm_max_active" 2>/dev/null || printf 0)"
        [ "$active" -le "$max" ] || printf '%s\n' "$active" >"$gc_rm_max_active"
      ) 9>"$tmp/gc-rm-count.lock"
      [ "$slow_gc_rm_seconds" = 0 ] || sleep "$slow_gc_rm_seconds"
      while [ -e "$gc_rm_gate" ]; do sleep 0.01; done
      if [ -n "$gc_remove_failure" ] && [[ "${arg##*/}" == "$gc_remove_failure"* ]]; then
        (
          flock -x 9
          active=$(( $(cat "$gc_rm_active" 2>/dev/null || printf 1) - 1 ))
          printf '%s\n' "$active" >"$gc_rm_active"
        ) 9>"$tmp/gc-rm-count.lock"
        return 1
      fi
      command rm "$@"
      (
        flock -x 9
        active=$(( $(cat "$gc_rm_active" 2>/dev/null || printf 1) - 1 ))
        printf '%s\n' "$active" >"$gc_rm_active"
      ) 9>"$tmp/gc-rm-count.lock"
      printf '%s\n' "$arg" >>"$gc_rm_finished"
      return 0
    fi
  done
  command rm "$@"
}
. "$SCRIPT_DIR/runner-resources.sh"
. "$SCRIPT_DIR/runner-jit.sh"
CACHE_ROOT="$tmp/configured"
jit_paths_refresh

declare -A fake_exists fake_status fake_consumed fake_pool fake_handle
removed="$tmp/removed"
retired="$tmp/retired"
retire_mode=success
docker(){
  local op="${1:-}" fmt name
  shift || true
  case "$op" in
    inspect)
      if [ "${1:-}" = --format ]; then
        fmt="$2"; name="$3"
        [ "${fake_exists[$name]:-0}" = 1 ] || return 1
        case "$fmt" in
          *State.Running*) [ "${fake_status[$name]}" = running ] && printf true || printf false ;;
          *State.Status*) printf '%s' "${fake_status[$name]}" ;;
          *managed*) printf true ;;
          *backend*) printf scaleset ;;
          *runner-id*) printf '%s' "$name" ;;
          *work-handle*) printf '%s' "${fake_handle[$name]}" ;;
          *pool*) printf '%s' "${fake_pool[$name]}" ;;
          *) return 1 ;;
        esac
      else
        name="$1"; [ "${fake_exists[$name]:-0}" = 1 ]
      fi
      ;;
    exec)
      name="$1"
      [ "${fake_exists[$name]:-0}" = 1 ] && [ "${fake_consumed[$name]:-0}" = 1 ]
      ;;
    cp) return 1 ;;
    rm)
      [ "${1:-}" = -f ] && shift
      name="$1"; fake_exists[$name]=0; printf '%s\n' "$name" >>"$removed"
      ;;
    ps)
      for name in "${!fake_exists[@]}"; do [ "${fake_exists[$name]}" = 1 ] && printf '%s\n' "$name"; done
      ;;
    *) return 1 ;;
  esac
}
scaleset_request(){
  [ "$1" = retire_jit ] || return 1
  printf '%s\n' "$2" >>"$retired"
  if [ "$retire_mode" = already ]; then
    printf '{"schema_version":1,"request_id":"r","ok":false,"code":"work_handle_not_issued"}\n'
    return 1
  fi
  if [ "$retire_mode" = unconfirmed ]; then
    printf '{"schema_version":1,"request_id":"r","ok":true,"result":{"retired":false}}\n'
    return 0
  fi
  printf '{"schema_version":1,"request_id":"r","ok":true,"result":{"retired":true}}\n'
}

write_state(){
  local path="$1" runner="$2" phase="$3" reservation="$4" work_handle="$5" updated="$6" pool_id="${7:-}"
  mkdir -p "$(dirname "$path")"
  printf 'schema_version=1\nrunner_id=%s\nphase=%s\nreservation_id=%s\nwork_handle=%s\ncontainer_name=%s\npool_id=%s\nupdated_at=%s\n' \
    "$runner" "$phase" "$reservation" "$work_handle" "$runner" "$pool_id" "$updated" >"$path"
  chmod 0600 "$path"
}

old=$(( $(date +%s) - 3600 ))
rust=ci-runner-jit-rust-aaaaaaaaaaaaaaaaaaaa
fake_exists[$rust]=1; fake_status[$rust]=exited; fake_consumed[$rust]=1; fake_pool[$rust]=rust; fake_handle[$rust]=101
mkdir -p "$CACHE_ROOT/work/$rust" "$CACHE_ROOT/docker/$rust"
touch "$CACHE_ROOT/work/$rust/artifact" "$CACHE_ROOT/docker/$rust/layer"
write_state "$JIT_LEGACY_STATE_DIR/$rust.state" "$rust" running lease-rust-old 101 "$old"
jit_reconcile
[ "${fake_exists[$rust]}" = 0 ] || crf_fail "exited legacy JIT container was not removed"
[ ! -e "$CACHE_ROOT/work/$rust" ] || crf_fail "retired JIT workspace was not removed"
[ ! -e "$CACHE_ROOT/docker/$rust" ] || crf_fail "retired JIT Docker root was not removed"
[ ! -e "$JIT_LEGACY_STATE_DIR/$rust.state" ] || crf_fail "legacy JIT state was not imported"
[ ! -e "$JIT_STATE_DIR/$rust.state" ] || crf_fail "fully retired JIT state was not removed"
grep -Fq '"pool_id":"rust"' "$retired" || crf_fail "retirement used the wrong pool"
grep -Fq '"work_handle":101' "$retired" || crf_fail "retirement used the wrong work handle"

fresh=ci-runner-jit-ops-bbbbbbbbbbbbbbbbbbbb
fake_exists[$fresh]=1; fake_status[$fresh]=running; fake_consumed[$fresh]=0; fake_pool[$fresh]=ops; fake_handle[$fresh]=202
write_state "$JIT_STATE_DIR/$fresh.state" "$fresh" container_observed lease-ops-fresh 202 "$(date +%s)" ops
before_retired="$(wc -l <"$retired")"
jit_reconcile
[ "${fake_exists[$fresh]}" = 1 ] || crf_fail "fresh JIT handoff was interrupted"
[ "$(jit_state_field "$JIT_STATE_DIR/$fresh.state" phase)" = container_observed ] || crf_fail "fresh handoff state changed"
[ "$(wc -l <"$retired")" = "$before_retired" ] || crf_fail "fresh handoff was retired"

write_state "$JIT_STATE_DIR/$fresh.state" "$fresh" container_observed lease-ops-fresh 202 "$old" ops
jit_reconcile
[ "${fake_exists[$fresh]}" = 0 ] || crf_fail "stale JIT handoff was not removed"
grep -Fq '"work_handle":202' "$retired" || crf_fail "stale handoff was not retired"

orphan=ci-runner-jit-python-cccccccccccccccccccc
fake_exists[$orphan]=1; fake_status[$orphan]=exited; fake_consumed[$orphan]=1; fake_pool[$orphan]=python; fake_handle[$orphan]=303
jit_reconcile
[ "${fake_exists[$orphan]}" = 0 ] || crf_fail "orphan exited JIT container was not removed"
grep -Fq '"work_handle":303' "$retired" || crf_fail "orphan work handle was not retired"

# A create attempt may fail before Docker exposes a container. Its already
# allocated work/docker trees must still detach before retirement and release.
create_failed=ci-runner-jit-rust-12121212121212121212
create_failed_reservation=lease-rust-create-failed
fake_exists[$create_failed]=0; fake_status[$create_failed]=exited; fake_consumed[$create_failed]=0; fake_pool[$create_failed]=rust; fake_handle[$create_failed]=313
mkdir -p "$CACHE_ROOT/work/$create_failed" "$CACHE_ROOT/docker/$create_failed"
touch "$CACHE_ROOT/work/$create_failed/artifact" "$CACHE_ROOT/docker/$create_failed/layer" \
  "$RESERVATION_DIR/$create_failed_reservation.state"
write_state "$JIT_STATE_DIR/$create_failed.state" "$create_failed" failed "$create_failed_reservation" 313 "$old" rust
jit_reconcile
[ ! -e "$CACHE_ROOT/work/$create_failed" ] && [ ! -e "$CACHE_ROOT/docker/$create_failed" ] || crf_fail "failed create left live runner data attached"
[ "$(jit_state_field "$JIT_STATE_DIR/$create_failed.state" phase)" = deleted ] || crf_fail "failed create state did not converge"
[ ! -e "$RESERVATION_DIR/$create_failed_reservation.state" ] || crf_fail "failed create reservation was not released"
grep -Fq '"work_handle":313' "$retired" || crf_fail "failed create handle was not retired"

# A delivered request without explicit retirement confirmation must remain in
# deleting state so reconciliation retries instead of releasing the reservation.
unconfirmed=ci-runner-jit-ops-eeeeeeeeeeeeeeeeeeee
fake_exists[$unconfirmed]=0; fake_status[$unconfirmed]=exited; fake_consumed[$unconfirmed]=1; fake_pool[$unconfirmed]=ops; fake_handle[$unconfirmed]=505
write_state "$JIT_STATE_DIR/$unconfirmed.state" "$unconfirmed" deleting lease-ops-unconfirmed 505 "$old" ops
retire_mode=unconfirmed
jit_reconcile
[ -e "$JIT_STATE_DIR/$unconfirmed.state" ] || crf_fail "unconfirmed retirement deleted retry state"
[ "$(jit_state_field "$JIT_STATE_DIR/$unconfirmed.state" phase)" = deleting ] || crf_fail "unconfirmed retirement changed retry phase"
grep -Fq '"work_handle":505' "$retired" || crf_fail "unconfirmed handle was not attempted"

# A controller restart or lost response can leave the root-owned state in
# deleting after the issued-handle tombstone was already removed. That specific
# terminal response is an idempotent success, not a permanent cleanup loop.
lost=ci-runner-jit-rust-dddddddddddddddddddd
fake_exists[$lost]=0; fake_status[$lost]=exited; fake_consumed[$lost]=1; fake_pool[$lost]=rust; fake_handle[$lost]=404
write_state "$JIT_STATE_DIR/$lost.state" "$lost" deleting lease-rust-lost 404 "$old" rust
retire_mode=already
jit_reconcile
[ ! -e "$JIT_STATE_DIR/$lost.state" ] || crf_fail "already-retired deleting state did not converge"
grep -Fq '"work_handle":404' "$retired" || crf_fail "already-retired handle was not retried"

# Filesystem cleanup must finish before remote retirement or reservation
# release. An unsafe cache root leaves retry state and all local proof/data.
blocked=ci-runner-jit-ops-ffffffffffffffffffff
blocked_reservation=lease-ops-blocked
fake_exists[$blocked]=0; fake_status[$blocked]=exited; fake_consumed[$blocked]=1; fake_pool[$blocked]=ops; fake_handle[$blocked]=606
mkdir -p "$CACHE_ROOT/work/$blocked" "$CACHE_ROOT/docker/$blocked"
touch "$CACHE_ROOT/work/$blocked/artifact" "$CACHE_ROOT/docker/$blocked/layer" \
  "$RESERVATION_DIR/$blocked_reservation.state"
write_state "$JIT_STATE_DIR/$blocked.state" "$blocked" terminal "$blocked_reservation" 606 "$old" ops
before_retired="$(wc -l <"$retired")"
safe_cache_root_mode=invalid
if jit_cleanup_observed "$blocked" "$blocked_reservation" 606 "$blocked" ops; then
  crf_fail "cleanup accepted an invalid safe cache root"
fi
safe_cache_root_mode=success
[ "$(jit_state_field "$JIT_STATE_DIR/$blocked.state" phase)" = deleting ] || crf_fail "failed cleanup did not retain deleting state"
[ -e "$RESERVATION_DIR/$blocked_reservation.state" ] || crf_fail "failed cleanup released reservation"
[ -e "$CACHE_ROOT/work/$blocked/artifact" ] && [ -e "$CACHE_ROOT/docker/$blocked/layer" ] || crf_fail "failed cleanup removed runner data"
[ "$(wc -l <"$retired")" = "$before_retired" ] || crf_fail "failed local cleanup attempted remote retirement"

# The same ordering holds when the root is valid but atomic detachment fails.
remove_failed=ci-runner-jit-python-99999999999999999999
remove_failed_reservation=lease-python-remove-failed
fake_exists[$remove_failed]=0; fake_status[$remove_failed]=exited; fake_consumed[$remove_failed]=1; fake_pool[$remove_failed]=python; fake_handle[$remove_failed]=707
mkdir -p "$CACHE_ROOT/work/$remove_failed" "$CACHE_ROOT/docker/$remove_failed"
touch "$CACHE_ROOT/work/$remove_failed/artifact" "$CACHE_ROOT/docker/$remove_failed/layer" \
  "$RESERVATION_DIR/$remove_failed_reservation.state"
write_state "$JIT_STATE_DIR/$remove_failed.state" "$remove_failed" terminal "$remove_failed_reservation" 707 "$old" python
before_retired="$(wc -l <"$retired")"
detach_failure_runner="$remove_failed"
if jit_cleanup_observed "$remove_failed" "$remove_failed_reservation" 707 "$remove_failed" python; then
  crf_fail "cleanup ignored runner-data detach failure"
fi
detach_failure_runner=
[ "$(jit_state_field "$JIT_STATE_DIR/$remove_failed.state" phase)" = deleting ] || crf_fail "removal failure did not retain deleting state"
[ -e "$RESERVATION_DIR/$remove_failed_reservation.state" ] || crf_fail "removal failure released reservation"
[ -e "$CACHE_ROOT/work/$remove_failed/artifact" ] && [ -e "$CACHE_ROOT/docker/$remove_failed/layer" ] || crf_fail "removal failure did not preserve runner data"
[ "$(wc -l <"$retired")" = "$before_retired" ] || crf_fail "removal failure attempted remote retirement"

# Invalid identities are rejected before any path removal, while already
# absent valid paths are an idempotent success.
sentinel="$CACHE_ROOT/work/do-not-remove"
mkdir -p "$sentinel"
touch "$sentinel/artifact"
if jit_runner_data_remove '../do-not-remove'; then
  crf_fail "invalid runner ID was accepted for data removal"
fi
[ -e "$sentinel/artifact" ] || crf_fail "invalid runner ID removed unrelated data"
absent=ci-runner-jit-rust-11111111111111111111
jit_runner_data_remove "$absent" || crf_fail "absent runner paths were not idempotent"
[ ! -e "$CACHE_ROOT/work/$absent" ] && [ ! -e "$CACHE_ROOT/docker/$absent" ] || crf_fail "absent cleanup created runner paths"

# These deliberately failed cases have proven their retry state. Remove the
# fixtures so the latency assertion below measures one reconciliation cleanup.
command rm -rf "$CACHE_ROOT/work/$blocked" "$CACHE_ROOT/docker/$blocked" \
  "$CACHE_ROOT/work/$remove_failed" "$CACHE_ROOT/docker/$remove_failed"
command rm -f "$JIT_STATE_DIR/$blocked.state" "$JIT_STATE_DIR/$remove_failed.state" \
  "$RESERVATION_DIR/$blocked_reservation.state" "$RESERVATION_DIR/$remove_failed_reservation.state"

# Recursive reclamation runs outside reconciliation. Even deliberately slow rm
# must not delay retirement or reservation convergence.
slow=ci-runner-jit-rust-22222222222222222222
slow_reservation=lease-rust-slow
fake_exists[$slow]=0; fake_status[$slow]=exited; fake_consumed[$slow]=1; fake_pool[$slow]=rust; fake_handle[$slow]=808
mkdir -p "$CACHE_ROOT/work/$slow" "$CACHE_ROOT/docker/$slow"
touch "$CACHE_ROOT/work/$slow/artifact" "$CACHE_ROOT/docker/$slow/layer" "$RESERVATION_DIR/$slow_reservation.state"
write_state "$JIT_STATE_DIR/$slow.state" "$slow" terminal "$slow_reservation" 808 "$old" rust
slow_gc_rm_seconds=0
wait "${JIT_GC_SWEEPER_PID:-}" 2>/dev/null || crf_fail "earlier GC sweep failed before blocked cleanup proof"
: >"$gc_rm_started"; : >"$gc_rm_finished"; : >"$gc_inherited_fd5"; : >"$gc_inherited_fd8"
: >"$gc_rm_gate"
exec 5>"$tmp/autoscale-tick.lock"
flock 5
exec 8>"$tmp/autoscale-fleet.lock"
flock 8
jit_reconcile
flock -u 8; exec 8>&-
flock -u 5; exec 5>&-
[ ! -e "$JIT_STATE_DIR/$slow.state" ] || crf_fail "slow cleanup did not converge JIT state"
[ ! -e "$RESERVATION_DIR/$slow_reservation.state" ] || crf_fail "slow cleanup did not release reservation"
[ ! -e "$CACHE_ROOT/work/$slow" ] && [ ! -e "$CACHE_ROOT/docker/$slow" ] || crf_fail "slow cleanup left live runner paths attached"
for _ in {1..100}; do [ -s "$gc_rm_started" ] && break; sleep 0.01; done
[ -s "$gc_rm_started" ] || crf_fail "background GC sweep did not start"
[ ! -s "$gc_rm_finished" ] || crf_fail "blocked recursive deletion completed before reconciliation returned"
[ ! -s "$gc_inherited_fd5" ] || crf_fail "GC sweeper inherited the autoscale tick lock fd"
[ ! -s "$gc_inherited_fd8" ] || crf_fail "GC sweeper inherited the autoscale lock fd"
rm -f "$gc_rm_gate"
wait "${JIT_GC_SWEEPER_PID:-}" 2>/dev/null || crf_fail "blocked GC sweep failed after release"
[ -s "$gc_rm_finished" ] || crf_fail "released recursive deletion did not complete"
find "$CACHE_ROOT/.jit-gc" -maxdepth 1 -name "$slow.*" | grep -q . &&
  crf_fail "released recursive deletion left quarantined runner data"

# The production command is commonly invoked through a pipe or output-capturing
# caller. The detached sweeper must not retain those descriptors and delay EOF.
pipe_item="$CACHE_ROOT/.jit-gc/pipe-latency"
mkdir -p "$pipe_item"; touch "$pipe_item/artifact"
slow_gc_rm_seconds=1
export CACHE_ROOT RUNDIR JIT_GC_SWEEP_MAX JIT_GC_SWEEPER_PID slow_gc_rm_seconds
export gc_rm_started gc_rm_finished gc_rm_gate gc_rm_active gc_rm_max_active gc_inherited_fd5 gc_inherited_fd8
export safe_cache_root_mode detach_failure_runner gc_remove_failure
export -f crf_safe_cache_root jit_gc_log jit_gc_root_prepare jit_gc_sweep_config_valid
export -f jit_gc_sweep jit_gc_sweep_start rm mv
: >"$gc_rm_gate"
pipe_result="$(timeout 2 bash -c 'jit_gc_sweep_start; printf detached' | cat)" ||
  crf_fail "piped caller retained background GC descriptors"
[ "$pipe_result" = detached ] || crf_fail "piped GC start returned unexpected output"
[ -e "$pipe_item" ] || crf_fail "blocked piped GC reclaimed its fixture before gate release"
rm -f "$gc_rm_gate"
for _ in {1..200}; do
  grep -Fq "jit-gc: reclaimed item=pipe-latency" "$RUNDIR/autoscale.log" 2>/dev/null && break
  sleep 0.01
done
grep -Fq "jit-gc: reclaimed item=pipe-latency" "$RUNDIR/autoscale.log" 2>/dev/null ||
  crf_fail "detached piped GC did not report completion"
[ ! -e "$pipe_item" ] || crf_fail "detached piped GC did not reclaim its fixture"

# Configuration errors are rejected before a child is launched, allowing the
# caller to emit sweeper_start_failed telemetry synchronously.
JIT_GC_SWEEP_MAX=0
before_gc_log="$(wc -l <"$RUNDIR/autoscale.log")"
if jit_gc_sweep_start; then
  crf_fail "invalid GC sweep maximum started a background child"
fi
invalid_gc_telemetry="$(jit_gc_sweep_start 2>&1 || jit_gc_log "sweeper_start_failed test-invalid-config" 2>&1)"
[[ "$invalid_gc_telemetry" == *"jit-gc: sweeper_start_failed test-invalid-config"* ]] ||
  crf_fail "invalid GC configuration did not emit synchronous failure telemetry"
[ "$(wc -l <"$RUNDIR/autoscale.log")" = "$before_gc_log" ] ||
  crf_fail "invalid GC configuration launched an asynchronous sweeper"
JIT_GC_SWEEP_MAX=8

# A failed sweep remains quarantined and is retried by a later reconcile, which
# models daemon restart recovery. Only one sweeper may reclaim at a time.
slow_gc_rm_seconds=0
wait "${JIT_GC_SWEEPER_PID:-}" 2>/dev/null || true
retry_item="$CACHE_ROOT/.jit-gc/retry.manual"
mkdir -p "$retry_item"; touch "$retry_item/artifact"
gc_remove_failure=retry.manual
jit_gc_sweep_start
wait "${JIT_GC_SWEEPER_PID:-}" 2>/dev/null || true
gc_remove_failure=
find "$CACHE_ROOT/.jit-gc" -maxdepth 2 -type f -path '*retry.manual*/artifact' | grep -q . ||
  crf_fail "failed sweep did not preserve quarantined data"
slow_gc_rm_seconds=1
jit_reconcile
first_sweeper="$JIT_GC_SWEEPER_PID"
jit_gc_sweep_start
second_sweeper="$JIT_GC_SWEEPER_PID"
[ "$first_sweeper" = "$second_sweeper" ] || crf_fail "concurrent GC sweepers were started"
wait "$first_sweeper" 2>/dev/null || true
find "$CACHE_ROOT/.jit-gc" -maxdepth 1 -name '*retry.manual*' | grep -q . &&
  crf_fail "quarantined data was not retried on the next sweep"
[ "$(cat "$gc_rm_max_active" 2>/dev/null || printf 0)" -le 1 ] || crf_fail "GC reclamation concurrency was not bounded"

# Failed entries rotate behind untouched work so a full failed batch cannot
# starve a later reclaimable item forever.
slow_gc_rm_seconds=0
for n in {1..9}; do mkdir -p "$CACHE_ROOT/.jit-gc/a-fail-$n"; done
mkdir -p "$CACHE_ROOT/.jit-gc/b-reclaim"; touch "$CACHE_ROOT/.jit-gc/b-reclaim/artifact"
gc_remove_failure=a-fail
jit_gc_sweep_start; wait "${JIT_GC_SWEEPER_PID:-}" 2>/dev/null || true
jit_gc_sweep_start; wait "${JIT_GC_SWEEPER_PID:-}" 2>/dev/null || true
gc_remove_failure=
[ ! -e "$CACHE_ROOT/.jit-gc/b-reclaim" ] || crf_fail "failed GC batch starved later reclaimable data"

# Symlinked parent roots are rejected before moving anything outside CACHE_ROOT.
outside="$tmp/outside"; mkdir -p "$outside/$absent"; touch "$outside/$absent/sentinel"
mv "$CACHE_ROOT/work" "$CACHE_ROOT/work.real"
ln -s "$outside" "$CACHE_ROOT/work"
if jit_runner_data_remove "$absent"; then
  crf_fail "symlinked work root was accepted for detachment"
fi
[ -e "$outside/$absent/sentinel" ] || crf_fail "symlinked work root moved outside data"
rm "$CACHE_ROOT/work"; mv "$CACHE_ROOT/work.real" "$CACHE_ROOT/work"

echo "jit-recovery: OK"
