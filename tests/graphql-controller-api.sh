#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d /tmp/crf-graphql-api.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root"

API_RC=0
API_STDOUT=''
API_STDERR=''

run_api() {
  local verb="${1:-}" out="$tmp/stdout" err="$tmp/stderr"
  : >"$out"
  : >"$err"
  set +e
  CRF_TEST_MODE=1 CRF_TEST_ROOT="$tmp/root" bash "$ENGINE" api "$verb" >"$out" 2>"$err"
  API_RC=$?
  set -e
  API_STDOUT="$(<"$out")"
  API_STDERR="$(<"$err")"
}

assert_single_json_object_or_empty() {
  local value="$1"
  [ -z "$value" ] && return 0
  [ "$(printf '%s\n' "$value" | wc -l)" -eq 1 ] ||
    crf_fail 'strict API stdout contained more than one line'
  printf '%s' "$value" | php -r '
    $value=json_decode(stream_get_contents(STDIN),true);
    exit(is_array($value)&&json_last_error()===JSON_ERROR_NONE?0:1);
  ' || crf_fail 'strict API stdout was not one JSON object'
}

run_api unsupported-operation
[ "$API_RC" -ne 0 ] || crf_fail 'unknown API operation unexpectedly succeeded'
assert_single_json_object_or_empty "$API_STDOUT"

crf_assert_eq '2' "$API_RC" 'unknown API operation exit code'
printf '%s' "$API_STDOUT" | php -r '
  $value=json_decode(stream_get_contents(STDIN),true);
  $ok=is_array($value)&&($value["schema_version"]??0)===1&&
      ($value["ok"]??true)===false&&($value["code"]??"")==="invalid_request";
  exit($ok?0:1);
' || crf_fail 'unknown API operation did not return the controlled error envelope'

API_MODULE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-api.sh
exact_input="$tmp/exact-request"
overflow_input="$tmp/overflow-request"
php -r 'fwrite(STDOUT,str_repeat("a",(int)$argv[1]));' 1048576 >"$exact_input"
php -r 'fwrite(STDOUT,str_repeat("b",(int)$argv[1]));' 1048577 >"$overflow_input"

(
  RUNDIR="$tmp/capture-run"
  mkdir -p "$RUNDIR"
  # shellcheck disable=SC1090
  . "$API_MODULE"
  runner_api_capture_request <"$exact_input"
  crf_assert_eq "$RUNNER_API_MAX_REQUEST_BYTES" "$(stat -c %s "$RUNNER_API_REQUEST_FILE")" 'exact request size'
  crf_assert_file_mode "$RUNNER_API_REQUEST_FILE" 600
  crf_assert_file_mode "$RUNDIR/api-requests" 700
  runner_api_cleanup_request
  shopt -s nullglob
  remaining=("$RUNDIR/api-requests"/request.*)
  [ "${#remaining[@]}" -eq 0 ] || crf_fail 'request file remained after cleanup'
)

(
  RUNDIR="$tmp/overflow-run"
  mkdir -p "$RUNDIR"
  # shellcheck disable=SC1090
  . "$API_MODULE"
  set +e
  runner_api_capture_request <"$overflow_input"
  rc=$?
  set -e
  crf_assert_eq 2 "$rc" 'overflow request exit code'
  [ -z "$RUNNER_API_REQUEST_FILE" ] || crf_fail 'overflow request path was retained'
  shopt -s nullglob
  remaining=("$RUNDIR/api-requests"/request.*)
  [ "${#remaining[@]}" -eq 0 ] || crf_fail 'overflow request file was not cleaned'
)

valid_scale="$tmp/valid-scale.json"
malicious_scale="$tmp/malicious-scale.json"
marker="$tmp/metacharacter-executed"
php -r '
  $request=[
    "schema_version"=>1,
    "request_id"=>"7bb90867-3378-4ae3-81bb-74ce20fd3274",
    "operation"=>"scale",
    "expected"=>["config_revision"=>str_repeat("a",64),"inventory_revision"=>str_repeat("b",64)],
    "input"=>["pool_id"=>"rust","target"=>3],
  ];
  echo json_encode($request,JSON_UNESCAPED_SLASHES);
' >"$valid_scale"
chmod 0600 "$valid_scale"

(
  # shellcheck disable=SC1090
  . "$API_MODULE"
  RUNNER_API_REQUEST_FILE="$valid_scale"
  runner_api_parse_fields scale
  crf_assert_eq 5 "${#RUNNER_API_FIELDS[@]}" 'decoded field count'
  crf_assert_eq '7bb90867-3378-4ae3-81bb-74ce20fd3274' "${RUNNER_API_FIELDS[0]}" 'decoded request id'
  crf_assert_eq "$(printf 'a%.0s' {1..64})" "${RUNNER_API_FIELDS[1]}" 'decoded config revision'
  crf_assert_eq "$(printf 'b%.0s' {1..64})" "${RUNNER_API_FIELDS[2]}" 'decoded inventory revision'
  crf_assert_eq rust "${RUNNER_API_FIELDS[3]}" 'decoded pool'
  crf_assert_eq 3 "${RUNNER_API_FIELDS[4]}" 'decoded target'
)

