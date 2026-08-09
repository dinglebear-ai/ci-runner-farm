#!/usr/bin/env bash
# Behavioral coverage for reconcile preparation, durable retry, and Stop fencing.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
extract_function() { sed -n "/^${1}()/,/^}/p" "$ENGINE" >>"$2"; }

if [ "${1:-}" = reconcile-drain ] && [ -n "${CRF_RETRY_TEST_DIR:-}" ]; then
  probe="$CRF_RETRY_TEST_DIR"
  functions="$probe/worker-functions.sh"
  : >"$functions"
  extract_function cmd_reconcile_drain "$functions"
  # shellcheck disable=SC1090
  . "$functions"
  load_cfg() { :; }
  count_reconcile_work() { [ -e "$probe/recycled" ] && echo 0 || echo 1; }
  with_fleet_lock() { shift; "$@"; }
  reconcile_stale_runners() {
    if [ -e "$probe/stop-issued" ]; then
      : >"$probe/mutation-after-stop"
      : >"$probe/capacity-return-after-stop"
    elif [ "$(cat "$probe/state")" = idle ]; then
      : >"$probe/recycled"
    fi
  }
  managed_names() { echo ci-runner-stale; }
  runner_pool() { echo default; }
  pool_mode_enabled() { return 1; }
  count_pool_desired_drift() { echo 0; }
  count_pool_missing_capacity() { echo 0; }
  count_stale_runners() { echo 1; }
  reconcile_identity_clear() { :; }
  log() {
    case "$*" in
      *'retrying idle-safe recycling every 120s'*) : >"$probe/retry-announced" ;;
    esac
  }
  err() { printf '%s\n' "$*" >>"$probe/error"; }
  date() {
    if [ -e "$probe/date-called" ]; then echo 2
    else : >"$probe/date-called"; echo 0
    fi
  }
  sleep() {
    local duration="$1"
    if [ "$duration" = 120 ]; then
      : >"$probe/retry-sleep"
      if [ "${CRF_RETRY_STOP_CASE:-0}" = 1 ]; then
        while [ ! -e "$probe/release-sleep" ]; do /bin/sleep 0.01; done
      else
        printf 'idle\n' >"$probe/state"
      fi
    else
      /bin/sleep 0.01
    fi
  }
  RUNDIR="$probe/run"
  TOKEN_FILE="$probe/token"
  ACCESS_TOKEN=test
  IMAGE_DRAIN_TIMEOUT=1
  cmd_reconcile_drain
  exit 0
fi

