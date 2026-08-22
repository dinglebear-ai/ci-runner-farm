#!/usr/bin/env bash
# Behavioral coverage for reconciling containers stalled at credential handoff.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmpdir="$(mktemp -d)"
snippet="$tmpdir/functions.sh"
trap 'rm -rf "$tmpdir"' EXIT

for fn in runner_credential_handoff_stalled recover_stalled_credential_handoffs boot_autostart_locked cmd_boot_autostart; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >>"$snippet"
done
# shellcheck disable=SC1090
. "$snippet"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_true() { "$@" || fail "expected success: $*"; }
expect_false() { if "$@"; then fail "expected failure: $*"; fi; }

NOW=1000
START_EPOCH=700
STARTED_AT=2026-08-05T17:00:00Z
DATE_OK=true
INVENTORY_STARTED=true
READY=true
CONSUMED=false
LISTENER=false
TOP_OK=true

inventory_field() {
  case "$2" in
    state) printf '%s\n' running ;;
    started_at)
      [ "$INVENTORY_STARTED" = true ] || return 1
      printf '%s\n' "$STARTED_AT"
      ;;
    *) return 1 ;;
  esac
}

date() {
  case "${1:-}" in
    +%s) printf '%s\n' "$NOW" ;;
    -d)
      [ "$DATE_OK" = true ] || return 1
      printf '%s\n' "$START_EPOCH"
      ;;
    *) command date "$@" ;;
  esac
}

docker() {
  case "${1:-}:${2:-}" in
    exec:ci-runner-rust-1)
      case "${4:-}" in
        -f) [ "$READY" = true ] ;;
        !) [ "$CONSUMED" = false ] ;;
        *) return 99 ;;
      esac
      ;;
    top:ci-runner-rust-1)
      [ "$TOP_OK" = true ] || return 1
      printf 'COMMAND\n'
      if [ "$LISTENER" = true ]; then
        printf '/actions-runner/bin/Runner.Listener run --startuptype service\n'
      else
        printf '/usr/local/bin/crf-runner-entrypoint\n'
      fi
      ;;
    *)
      printf 'unexpected docker call: %s\n' "$*" >&2
      return 99
      ;;
  esac
}

reset_case() {
  NOW=1000
  START_EPOCH=700
  STARTED_AT=2026-08-05T17:00:00Z
  DATE_OK=true
  INVENTORY_STARTED=true
  READY=true
  CONSUMED=false
  LISTENER=false
  TOP_OK=true
}

reset_case
expect_true runner_credential_handoff_stalled ci-runner-rust-1

reset_case
START_EPOCH=761
expect_false runner_credential_handoff_stalled ci-runner-rust-1

reset_case
LISTENER=true
expect_false runner_credential_handoff_stalled ci-runner-rust-1

reset_case
READY=false
expect_false runner_credential_handoff_stalled ci-runner-rust-1

reset_case
CONSUMED=true
expect_false runner_credential_handoff_stalled ci-runner-rust-1

reset_case
DATE_OK=false
expect_false runner_credential_handoff_stalled ci-runner-rust-1

reset_case
TOP_OK=false
expect_false runner_credential_handoff_stalled ci-runner-rust-1

reset_case
INVENTORY_STARTED=false
expect_false runner_credential_handoff_stalled ci-runner-rust-1

# The recovery sweep repairs only conclusively stalled, valid classic runners.
recovery_log="$tmpdir/recovered"
refresh_count="$tmpdir/refresh-count"
token_count="$tmpdir/token-count"
TOKEN_OK=true
load_cfg() { :; }
validate_runtime_config() { return 0; }
github_api_token_load() {
  local count=0
  [ -f "$token_count" ] && count="$(cat "$token_count")"
  printf '%s\n' "$((count + 1))" >"$token_count"
  [ "$TOKEN_OK" = true ]
}
fleet_inventory_refresh() {
  local count=0
  [ -f "$refresh_count" ] && count="$(cat "$refresh_count")"
  printf '%s\n' "$((count + 1))" >"$refresh_count"
}
inventory_names() { printf '%s\n' ci-runner-rust-1 ci-runner-rust-2 ci-runner-invalid; }
runner_identity_validate() { [ "$1" != ci-runner-invalid ]; }
runner_credential_handoff_stalled() { [ "$1" = ci-runner-rust-2 ]; }
recreate_runner() { printf '%s|%s\n' "$1" "$2" >>"$recovery_log"; }
log() { :; }
err() { :; }
POOL_CONFIG_ERROR='invalid test config'
MAINTENANCE_FILE=''

expect_true recover_stalled_credential_handoffs
[ "$(cat "$recovery_log")" = 'ci-runner-rust-2|force' ] ||
  fail 'recovery did not recycle only the conclusively stalled runner'
[ "$(cat "$refresh_count")" -eq 2 ] ||
  fail 'recovery did not refresh inventory before and after replacement'
[ "$(cat "$token_count")" -eq 1 ] ||
  fail 'recovery did not reload the GitHub API token after config reload'

# The watchdog may reuse the inventory it refreshed immediately beforehand.
rm -f "$recovery_log" "$refresh_count" "$token_count"
INVENTORY_ACTIVE=1
INVENTORY_FILE="$tmpdir/inventory.tsv"
: >"$INVENTORY_FILE"
expect_true recover_stalled_credential_handoffs reuse
[ "$(cat "$recovery_log")" = 'ci-runner-rust-2|force' ] ||
  fail 'inventory-reuse recovery did not recycle the stalled runner'
[ "$(cat "$refresh_count")" -eq 1 ] ||
  fail 'inventory-reuse recovery performed an unnecessary initial refresh'

