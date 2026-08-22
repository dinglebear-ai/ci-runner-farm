#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

API_MODULE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-api.sh
ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d /tmp/crf-graphql-aux.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1090
. "$API_MODULE"

config_revision(){ printf 'a%.0s' {1..64}; }
migration_load(){ return 1; }

assert_envelope() {
  local output="$1" expected_ok="$2" expected_code="$3"
  printf '%s' "$output" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $ok=is_array($j)&&($j["ok"]??null)===($argv[1]==="true")&&($j["code"]??"")===$argv[2];
    exit($ok?0:1);
  ' "$expected_ok" "$expected_code" || crf_fail "unexpected auxiliary envelope: $expected_code"
}

cmd_queued_json(){
  printf '%s\n' '{"queued":1,"known_queued":1,"workflow_runs":1,"partial":false,"truncated":false,"detail_complete":true,"jobs":[{"run_id":"9007199254740993","job_id":"9007199254740995","repo":"owner/repo","workflow":"#42 · Build","labels":"self-hosted, rust, linux","pool":"rust","reason":"waiting for runner","created_at":"2026-08-05T18:00:00Z","url":"https://github.example/jobs/1"}],"age":12}'
}
cmd_stats_json(){ printf '%s\n' '{"ok":7,"fail":2,"cancel":1,"other":0,"total":10,"age":15}'; }
cmd_cache_usage_json(){ printf '%s\n' '{"total":9007199254740993,"pkg":536870912,"age":9}'; }
cmd_image_info_json(){
  printf '%s\n' "{\"exists\":true,\"image\":\"ci-runner-farm-runner:latest\",\"source\":\"builtin\",\"id\":\"0123456789ab\",\"image_id\":\"sha256:$(printf 'a%.0s' {1..64})\",\"created\":\"2026-08-05T17:00:00Z\",\"size_mb\":3072,\"size_bytes\":3221225472,\"base\":\"ubuntu:24.04\",\"in_use\":3,\"dockerfile\":\"/boot/config/plugins/ci-runner-farm/Dockerfile\"}"
}

queue_output="$(runner_api_auxiliary queue 2>"$tmp/queue.stderr")"
assert_envelope "$queue_output" true ok
printf '%s' "$queue_output" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);
  $ok=($j["result"]["jobs"][0]["run_id"]??"")==="9007199254740993"&&
      ($j["result"]["jobs"][0]["job_id"]??"")==="9007199254740995";
  exit($ok?0:1);
' || crf_fail 'queue IDs were not preserved by the wrapper'

stats_output="$(runner_api_auxiliary statistics 2>"$tmp/stats.stderr")"
assert_envelope "$stats_output" true ok
printf '%s' "$stats_output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["result"]["total"]??-1)===10?0:1);' ||
  crf_fail 'statistics wrapper changed total'

cache_output="$(runner_api_auxiliary cache 2>"$tmp/cache.stderr")"
assert_envelope "$cache_output" true ok
printf '%s' "$cache_output" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);
  exit(($j["result"]["total"]??"")==="9007199254740993"&&($j["result"]["pkg"]??"")==="536870912"?0:1);
' || crf_fail 'cache wrapper lost exact bytes'

image_output="$(runner_api_auxiliary image 2>"$tmp/image.stderr")"
assert_envelope "$image_output" true ok
printf '%s' "$image_output" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);
  $ok=($j["result"]["image_id"]??"")==="sha256:".str_repeat("a",64)&&
      ($j["result"]["size_bytes"]??"")==="3221225472"&&
      !array_key_exists("size_mb",$j["result"]);
  exit($ok?0:1);
' || crf_fail 'image wrapper lost exact identity or bytes'

cmd_stats_json(){ return 1; }
set +e
failed_output="$(runner_api_auxiliary statistics 2>"$tmp/stats-failed.stderr")"
failed_rc=$?
set -e
crf_assert_eq 5 "$failed_rc" 'failed auxiliary command exit code'
assert_envelope "$failed_output" false backend_unavailable

cmd_cache_usage_json(){ printf '%s' '{bad json'; }
set +e
malformed_output="$(runner_api_auxiliary cache 2>"$tmp/cache-malformed.stderr")"
malformed_rc=$?
set -e
crf_assert_eq 5 "$malformed_rc" 'malformed auxiliary result exit code'
assert_envelope "$malformed_output" false backend_unavailable

shopt -s nullglob
remaining=("$RUNDIR/api-results"/*)
[ "${#remaining[@]}" -eq 0 ] || crf_fail 'auxiliary result files were not cleaned'

# The queue refresh source must never cast GitHub IDs through a PHP integer.
! grep -Fq '"run_id"=>(int)$runId' "$ENGINE" || crf_fail 'queue run ID cast reintroduced'
! grep -Fq '"job_id"=>(int)' "$ENGINE" || crf_fail 'queue job ID cast reintroduced'
grep -Fq '"run_id"=>$runId' "$ENGINE" || crf_fail 'queue run ID string preservation missing'
grep -Fq '"job_id"=>$jobId' "$ENGINE" || crf_fail 'queue job ID string preservation missing'

# Exercise the real image serializer with a fake Docker function.
image_snippet="$tmp/image-functions.sh"
for fn in json_escape cmd_image_info_json; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >>"$image_snippet"
done
(
  # shellcheck disable=SC1090
  . "$image_snippet"
  CFGDIR="$tmp/config"
  PLUGIN=ci-runner-farm
  IMAGE_SOURCE=builtin
  mkdir -p "$CFGDIR"
  printf '%s\n' 'FROM ubuntu:24.04' >"$CFGDIR/Dockerfile"
  effective_image(){ printf '%s\n' 'ci-runner-farm-runner:latest'; }
  managed_names(){ printf '%s\n' 'ci-runner-rust-1'; }
  docker(){
    if [ "$1 $2 $3" = 'image inspect -f' ]; then
      case "$4" in
        '{{.Id}}') printf 'sha256:%064d\n' 1 ;;
        '{{.Created}}') printf '%s\n' '2026-08-05T17:00:00Z' ;;
        '{{.Size}}') printf '%s\n' '3221225472' ;;
        *) return 1 ;;
      esac
    elif [ "$1 $2 $3" = 'inspect -f {{.Image}}' ]; then
      printf 'sha256:%064d\n' 1
    else
      return 1
    fi
  }
  real_image="$(cmd_image_info_json)"
  printf '%s' "$real_image" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    $id="sha256:".str_repeat("0",63)."1";
    exit(($j["image_id"]??"")===$id&&($j["size_bytes"]??0)===3221225472?0:1);
  ' || crf_fail 'real image serializer omitted exact fields'
)

printf 'graphql-auxiliary-api: OK\n'
