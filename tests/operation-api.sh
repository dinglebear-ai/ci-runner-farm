#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-operation-api.XXXXXX)"
trap 'rm -rf "$root"' EXIT
CFGDIR="$root/config"
RUNDIR="$root/run"
OPERATION_DIR="$CFGDIR/operations"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$CFGDIR" "$RUNDIR"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operations.sh"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-status.sh"

sha="$(printf config | sha256sum | cut -d' ' -f1)"
config_revision(){ printf '%s\n' "$sha"; }
migration_load(){ return 1; }
scaleset_ownership_revision(){ printf 'b%.0s' {1..64}; }
scaleset_record_reason(){ printf '%s\n' compatibility_record_missing; }
json_escape(){ php -r '$v=stream_get_contents(STDIN);$j=json_encode($v);echo substr($j,1,-1);'; }
GH_OWNER=owner
AUTH_MODE=pat
POOL_BACKEND=classic
GITHUB_APP_INSTALLATION_ID=
RUNNER_GROUP=
GITHUB_APP_KEY_FILE="$root/no-key"
SCALESET_COMPAT="$root/no-compat"
SCALESET_STATE_DIR="$root/legacy-scalesets"
mkdir -p "$SCALESET_STATE_DIR/operations"
printf '%s\n' '{"schema_version":1,"operation_id":"ffffffff-ffff-ffff-ffff-ffffffffffff","state":"passed"}' >"$SCALESET_STATE_DIR/operations/legacy.json"
cat >"$root/fake-helper" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] && printf '%s\n' '{}'
EOF
chmod 0755 "$root/fake-helper"
SCALESET_HELPER="$root/fake-helper"

run_id='40000001-0000-0000-0000-000000000001'
CRF_OPERATION_ID="$run_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
operation_mark_running "$run_id" 'Running.'
touch -d '@2000' "$OPERATION_DIR/$run_id.json"
status_backend_refresh
printf '%s' "$STATUS_OPERATION_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["operation_id"]??"")===$argv[1]&&($j["state"]??"")==="running"?0:1);' "$run_id" || crf_fail 'running durable operation missing from status'
case "$STATUS_OPERATION_JSON" in *ffffffff*) crf_fail 'legacy tmpfs operation leaked into status' ;; esac

operation_finish "$run_id" succeeded compatible 'Passed.' >/dev/null
touch -d '@3000' "$OPERATION_DIR/$run_id.json"
status_backend_refresh
printf '%s' "$STATUS_OPERATION_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["operation_id"]??"")===$argv[1]&&($j["state"]??"")==="succeeded"&&is_string($j["finished_at"]??null)?0:1);' "$run_id" || crf_fail 'terminal durable operation missing from status'

interrupted_id='40000002-0000-0000-0000-000000000002'
CRF_OPERATION_ID="$interrupted_id" operation_create image_build "$sha" image_build_log >/dev/null
operation_reconcile_interrupted
touch -d '@4000' "$OPERATION_DIR/$interrupted_id.json"
status_backend_refresh
printf '%s' "$STATUS_OPERATION_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["operation_id"]??"")===$argv[1]&&($j["state"]??"")==="failed"&&($j["code"]??"")==="operation_interrupted"?0:1);' "$interrupted_id" || crf_fail 'interrupted durable operation missing from status'

empty_dir="$root/empty-operations"
OPERATION_DIR="$empty_dir"
status_backend_refresh
crf_assert_eq null "$STATUS_OPERATION_JSON" 'empty durable journal did not produce null status operation'
OPERATION_DIR="$CFGDIR/operations"

