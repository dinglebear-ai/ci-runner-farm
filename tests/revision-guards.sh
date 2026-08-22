#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-revision-guards.XXXXXX)"
trap 'rm -rf "$root"' EXIT
RUNDIR="$root/run"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
INVENTORY_FILE="$RUNDIR/fleet-inventory.tsv"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-api.sh"

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
lock_snippet="$root/with-fleet-lock.sh"
sed -n '/^with_fleet_lock()/,/^}/p' "$engine" >"$lock_snippet"
mutation_owner_guard(){ return 0; }
# shellcheck disable=SC1090
. "$lock_snippet"

request_id='5aa00001-0000-4000-8000-000000000001'
config_one="$(printf config-one | sha256sum | cut -d' ' -f1)"
config_two="$(printf config-two | sha256sum | cut -d' ' -f1)"
printf '%s\n' "$config_one" >"$root/config.source"
printf '%s\n' 'runner-one|running' >"$root/inventory.source"
CURRENT_CONFIG=
load_calls="$root/load.calls"
inventory_calls="$root/inventory.calls"
lock_calls="$root/lock.calls"
action_calls="$root/action.calls"

load_cfg(){
  printf 'load\n' >>"$load_calls"
  CURRENT_CONFIG="$(cat "$root/config.source")"
}
config_revision(){ printf '%s\n' "$CURRENT_CONFIG"; }
fleet_inventory_refresh(){
  printf 'inventory\n' >>"$inventory_calls"
  [ "${CRF_TEST_INVENTORY_FAIL:-0}" = 0 ] || return 1
  cp "$root/inventory.source" "$INVENTORY_FILE"
  chmod 0600 "$INVENTORY_FILE"
}
migration_load(){ return 1; }
err(){ printf '%s\n' "$*" >>"$root/errors"; }
flock(){
  printf 'lock\n' >>"$lock_calls"
  command flock "$@"
}
guarded_action(){ printf 'action\n' >>"$action_calls"; }

load_cfg
fleet_inventory_refresh
expected_config="$CURRENT_CONFIG"
expected_inventory="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
: >"$load_calls"; : >"$inventory_calls"; : >"$lock_calls"; : >"$action_calls"

run_guard(){
  local out="$root/out" errfile="$root/err"
  : >"$out"; : >"$errfile"
  set +e
  "$@" >"$out" 2>"$errfile"
  GUARD_RC=$?
  set -e
  GUARD_STDOUT="$(<"$out")"
}
assert_error(){
  local code="$1" expected_config_revision="$2" expected_inventory_revision="$3"
  printf '%s' "$GUARD_STDOUT" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $revisions=$j["observed"]??[];
    exit(is_array($j)&&($j["ok"]??null)===false&&($j["code"]??"")===$argv[1]&&
      ($j["request_id"]??"")===$argv[2]&&
      ($revisions["config_revision"]??"")===$argv[3]&&
      ($revisions["inventory_revision"]??"")===$argv[4]?0:1);
  ' "$code" "$request_id" "$expected_config_revision" "$expected_inventory_revision" ||
    crf_fail "bad revision guard error $code"
}

with_fleet_lock wait runner_api_guarded_fleet_action "$expected_config" "$expected_inventory" "$request_id" guarded_action
crf_assert_eq 1 "$(wc -l <"$lock_calls")" 'valid strict action did not acquire exactly one fleet lock'
crf_assert_eq 1 "$(wc -l <"$load_calls")" 'valid strict action did not reload config once'
crf_assert_eq 1 "$(wc -l <"$inventory_calls")" 'valid strict action did not refresh inventory once'
crf_assert_eq 1 "$(wc -l <"$action_calls")" 'valid strict action did not execute exactly once'

: >"$load_calls"; : >"$inventory_calls"; : >"$lock_calls"; : >"$action_calls"
printf '%s\n' "$config_two" >"$root/config.source"
run_guard with_fleet_lock wait runner_api_guarded_fleet_action "$expected_config" "$expected_inventory" "$request_id" guarded_action
crf_assert_eq 3 "$GUARD_RC" 'stale config fleet guard exit code'
current_inventory="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
assert_error stale_config "$config_two" "$current_inventory"
crf_assert_eq 1 "$(wc -l <"$lock_calls")" 'stale config path did not acquire one lock'
crf_assert_eq 1 "$(wc -l <"$load_calls")" 'stale config path did not reload config'
crf_assert_eq 1 "$(wc -l <"$inventory_calls")" 'stale config path did not refresh inventory'
crf_assert_eq 0 "$(wc -l <"$action_calls")" 'stale config path executed side effect'