php -r '
  $request=[
    "schema_version"=>1,
    "request_id"=>"7bb90867-3378-4ae3-81bb-74ce20fd3274",
    "operation"=>"scale",
    "expected"=>["config_revision"=>str_repeat("a",64),"inventory_revision"=>str_repeat("b",64)],
    "input"=>["pool_id"=>"rust;touch ".$argv[1],"target"=>3],
  ];
  echo json_encode($request,JSON_UNESCAPED_SLASHES);
' "$marker" >"$malicious_scale"
chmod 0600 "$malicious_scale"

(
  # shellcheck disable=SC1090
  . "$API_MODULE"
  RUNNER_API_REQUEST_FILE="$malicious_scale"
  set +e
  runner_api_parse_fields scale >/dev/null 2>&1
  rc=$?
  set -e
  crf_assert_eq 2 "$rc" 'metacharacter request exit code'
  [ ! -e "$marker" ] || crf_fail 'shell metacharacters were executed'
)

response_result="$tmp/response-result.json"
printf '%s\n' '{"value":"ok","count":3}' >"$response_result"
chmod 0600 "$response_result"

(
  # shellcheck disable=SC1090
  . "$API_MODULE"
  RUNDIR="$tmp/response-run"
  mkdir -p "$RUNDIR"
  INVENTORY_FILE="$tmp/response-inventory.tsv"
  printf '%s\n' 'runner-a|running' >"$INVENTORY_FILE"
  chmod 0600 "$INVENTORY_FILE"
  config_revision(){ printf 'a%.0s' {1..64}; }
  migration_load(){
    MIGRATION_REVISION="$(printf 'b%.0s' {1..64})"
    MIGRATION_OWNERSHIP_REVISION="$(printf 'c%.0s' {1..64})"
    MIGRATION_COMPATIBILITY_RECORD_ID="$(printf 'd%.0s' {1..64})"
    return 0
  }
  request_id='7bb90867-3378-4ae3-81bb-74ce20fd3274'
  emit_err="$tmp/emit.stderr"
  output="$(runner_api_emit "$request_id" true ok 'test response' "$response_result" 2>"$emit_err")"
  [ ! -s "$emit_err" ] || crf_fail 'valid response wrote diagnostics to stderr'
  assert_single_json_object_or_empty "$output"
  inventory_revision="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
  printf '%s' "$output" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $ok=is_array($j)&&($j["request_id"]??"")===$argv[1]&&($j["ok"]??false)===true&&
      ($j["code"]??"")==="ok"&&($j["result"]["value"]??"")==="ok"&&
      ($j["observed"]["config_revision"]??"")===str_repeat("a",64)&&
      ($j["observed"]["inventory_revision"]??"")===$argv[2]&&
      ($j["observed"]["transition_revision"]??"")===str_repeat("b",64)&&
      ($j["observed"]["ownership_revision"]??"")===str_repeat("c",64)&&
      ($j["observed"]["compatibility_record_id"]??"")===str_repeat("d",64)&&
      array_key_exists("credential_revision",$j["observed"])&&$j["observed"]["credential_revision"]===null;
    exit($ok?0:1);
  ' "$request_id" "$inventory_revision" || crf_fail 'valid file response envelope was incorrect'

  stream_output="$(printf '%s' '{"stream":true}' | runner_api_emit "$request_id" true ok 'stream response' -)"
  printf '%s' "$stream_output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["result"]["stream"]??false)===true?0:1);' ||
    crf_fail 'stdin response source was not preserved'

  bad_result="$tmp/bad-result.json"
  printf '%s' '{bad json' >"$bad_result"
  chmod 0600 "$bad_result"
  set +e
  bad_output="$(runner_api_emit "$request_id" true ok 'bad response' "$bad_result" 2>"$tmp/bad-result.stderr")"
  bad_rc=$?
  set -e
  crf_assert_eq 5 "$bad_rc" 'malformed result exit code'
  [ -s "$tmp/bad-result.stderr" ] || crf_fail 'malformed result did not emit bounded diagnostics'
  assert_single_json_object_or_empty "$bad_output"
  printf '%s' "$bad_output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["ok"]??true)===false&&($j["code"]??"")==="backend_unavailable"&&array_key_exists("result",$j)&&$j["result"]===null?0:1);' ||
    crf_fail 'malformed result did not fall back to backend_unavailable'

  error_specs=(
    'runner_api_fail_invalid_request invalid_request 2'
    'runner_api_fail_invalid_revision invalid_revision 2'
    'runner_api_fail_stale_config stale_config 3'
    'runner_api_fail_stale_inventory stale_inventory 3'
    'runner_api_fail_stale_transition stale_transition 3'
    'runner_api_fail_ownership_changed ownership_changed 3'
    'runner_api_fail_compatibility_changed compatibility_changed 3'
    'runner_api_fail_backend_unavailable backend_unavailable 5'
    'runner_api_fail_output_too_large output_too_large 5'
  )
  for spec in "${error_specs[@]}"; do
    read -r helper expected_code expected_rc <<<"$spec"
    set +e
    error_output="$("$helper" 'test failure' "$request_id" 2>"$tmp/error-helper.stderr")"
    actual_rc=$?
    set -e
    crf_assert_eq "$expected_rc" "$actual_rc" "$helper exit code"
    printf '%s' "$error_output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["ok"]??true)===false&&($j["code"]??"")===$argv[1]&&($j["request_id"]??"")===$argv[2]?0:1);' "$expected_code" "$request_id" ||
      crf_fail "$helper envelope was incorrect"
  done
)

printf 'graphql-controller-api: OK\n'