readiness_file="$root/readiness.json"
operation_json="$(operation_read_public "$interrupted_id")"
php -r '$op=json_decode($argv[1],true);echo json_encode(["schema_version"=>2,"backend"=>["requested"=>"classic","effective"=>"classic"],"compatibility"=>["valid"=>false,"reason"=>"not_checked"],"operation"=>$op,"count"=>0],JSON_UNESCAPED_SLASHES),"\n";' "$operation_json" >"$readiness_file"
chmod 0600 "$readiness_file"
php "$SCRIPT_DIR/api-status.php" readiness "$readiness_file" >/dev/null || crf_fail 'valid durable readiness operation was rejected'
php -r '$j=json_decode(file_get_contents($argv[1]),true);$j["operation"]["state"]="passed";file_put_contents($argv[1],json_encode($j)."\n");' "$readiness_file"
if php "$SCRIPT_DIR/api-status.php" readiness "$readiness_file" >/dev/null 2>&1; then crf_fail 'invalid durable operation state was accepted'; fi
php -r '$j=json_decode(file_get_contents($argv[1]),true);$j["operation"]["state"]="failed";$j["operation"]["unexpected"]=true;file_put_contents($argv[1],json_encode($j)."\n");' "$readiness_file"
if php "$SCRIPT_DIR/api-status.php" readiness "$readiness_file" >/dev/null 2>&1; then crf_fail 'operation with unknown field was accepted'; fi

# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-api.sh"
migration_load(){ return 1; }
API_RC=0
API_STDOUT=
request_json(){
  php -r '$id=$argv[1];$op=$argv[2];echo json_encode(["schema_version"=>1,"request_id"=>$id,"operation"=>"operation-read","expected"=>(object)[],"input"=>["operation_id"=>$op]],JSON_UNESCAPED_SLASHES);' "$1" "$2"
}
run_api(){
  local req="$1" out="$root/api.out" err="$root/api.err"
  : >"$out"; : >"$err"
  set +e
  printf '%s' "$req" | ( runner_api_dispatch operation-read ) >"$out" 2>"$err"
  API_RC=$?
  set -e
  API_STDOUT="$(<"$out")"
}
assert_envelope(){
  local ok="$1" code="$2" request="$3"
  printf '%s' "$API_STDOUT" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["ok"]??null)===($argv[1]==="true")&&($j["code"]??"")===$argv[2]&&($j["request_id"]??"")===$argv[3]?0:1);' "$ok" "$code" "$request" || crf_fail "bad operation envelope $code"
}

request_id='4aa00001-0000-4000-8000-000000000001'
run_api "$(request_json "$request_id" "$interrupted_id")"
crf_assert_eq 0 "$API_RC" 'operation read exit code'
assert_envelope true ok "$request_id"
printf '%s' "$API_STDOUT" | php -r '$j=json_decode(stream_get_contents(STDIN),true);$r=$j["result"]??[];exit(($r["operation_id"]??"")===$argv[1]&&($r["code"]??"")==="operation_interrupted"&&!array_key_exists("worker",$r)&&!array_key_exists("output_source",$r)?0:1);' "$interrupted_id" || crf_fail 'operation read leaked private fields or wrong result'

missing_id='40000009-0000-0000-0000-000000000009'
run_api "$(request_json "$request_id" "$missing_id")"
crf_assert_eq 4 "$API_RC" 'missing operation read exit code'
assert_envelope false operation_not_found "$request_id"

unsafe_id='40000008-0000-0000-0000-000000000008'
ln -s "$OPERATION_DIR/$interrupted_id.json" "$OPERATION_DIR/$unsafe_id.json"
run_api "$(request_json "$request_id" "$unsafe_id")"
crf_assert_eq 5 "$API_RC" 'unsafe operation read exit code'
assert_envelope false backend_unavailable "$request_id"
rm -f "$OPERATION_DIR/$unsafe_id.json"

run_api "$(request_json "$request_id" bad-id)"
crf_assert_eq 2 "$API_RC" 'invalid operation ID exit code'
assert_envelope false invalid_request ''

for dir in "$RUNDIR/api-requests" "$RUNDIR/api-results"; do
  [ ! -d "$dir" ] || [ -z "$(find "$dir" -maxdepth 1 -type f -print -quit)" ] || crf_fail "operation API left temporary files in $dir"
done

echo 'operation-api: OK'
