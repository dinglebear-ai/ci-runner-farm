#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-lifecycle-api.XXXXXX)"
trap 'rm -rf "$root"' EXIT
RUNDIR="$root/run"
INVENTORY_FILE="$RUNDIR/fleet-inventory.tsv"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-api.sh"

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
snippet="$root/functions.sh"
for fn in with_fleet_lock cmd_restart; do
  sed -n "/^${fn}()/,/^}/p" "$engine" >>"$snippet"
done
# shellcheck disable=SC1090
. "$snippet"

request_id='6aa00001-0000-4000-8000-000000000001'
config_one="$(printf config-one | sha256sum | cut -d' ' -f1)"
config_two="$(printf config-two | sha256sum | cut -d' ' -f1)"
printf '%s\n' "$config_one" >"$root/config.source"
printf '%s\n' 'runner-one|running' >"$root/inventory.source"
CURRENT_CONFIG=
load_calls="$root/load.calls"
inventory_calls="$root/inventory.calls"
lock_calls="$root/lock.calls"
start_calls="$root/start.calls"
stop_calls="$root/stop.calls"
validate_calls="$root/validate.calls"

load_cfg(){
  printf 'load\n' >>"$load_calls"
  CURRENT_CONFIG="$(cat "$root/config.source")"
}
config_revision(){ printf '%s\n' "$CURRENT_CONFIG"; }
fleet_inventory_refresh(){
  printf 'inventory\n' >>"$inventory_calls"
  local count
  count="$(wc -l <"$inventory_calls")"
  if [ -n "${FAIL_INVENTORY_ON_CALL:-}" ] && [ "$count" -eq "$FAIL_INVENTORY_ON_CALL" ]; then
    return 1
  fi
  cp "$root/inventory.source" "$INVENTORY_FILE"
  chmod 0600 "$INVENTORY_FILE"
}
migration_load(){
  [ "${MIGRATION_AVAILABLE:-0}" = 1 ] || return 1
  MIGRATION_PHASE="${TEST_MIGRATION_PHASE:-classic_active}"
  MIGRATION_EFFECTIVE_BACKEND="${TEST_EFFECTIVE_BACKEND:-classic}"
  MIGRATION_LAST_BARRIER="${TEST_LAST_BARRIER:-none}"
}
backend_classic_admission_allowed(){ [ "${CLASSIC_ALLOWED:-0}" = 1 ]; }
validate_runtime_config(){
  printf 'validate\n' >>"$validate_calls"
  [ "${VALID_CONFIG:-1}" = 1 ]
}
auth_credentials_configured(){ [ "${CREDENTIALS_READY:-1}" = 1 ]; }
err(){ printf 'ERR:%s\n' "$*" >&2; }
cmd_start(){
  printf 'start\n' >>"$start_calls"
  printf 'human start output\n'
  printf 'human start error\n' >&2
  return "${START_RC:-0}"
}
cmd_stop(){
  printf 'stop\n' >>"$stop_calls"
  printf 'scale-set ineligibility warning\n' >&2
  return "${STOP_RC:-0}"
}
flock(){
  printf 'lock\n' >>"$lock_calls"
  command flock "$@"
}

request_json(){
  php -r '
    echo json_encode([
      "schema_version"=>1,
      "request_id"=>$argv[1],
      "operation"=>$argv[2],
      "expected"=>[
        "config_revision"=>$argv[3],
        "inventory_revision"=>$argv[4],
      ],
      "input"=>(object)[],
    ],JSON_UNESCAPED_SLASHES);
  ' "$request_id" "$1" "$2" "$3"
}
API_RC=0
API_STDOUT=
run_api(){
  local operation="$1" expected_config="$2" expected_inventory="$3"
  local out="$root/api.out" err_file="$root/api.err"
  : >"$out"; : >"$err_file"
  set +e
  printf '%s' "$(request_json "$operation" "$expected_config" "$expected_inventory")" |
    ( runner_api_dispatch "$operation" ) >"$out" 2>"$err_file"
  API_RC=$?
  set -e
  API_STDOUT="$(<"$out")"
}
assert_envelope(){
  local ok="$1" code="$2"
  printf '%s' "$API_STDOUT" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    exit(is_array($j)&&($j["ok"]??null)===($argv[1]==="true")&&
      ($j["code"]??"")===$argv[2]&&($j["request_id"]??"")===$argv[3]?0:1);
  ' "$ok" "$code" "$request_id" || crf_fail "bad lifecycle envelope $code"
}
assert_no_human_output(){
  case "$API_STDOUT" in *human*|*warning*) crf_fail 'human lifecycle output contaminated stdout' ;; esac
}
count_file(){ [ -f "$1" ] && wc -l <"$1" || printf '0\n'; }
reset_case(){
  rm -f "$load_calls" "$inventory_calls" "$lock_calls" "$start_calls" "$stop_calls" "$validate_calls"
  unset FAIL_INVENTORY_ON_CALL MIGRATION_AVAILABLE TEST_MIGRATION_PHASE TEST_EFFECTIVE_BACKEND
  unset TEST_LAST_BARRIER CLASSIC_ALLOWED START_RC STOP_RC
  VALID_CONFIG=1
  CREDENTIALS_READY=1
  printf '%s\n' "$config_one" >"$root/config.source"
  printf '%s\n' 'runner-one|running' >"$root/inventory.source"
  load_cfg
  fleet_inventory_refresh
  EXPECTED_CONFIG="$CURRENT_CONFIG"
  EXPECTED_INVENTORY="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
  rm -f "$load_calls" "$inventory_calls"
}

