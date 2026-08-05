#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

API_MODULE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-api.sh
tmp="$(mktemp -d /tmp/crf-graphql-log.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1090
. "$API_MODULE"

config_revision(){ printf 'a%.0s' {1..64}; }
migration_load(){ return 1; }

LOG_RC=0
LOG_STDOUT=''
request_json() {
  local op="$1" name="${2:-}" lines="$3" id="$4"
  php -r '
    $op=$argv[1];$name=$argv[2];$lines=(int)$argv[3];$id=$argv[4];
    $input=$op==="controller-log"?["lines"=>$lines]:["runner_name"=>$name,"lines"=>$lines];
    echo json_encode(["schema_version"=>1,"request_id"=>$id,"operation"=>$op,"expected"=>(object)[],"input"=>$input],JSON_UNESCAPED_SLASHES);
  ' "$op" "$name" "$lines" "$id"
}
run_api() {
  local op="$1" req="$2" out="$tmp/out" err="$tmp/err"
  : >"$out"; : >"$err"
  set +e
  printf '%s' "$req" | ( runner_api_dispatch "$op" ) >"$out" 2>"$err"
  LOG_RC=$?
  set -e
  LOG_STDOUT="$(<"$out")"
}
assert_env() {
  local expected_ok="$1" code="$2" id="$3"
  printf '%s' "$LOG_STDOUT" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    exit(is_array($j)&&($j["ok"]??null)===($argv[1]==="true")&&
      ($j["code"]??"")===$argv[2]&&($j["request_id"]??"")===$argv[3]?0:1);
  ' "$expected_ok" "$code" "$id" || crf_fail "bad envelope $code"
}

marker="$tmp/called"
cmd_logs_tail() {
  printf '%s\n' 'old' 'github_pat_abcdefghijklmnopqrstuvwxyz' 'latest runner'
  printf runner >"$marker"
}
cmd_history_log() {
  printf '%s\n' '{"ok":true,"log":"old\nAuthorization: Bearer abcdefghijklmnopqrstuvwxyz\nlatest history"}'
  printf history >"$marker"
}
cmd_farm_log() {
  printf '%s\n' '{"ok":true,"log":"old\npassword=abcdefghijklmnopqrstuvwxyz\nlatest controller"}'
  printf controller >"$marker"
}

id=7bb90867-3378-4ae3-81bb-74ce20fd3274
run_api runner-log "$(request_json runner-log ci-runner-rust-1 2 "$id")"
crf_assert_eq 0 "$LOG_RC" 'runner log rc'
assert_env true ok "$id"
printf '%s' "$LOG_STDOUT" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);$r=$j["result"]??[];
  exit(($r["source"]??"")==="runner:ci-runner-rust-1"&&
    !str_contains($r["content"]??"","github_pat_")&&
    str_ends_with($r["content"]??"","latest runner")?0:1);
' || crf_fail 'runner result'

run_api history-log "$(request_json history-log ci-runner-jit-rust-aaaaaaaaaaaaaaaaaaaa 2 "$id")"
crf_assert_eq 0 "$LOG_RC" 'history log rc'
assert_env true ok "$id"
printf '%s' "$LOG_STDOUT" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);$r=$j["result"]??[];
  exit(($r["source"]??"")==="history:ci-runner-jit-rust-aaaaaaaaaaaaaaaaaaaa"&&
    !str_contains($r["content"]??"","abcdefghijklmnopqrstuvwxyz")&&
    str_ends_with($r["content"]??"","latest history")?0:1);
' || crf_fail 'history result'

run_api controller-log "$(request_json controller-log '' 2 "$id")"
crf_assert_eq 0 "$LOG_RC" 'controller log rc'
assert_env true ok "$id"
printf '%s' "$LOG_STDOUT" | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);$r=$j["result"]??[];
  exit(($r["source"]??"")==="controller"&&
    !str_contains($r["content"]??"","abcdefghijklmnopqrstuvwxyz")&&
    str_ends_with($r["content"]??"","latest controller")?0:1);
' || crf_fail 'controller result'

rm -f "$marker"
malicious='ci-runner-rust-1;touch-injected'
run_api runner-log "$(request_json runner-log "$malicious" 2 "$id")"
crf_assert_eq 2 "$LOG_RC" 'malicious runner rc'
assert_env false invalid_request ''
[ ! -e "$marker" ] || crf_fail 'invalid runner reached command'

run_api runner-log "$(request_json runner-log ci-runner-rust-1 501 "$id")"
crf_assert_eq 2 "$LOG_RC" 'line bound rc'
assert_env false invalid_request ''
[ ! -e "$marker" ] || crf_fail 'invalid lines reached command'

cmd_logs_tail(){ return 1; }
run_api runner-log "$(request_json runner-log ci-runner-rust-1 2 "$id")"
crf_assert_eq 4 "$LOG_RC" 'missing runner rc'
assert_env false invalid_runner "$id"

cmd_farm_log(){ return 1; }
run_api controller-log "$(request_json controller-log '' 2 "$id")"
crf_assert_eq 5 "$LOG_RC" 'missing controller rc'
assert_env false backend_unavailable "$id"

shopt -s nullglob
requests=("$RUNDIR/api-requests"/*)
results=("$RUNDIR/api-results"/*)
[ "${#requests[@]}" -eq 0 ] || crf_fail 'request cleanup'
[ "${#results[@]}" -eq 0 ] || crf_fail 'result cleanup'

printf 'graphql-log-api: OK\n'
