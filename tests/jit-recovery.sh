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
. "$SCRIPT_DIR/runner-resources.sh"
. "$SCRIPT_DIR/runner-jit.sh"
CACHE_ROOT="$tmp/configured"
jit_paths_refresh

declare -A fake_exists fake_status fake_consumed fake_pool fake_handle
removed="$tmp/removed"
retired="$tmp/retired"
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
write_state "$JIT_LEGACY_STATE_DIR/$rust.state" "$rust" running lease-rust-old 101 "$old"
jit_reconcile
[ "${fake_exists[$rust]}" = 0 ] || crf_fail "exited legacy JIT container was not removed"
[ ! -e "$JIT_LEGACY_STATE_DIR/$rust.state" ] || crf_fail "legacy JIT state was not imported"
[ "$(jit_state_field "$JIT_STATE_DIR/$rust.state" phase)" = deleted ] || crf_fail "legacy JIT state was not retired"
[ "$(jit_state_field "$JIT_STATE_DIR/$rust.state" pool_id)" = rust ] || crf_fail "pool identity was not recovered"
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

echo "jit-recovery: OK"