reset_case
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 0 "$API_RC" 'strict start exit code'
assert_envelope true ok
assert_no_human_output
crf_assert_eq 1 "$(count_file "$lock_calls")" 'strict start lock count'
crf_assert_eq 1 "$(count_file "$start_calls")" 'strict start call count'
crf_assert_eq 0 "$(count_file "$stop_calls")" 'strict start called stop'
crf_assert_eq 1 "$(count_file "$load_calls")" 'strict start config reload count'
crf_assert_eq 2 "$(count_file "$inventory_calls")" 'strict start inventory refresh count'

reset_case
printf '%s\n' "$config_two" >"$root/config.source"
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 3 "$API_RC" 'stale start config exit code'
assert_envelope false stale_config
crf_assert_eq 0 "$(count_file "$start_calls")" 'stale start executed side effect'
crf_assert_eq 1 "$(count_file "$lock_calls")" 'stale start lock count'

reset_case
printf '%s\n' 'runner-two|running' >"$root/inventory.source"
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 3 "$API_RC" 'stale start inventory exit code'
assert_envelope false stale_inventory
crf_assert_eq 0 "$(count_file "$start_calls")" 'stale inventory executed side effect'

reset_case
VALID_CONFIG=0
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 4 "$API_RC" 'invalid config start exit code'
assert_envelope false invalid_config
crf_assert_eq 0 "$(count_file "$start_calls")" 'invalid config executed start'

reset_case
CREDENTIALS_READY=0
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 4 "$API_RC" 'missing credentials start exit code'
assert_envelope false backend_not_ready
crf_assert_eq 0 "$(count_file "$start_calls")" 'missing credentials executed start'

reset_case
MIGRATION_AVAILABLE=1 TEST_MIGRATION_PHASE=activating_scaleset
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 4 "$API_RC" 'transition blocked start exit code'
assert_envelope false backend_transition_in_progress
crf_assert_eq 0 "$(count_file "$start_calls")" 'transition block executed start'

reset_case
MIGRATION_AVAILABLE=1 TEST_MIGRATION_PHASE=activating_classic TEST_EFFECTIVE_BACKEND=scaleset
TEST_LAST_BARRIER=jit_drained CLASSIC_ALLOWED=1
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 0 "$API_RC" 'allowed rollback start exit code'
assert_envelope true ok

reset_case
START_RC=1
run_api start "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 4 "$API_RC" 'partial start exit code'
assert_envelope false resource_capacity
assert_no_human_output
crf_assert_eq 1 "$(count_file "$start_calls")" 'partial start call count'
crf_assert_eq 2 "$(count_file "$inventory_calls")" 'partial start final inventory refresh count'

reset_case
run_api stop "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 0 "$API_RC" 'strict stop exit code'
assert_envelope true ok
assert_no_human_output
crf_assert_eq 1 "$(count_file "$stop_calls")" 'strict stop call count'
crf_assert_eq 0 "$(count_file "$start_calls")" 'strict stop called start'

reset_case
STOP_RC=1
run_api stop "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 5 "$API_RC" 'strict stop failure exit code'
assert_envelope false backend_unavailable
crf_assert_eq 1 "$(count_file "$stop_calls")" 'failed stop call count'

reset_case
run_api restart "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 0 "$API_RC" 'strict restart exit code'
assert_envelope true ok
assert_no_human_output
crf_assert_eq 1 "$(count_file "$lock_calls")" 'strict restart lock count'
crf_assert_eq 1 "$(count_file "$stop_calls")" 'strict restart stop count'
crf_assert_eq 1 "$(count_file "$start_calls")" 'strict restart start count'

reset_case
STOP_RC=1
run_api restart "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 5 "$API_RC" 'restart stop failure exit code'
assert_envelope false backend_unavailable
crf_assert_eq 1 "$(count_file "$stop_calls")" 'restart stop failure stop count'
crf_assert_eq 0 "$(count_file "$start_calls")" 'restart stop failure reached start'

reset_case
START_RC=1
run_api restart "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 4 "$API_RC" 'restart partial start exit code'
assert_envelope false resource_capacity
crf_assert_eq 1 "$(count_file "$stop_calls")" 'restart partial stop count'
crf_assert_eq 1 "$(count_file "$start_calls")" 'restart partial start count'

reset_case
FAIL_INVENTORY_ON_CALL=2
run_api stop "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
crf_assert_eq 5 "$API_RC" 'post-stop inventory failure exit code'
assert_envelope false backend_unavailable
crf_assert_eq 1 "$(count_file "$stop_calls")" 'post-stop inventory failure lost side effect'

reset_case
run_api stop "$EXPECTED_CONFIG" "$EXPECTED_INVENTORY"
for dir in "$RUNDIR/api-requests" "$RUNDIR/api-results"; do
  [ ! -d "$dir" ] || [ -z "$(find "$dir" -maxdepth 1 -type f -print -quit)" ] ||
    crf_fail "strict lifecycle left temporary files in $dir"
done

grep -Fq 'cmd_stop || return 10' "$engine" || crf_fail 'restart does not preserve stop failure phase'
grep -Fq 'cmd_start || return 11' "$engine" || crf_fail 'restart does not preserve start failure phase'

echo 'lifecycle-api: OK'
