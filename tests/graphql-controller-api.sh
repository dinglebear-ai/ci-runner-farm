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

printf 'graphql-controller-api: OK\n'
