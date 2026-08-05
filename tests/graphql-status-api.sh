#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

API_MODULE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-api.sh
tmp="$(mktemp -d /tmp/crf-graphql-status.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1090
. "$API_MODULE"

assert_envelope() {
  local output="$1" expected_ok="$2" expected_code="$3"
  printf '%s' "$output" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $ok=is_array($j)&&($j["ok"]??null)===($argv[1]==="true")&&($j["code"]??"")===$argv[2];
    exit($ok?0:1);
  ' "$expected_ok" "$expected_code" || crf_fail "unexpected envelope: $expected_code"
}

config_revision(){ printf 'a%.0s' {1..64}; }
migration_load(){
  MIGRATION_REVISION="$(printf 'b%.0s' {1..64})"
  MIGRATION_OWNERSHIP_REVISION="$(printf 'c%.0s' {1..64})"
  MIGRATION_COMPATIBILITY_RECORD_ID="$(printf 'd%.0s' {1..64})"
  return 0
}

INVENTORY_FILE="$tmp/inventory.tsv"
printf '%s\n' 'ci-runner-rust-1|running|healthy|1500000000|3221225472|gen|rust|org:owner|1|rust|valid|classic|2026-08-05T17:00:00Z' >"$INVENTORY_FILE"
chmod 0600 "$INVENTORY_FILE"
inventory_revision="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"

RAW_STATUS="$tmp/status.json"
php -r '
  $inventory=$argv[1];
  $j=[
    "schema_version"=>2,"config_revision"=>str_repeat("a",64),"observed_at"=>1785950000,
    "inventory_revision"=>$inventory,
    "backend"=>["requested"=>"scaleset","effective"=>"invalid","transition_phase"=>"invalid","transition_id"=>"","transition_revision"=>str_repeat("b",64),"ownership_revision"=>str_repeat("c",64)],
    "compatibility"=>["valid"=>true,"reason"=>"valid","record_id"=>str_repeat("d",64),"runner_group_id"=>"9007199254740993"],
    "operation"=>null,"maintenance"=>false,
    "resources"=>["available"=>true,"reason"=>null,"cpu_milli"=>["budget"=>8000,"reserve"=>1000,"reserved"=>1500,"admissible"=>6500],"memory_bytes"=>["budget"=>17179869184,"reserve"=>1073741824,"reserved"=>3221225472,"admissible"=>13958643712]],
    "reservations"=>[],
    "recent_activity"=>[["schema_version"=>1,"observed_at"=>1785950000,"completed_at"=>"2026-08-05T18:00:00Z","runner_name"=>"ci-runner-rust-1","pool_id"=>"rust","work_handle"=>"9007199254740993","job"=>"build","conclusion"=>"success"]],
    "mode"=>"invalid","config_error"=>"","count"=>1,"configured"=>1,"token"=>true,
    "autoscale_enabled"=>true,"autoscale_max"=>64,"autoscale"=>"running","image_autoupdate"=>"off",
    "warning"=>"","security"=>"","stale"=>0,"retiring"=>0,"blocked_capacity"=>0,
    "pools"=>[["id"=>"rust","label"=>"rust","autoscale_enabled"=>true,"configured"=>1,"effective_target"=>1,"count"=>1,"up"=>1,"busy"=>1,"idle"=>0,"starting"=>0,"error"=>0,"completed"=>0,"stale"=>0,"retiring"=>0,"pending"=>0,"min"=>1,"max"=>"auto","idle_buffer"=>1,"remote_scale_set_id"=>"9007199254740993"]],
    "runners"=>[["name"=>"ci-runner-rust-1","pool"=>"rust","routing_label"=>"rust","scope_target"=>"org:owner","pool_index"=>1,"state"=>"running","phase"=>"busy","job"=>"build","job_started"=>"2026-08-05T18:00:00Z","started_at"=>"2026-08-05T17:00:00Z","repo"=>"owner/repo","pr"=>"1","branch"=>"main","run_id"=>"9007199254740993","cpus"=>1,"mem_gb"=>3,"cpu_pct"=>42.5,"mem_used_mib"=>512,"completed"=>false,"stale"=>false,"retiring"=>false]],
  ];
  echo json_encode($j,JSON_UNESCAPED_SLASHES);