rm -f "$recovery_log" "$refresh_count" "$token_count" "$INVENTORY_FILE"
expect_false recover_stalled_credential_handoffs reuse
[ ! -e "$recovery_log" ] || fail 'missing reusable inventory recycled a runner'

# A missing or expired token fails closed before inventory or mutation.
rm -f "$recovery_log" "$refresh_count" "$token_count"
TOKEN_OK=false
expect_false recover_stalled_credential_handoffs
[ ! -e "$recovery_log" ] || fail 'token failure recycled a runner'
[ ! -e "$refresh_count" ] || fail 'token failure inspected the fleet before authorization'
TOKEN_OK=true

# Maintenance and scale-set mode preserve the classic fleet.
: >"$tmpdir/maintenance"
MAINTENANCE_FILE="$tmpdir/maintenance"
rm -f "$recovery_log" "$refresh_count" "$token_count"
expect_true recover_stalled_credential_handoffs
[ ! -e "$recovery_log" ] || fail 'maintenance mode recycled a runner'
[ ! -e "$token_count" ] || fail 'maintenance mode loaded a mutation credential'
MAINTENANCE_FILE=''
backend_effective() { printf '%s\n' scaleset; }
expect_true recover_stalled_credential_handoffs
[ ! -e "$recovery_log" ] || fail 'scale-set mode recycled a classic runner'
[ ! -e "$token_count" ] || fail 'scale-set mode loaded a classic mutation credential'
unset -f backend_effective

# Boot autostart retries a transient partial start before waiting beyond the
# handoff window and invoking recovery under the same fleet lock as all other
# mutations.
operation_reconcile_interrupted() { return 0; }
(
  boot_calls="$tmpdir/boot-calls"
  sleep_calls="$tmpdir/sleep-calls"
  start_count_file="$tmpdir/start-count"
  RUNDIR="$tmpdir/serial-run"
  mkdir -p "$RUNDIR"
  auth_credentials_configured() { return 0; }
  docker() { [ "${1:-}" = info ]; }
  check_cache_root() { return 0; }
  log() { :; }
  err() { :; }
  with_fleet_lock() {
    printf '%s|%s\n' "$1" "$2" >>"$boot_calls"
    if [ "$2" = cmd_start ]; then
      start_count=0
      [ -f "$start_count_file" ] && start_count="$(cat "$start_count_file")"
      start_count=$((start_count + 1))
      printf '%s\n' "$start_count" >"$start_count_file"
      [ "$start_count" -ge 3 ]
    fi
  }
  sleep() { printf '%s\n' "$1" >>"$sleep_calls"; }
  RUNNER_CREDENTIAL_HANDOFF_STALL_SECONDS=7
  BOOT_AUTOSTART_START_ATTEMPTS=3
  BOOT_AUTOSTART_RETRY_DELAY_SECONDS=2
  cmd_boot_autostart || fail 'boot autostart gave up before the transient start failure cleared'
  [ "$(cat "$boot_calls")" = $'wait|cmd_start\nwait|cmd_start\nwait|cmd_start\nwait|recover_stalled_credential_handoffs' ] ||
    fail 'boot autostart did not retry partial starts before the recovery sweep'
  [ "$(cat "$sleep_calls")" = $'2\n2\n7' ] ||
    fail 'boot autostart did not apply retry delays before the handoff wait'
)

# The plugin install path and docker_started event can fire together during
# boot. Concurrent autostarts must coalesce into one fleet mutation.
(
  boot_calls="$tmpdir/concurrent-boot-calls"
  first_start="$tmpdir/concurrent-first-start"
  RUNDIR="$tmpdir/concurrent-run"
  mkdir -p "$RUNDIR"
  auth_credentials_configured() { return 0; }
  docker() { [ "${1:-}" = info ]; }
  check_cache_root() { return 0; }
  log() { :; }
  err() { :; }
  with_fleet_lock() {
    printf '%s\n' "$2" >>"$boot_calls"
    if [ "$2" = cmd_start ]; then
      : >"$first_start"
      command sleep 0.2
    fi
  }
  RUNNER_CREDENTIAL_HANDOFF_STALL_SECONDS=0
  cmd_boot_autostart & first_pid=$!
  for _ in $(seq 1 50); do
    [ -f "$first_start" ] && break
    command sleep 0.01
  done
  [ -f "$first_start" ] || fail 'first boot autostart never reached fleet start'
  cmd_boot_autostart & second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
  [ "$(grep -c '^cmd_start$' "$boot_calls")" -eq 1 ] ||
    fail 'concurrent boot autostarts did not coalesce into one fleet start'
)

[ "$(grep -c '^runner_credential_handoff_stalled()' "$ENGINE")" -eq 1 ] ||
  fail 'stalled handoff helper must be defined exactly once'
[ "$(grep -c '^recover_stalled_credential_handoffs()' "$ENGINE")" -eq 1 ] ||
  fail 'stalled handoff recovery must be defined exactly once'
grep -Fq 'started_at) col=13' "$ENGINE" ||
  fail 'inventory does not expose runner start time to credential recovery'
# shellcheck disable=SC2016
grep -Fq 'runner_credential_handoff_stalled "$c"' "$ENGINE" ||
  fail 'reconcile does not invoke stalled handoff predicate'
# shellcheck disable=SC2016
grep -Fq 'recreate_runner "$c" force' "$ENGINE" ||
  fail 'recovery does not use verified force recycle for stalled handoff'
grep -Fq 'with_fleet_lock wait recover_stalled_credential_handoffs' "$ENGINE" ||
  fail 'boot autostart does not run delayed recovery under the fleet lock'

echo 'stalled-credential-handoff: OK'