printf '%s\n' "$config_one" >"$root/config.source"
printf '%s\n' 'runner-two|running' >"$root/inventory.source"
: >"$load_calls"; : >"$inventory_calls"; : >"$lock_calls"; : >"$action_calls"
run_guard with_fleet_lock wait runner_api_guarded_fleet_action "$expected_config" "$expected_inventory" "$request_id" guarded_action
crf_assert_eq 3 "$GUARD_RC" 'stale inventory guard exit code'
current_inventory="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
assert_error stale_inventory "$config_one" "$current_inventory"
crf_assert_eq 1 "$(wc -l <"$lock_calls")" 'stale inventory path did not acquire one lock'
crf_assert_eq 1 "$(wc -l <"$load_calls")" 'stale inventory path did not reload config'
crf_assert_eq 1 "$(wc -l <"$inventory_calls")" 'stale inventory path did not refresh inventory'
crf_assert_eq 0 "$(wc -l <"$action_calls")" 'stale inventory path executed side effect'

printf '%s\n' 'runner-one|running' >"$root/inventory.source"
: >"$load_calls"; : >"$inventory_calls"; : >"$action_calls"
run_guard runner_api_guarded_config_action "$expected_config" "$request_id" guarded_action
crf_assert_eq 0 "$GUARD_RC" 'valid config-only guard exit code'
crf_assert_eq 1 "$(wc -l <"$load_calls")" 'config-only guard did not reload config'
crf_assert_eq 0 "$(wc -l <"$inventory_calls")" 'config-only guard refreshed inventory'
crf_assert_eq 1 "$(wc -l <"$action_calls")" 'config-only guard did not execute action'

printf '%s\n' "$config_two" >"$root/config.source"
: >"$load_calls"; : >"$inventory_calls"; : >"$action_calls"
run_guard runner_api_guarded_config_action "$expected_config" "$request_id" guarded_action
crf_assert_eq 3 "$GUARD_RC" 'stale config-only guard exit code'
assert_error stale_config "$config_two" "$current_inventory"
crf_assert_eq 1 "$(wc -l <"$load_calls")" 'stale config-only guard did not reload config'
crf_assert_eq 0 "$(wc -l <"$inventory_calls")" 'stale config-only guard refreshed inventory'
crf_assert_eq 0 "$(wc -l <"$action_calls")" 'stale config-only guard executed side effect'

printf '%s\n' "$config_one" >"$root/config.source"
: >"$load_calls"; : >"$inventory_calls"; : >"$lock_calls"; : >"$action_calls"
export CRF_TEST_INVENTORY_FAIL=1
run_guard with_fleet_lock wait runner_api_guarded_fleet_action "$expected_config" "$expected_inventory" "$request_id" guarded_action
unset CRF_TEST_INVENTORY_FAIL
crf_assert_eq 5 "$GUARD_RC" 'unavailable inventory guard exit code'
printf '%s' "$GUARD_STDOUT" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["code"]??"")==="backend_unavailable"?0:1);' ||
  crf_fail 'unavailable inventory code'
crf_assert_eq 0 "$(wc -l <"$action_calls")" 'unavailable inventory executed side effect'

set +e
run_guard runner_api_guarded_config_action bad "$request_id" guarded_action
set -e
crf_assert_eq 2 "$GUARD_RC" 'invalid revision guard exit code'

for fn in cmd_start cmd_stop cmd_restart; do
  block="$(sed -n "/^${fn}()/,/^}/p" "$engine")"
  case "$block" in *with_fleet_lock*) crf_fail "$fn acquired the fleet lock internally" ;; esac
done
grep -Fq 'start)        with_fleet_lock wait cmd_start' "$engine" || crf_fail 'legacy start lost dispatch-owned lock'
grep -Fq 'stop)         cmd_stop_fenced' "$engine" || crf_fail 'legacy stop lost reconcile fencing'
grep -Fq 'restart)      cmd_restart_fenced' "$engine" || crf_fail 'legacy restart lost reconcile fencing'
grep -Fq 'caller must be the sole fleet-lock owner' "$SCRIPT_DIR/runner-api.sh" ||
  crf_fail 'strict fleet lock ownership contract is missing'

echo 'revision-guards: OK'