' "$inventory_revision" >"$RAW_STATUS"
chmod 0600 "$RAW_STATUS"

cmd_status_json(){ cat "$RAW_STATUS"; }
status_output="$(runner_api_status 2>"$tmp/status.stderr")"
assert_envelope "$status_output" true ok
printf '%s' "$status_output" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);
  $ok=($j["result"]["runners"][0]["cpu_milli"]??null)===1500&&
    ($j["result"]["runners"][0]["memory_bytes"]??null)===3221225472&&
    ($j["result"]["runners"][0]["run_id"]??"")==="9007199254740993"&&
    ($j["result"]["resources"]["available"]??false)===true;
  exit($ok?0:1);
' || crf_fail 'strict status wrapper lost exact fields'
[ ! -s "$tmp/status.stderr" ] || crf_fail 'valid status wrote diagnostics'
shopt -s nullglob
remaining=("$RUNDIR/api-results"/*)
[ "${#remaining[@]}" -eq 0 ] || crf_fail 'status result files were not cleaned'

php -r '$j=json_decode(file_get_contents($argv[1]),true);$j["schema_version"]=3;file_put_contents($argv[2],json_encode($j));' "$RAW_STATUS" "$tmp/status-v3.json"
chmod 0600 "$tmp/status-v3.json"
RAW_STATUS="$tmp/status-v3.json"
set +e
schema_output="$(runner_api_status 2>"$tmp/status-v3.stderr")"
schema_rc=$?
set -e
crf_assert_eq 2 "$schema_rc" 'unsupported status schema exit code'
assert_envelope "$schema_output" false unsupported_schema

cmd_status_json(){ return 1; }
set +e
unavailable_output="$(runner_api_status 2>"$tmp/status-unavailable.stderr")"
unavailable_rc=$?
set -e
crf_assert_eq 5 "$unavailable_rc" 'inventory unavailable status exit code'
assert_envelope "$unavailable_output" false backend_unavailable

RAW_READINESS="$tmp/readiness.json"
printf '%s\n' '{"schema_version":2,"backend":{"requested":"classic","effective":"classic"},"compatibility":{"valid":false,"reason":"not_checked"},"operation":null,"count":2}' >"$RAW_READINESS"
chmod 0600 "$RAW_READINESS"
cmd_readiness_json(){ cat "$RAW_READINESS"; }
readiness_output="$(runner_api_readiness 2>"$tmp/readiness.stderr")"
assert_envelope "$readiness_output" true ok
printf '%s' "$readiness_output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["result"]["count"]??-1)===2?0:1);' ||
  crf_fail 'readiness count was not preserved'

printf '%s\n' '{"schema_version":2,"backend":{"requested":"classic","effective":"classic"},"compatibility":{"valid":false,"reason":"not_checked"},"operation":null,"count":null}' >"$RAW_READINESS"
readiness_output="$(runner_api_readiness 2>"$tmp/readiness-null.stderr")"
printf '%s' "$readiness_output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(array_key_exists("count",$j["result"])&&$j["result"]["count"]===null?0:1);' ||
  crf_fail 'unknown readiness count was lost'

printf '%s\n' '{"schema_version":1,"backend":{"requested":"classic","effective":"classic"},"compatibility":{"valid":false,"reason":"not_checked"},"operation":null,"count":0}' >"$RAW_READINESS"
set +e
readiness_bad="$(runner_api_readiness 2>"$tmp/readiness-v1.stderr")"
readiness_bad_rc=$?
set -e
crf_assert_eq 2 "$readiness_bad_rc" 'unsupported readiness schema exit code'
assert_envelope "$readiness_bad" false unsupported_schema

remaining=("$RUNDIR/api-results"/*)
[ "${#remaining[@]}" -eq 0 ] || crf_fail 'readiness result files were not cleaned'

printf 'graphql-status-api: OK\n'
