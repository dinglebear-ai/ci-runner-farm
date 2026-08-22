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
remove_failure_runner=
crf_safe_cache_root(){
  [ "$safe_cache_root_mode" = success ] || return 1
  printf '%s' "$CACHE_ROOT"
}
rm(){
  local arg
  if [ -n "$remove_failure_runner" ]; then
    for arg in "$@"; do
      [[ "$arg" == *"/$remove_failure_runner" ]] && return 1
    done
  fi
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

# The same ordering holds when the root is valid but removal itself fails.
remove_failed=ci-runner-jit-python-99999999999999999999
remove_failed_reservation=lease-python-remove-failed
fake_exists[$remove_failed]=0; fake_status[$remove_failed]=exited; fake_consumed[$remove_failed]=1; fake_pool[$remove_failed]=python; fake_handle[$remove_failed]=707
mkdir -p "$CACHE_ROOT/work/$remove_failed" "$CACHE_ROOT/docker/$remove_failed"
touch "$CACHE_ROOT/work/$remove_failed/artifact" "$CACHE_ROOT/docker/$remove_failed/layer" \
  "$RESERVATION_DIR/$remove_failed_reservation.state"
write_state "$JIT_STATE_DIR/$remove_failed.state" "$remove_failed" terminal "$remove_failed_reservation" 707 "$old" python
before_retired="$(wc -l <"$retired")"
remove_failure_runner="$remove_failed"
if jit_cleanup_observed "$remove_failed" "$remove_failed_reservation" 707 "$remove_failed" python; then
  crf_fail "cleanup ignored runner-data removal failure"
fi
remove_failure_runner=
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

echo "jit-recovery: OK"