tmp="$(mktemp -d)"
worker_pid=''
test_pgid="$(ps -o pgid= -p "$$" | tr -d '[:space:]')"
cleanup() {
  local pgid
  if [ -n "$worker_pid" ]; then
    pgid="$(ps -o pgid= -p "$worker_pid" 2>/dev/null | tr -d '[:space:]')"
    if [ "$pgid" = "$worker_pid" ] && [ "$pgid" != "$test_pgid" ]; then
      kill -KILL -- "-$worker_pid" 2>/dev/null || true
    fi
    wait "$worker_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Missing promoted aliases must be restored before the fingerprint is computed.
prep="$tmp/prep-functions.sh"
extract_function crf_confgen_prepare "$prep"
extract_function count_reconcile_work "$prep"
# shellcheck disable=SC1090
. "$prep"
IMAGE_SOURCE=builtin
BUILTIN_IMAGE=ci-runner-farm-runner:latest
SCRIPT_DIR="$tmp"
printf '#!/bin/sh\n' >"$SCRIPT_DIR/runner-entrypoint.sh"
alias_available=0
effective_image() { echo "$BUILTIN_IMAGE"; }
restore_promoted_image_alias() { alias_available=1; : >"$tmp/alias-restored"; }
docker() {
  [ "$1 $2" = 'image inspect' ] || return 1
  [ "$alias_available" = 1 ] || return 1
  printf 'sha256:%064d\n' 0 | tr 0 a
}
crf_confgen_prepare || { echo 'FAIL: missing promoted alias was not restored before fingerprinting' >&2; exit 1; }
[ -e "$tmp/alias-restored" ] || { echo 'FAIL: fingerprint preparation skipped promoted alias recovery' >&2; exit 1; }

# Preparation/inventory failures are unknown work, never a clean zero-work result.
count_stale_runners() { return 42; }
count_pool_desired_drift() { : >"$tmp/drift-called"; echo 0; }
if result="$(count_reconcile_work)"; then
  echo "FAIL: reconcile work preparation failure became successful count '${result:-empty}'" >&2
  exit 1
fi
[ ! -e "$tmp/drift-called" ] || { echo 'FAIL: reconcile work continued after stale-count preparation failed' >&2; exit 1; }

controller="$tmp/controller-functions.sh"
: >"$controller"
for fn in reconcile_proc_record reconcile_identity_read reconcile_group_live reconcile_group_owned \
  reconcile_identity_clear reconcile_pid_active reconcile_start reconcile_stop with_fleet_lock \
  cmd_stop_fenced cmd_reconcile_config; do
  extract_function "$fn" "$controller"
done
# shellcheck disable=SC1090
. "$controller"
RUNDIR="$tmp/run"
RECONCILE_PID="$RUNDIR/reconcile.pid"
RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"
mkdir -p "$RUNDIR"
export CRF_RETRY_TEST_DIR="$tmp"
validate_runtime_config() { return 0; }
mutation_owner_guard() { return 0; }
log() { :; }
err() { printf '%s\n' "$*" >&2; }
cmd_stop() { : >"$tmp/stop-completed"; }
NETWORK_ISOLATION=off

# Expire the foreground timeout while busy, then become idle during the durable
# backoff. The later retry must recycle without another Apply/Start.
printf 'busy\n' >"$tmp/state"
cmd_reconcile_config >/dev/null
worker_pid="$(cat "$RECONCILE_PID")"
for _ in $(seq 1 200); do [ -e "$tmp/recycled" ] && break; /bin/sleep 0.01; done
[ -e "$tmp/retry-announced" ] || { echo 'FAIL: expired drain did not enter durable retry' >&2; exit 1; }
[ -e "$tmp/recycled" ] || { echo 'FAIL: busy-to-idle stale runner was not recycled by a later retry' >&2; exit 1; }
wait "$worker_pid" 2>/dev/null || true
worker_pid=''

# A second worker stopped during its retry sleep must never reach another
# reconcile mutation or return capacity after Stop begins.
rm -f "$tmp/recycled" "$tmp/retry-announced" "$tmp/retry-sleep" "$tmp/date-called"
printf 'busy\n' >"$tmp/state"
export CRF_RETRY_STOP_CASE=1
cmd_reconcile_config >/dev/null
worker_pid="$(cat "$RECONCILE_PID")"
worker_pgid="$(ps -o pgid= -p "$worker_pid" | tr -d '[:space:]')"
worker_sid="$(ps -o sid= -p "$worker_pid" | tr -d '[:space:]')"
[ "$worker_pgid" = "$worker_pid" ] && [ "$worker_sid" = "$worker_pid" ] && [ "$worker_pgid" != "$test_pgid" ] || {
  echo 'FAIL: retry worker is not isolated from the test process group' >&2; exit 1;
}
for _ in $(seq 1 200); do [ -e "$tmp/retry-sleep" ] && break; /bin/sleep 0.01; done
[ -e "$tmp/retry-sleep" ] || { echo 'FAIL: Stop fixture did not reach durable retry sleep' >&2; exit 1; }
: >"$tmp/stop-issued"
cmd_stop_fenced
[ -e "$tmp/stop-completed" ] || { echo 'FAIL: Stop did not complete' >&2; exit 1; }
[ ! -e "$tmp/mutation-after-stop" ] || { echo 'FAIL: retry mutated after Stop' >&2; exit 1; }
[ ! -e "$tmp/capacity-return-after-stop" ] || { echo 'FAIL: retry returned capacity after Stop' >&2; exit 1; }
wait "$worker_pid" 2>/dev/null || true
worker_pid=''

echo 'reconcile-retry: OK'
