#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"
CFGDIR="$tmp/cfg"
CACHE_ROOT="$tmp/cache"
SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
NAME_PREFIX=ci-runner
LABEL_NS=net.unraid.ci-runner-farm
mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT"
pool_id_valid(){ [[ "${1:-}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }
. "$SCRIPT_DIR/runner-jit.sh"
. "$SCRIPT_DIR/runner-status.sh"
JIT_RECENT_ACTIVITY_MAX=3

write_job(){
  local runner="$1" pool="$2" handle="$3" job="$4" result="$5" second="$6" out
  out="$JIT_LOG_ROOT/$runner"; mkdir -p "$out"
  printf '[2026-08-01 01:02:%sZ INFO Terminal] WRITE LINE: 2026-08-01 01:02:%sZ: Running job: %s\n' "$second" "$second" "$job" >"$out/Runner_test.log"
  printf '[2026-08-01 01:02:%sZ INFO JobRunner] Job result after all job steps finish: %s\n[2026-08-01 01:02:%sZ INFO Worker] Job completed.\n' "$second" "$result" "$second" >"$out/Worker_test.log"
  jit_recent_activity_record "$runner" "$pool" "$handle"
}

r1=ci-runner-jit-ops-aaaaaaaaaaaaaaaaaaaa
write_job "$r1" ops 101 "Repository Contract" Succeeded 11
[ "$JIT_RECENT_ACTIVITY_FILE" = "$RUNDIR/recent-jobs.jsonl" ] || crf_fail "recent activity is not on runtime tmpfs"
[ "$(stat -c %a "$JIT_RECENT_ACTIVITY_FILE")" = 600 ] || crf_fail "recent activity mode is not 0600"
[ "$(wc -l <"$JIT_RECENT_ACTIVITY_FILE")" -eq 1 ] || crf_fail "first activity record was not written"
jq -e '.runner_name==$r and .pool_id=="ops" and .work_handle==101 and .job=="Repository Contract" and .conclusion=="success"' --arg r "$r1" "$JIT_RECENT_ACTIVITY_FILE" >/dev/null

write_job "$r1" ops 101 "Repository Contract rerun" Failed 12
[ "$(wc -l <"$JIT_RECENT_ACTIVITY_FILE")" -eq 1 ] || crf_fail "runner activity was not deduplicated"
jq -e '.job=="Repository Contract rerun" and .conclusion=="failure"' "$JIT_RECENT_ACTIVITY_FILE" >/dev/null

write_job ci-runner-jit-rust-bbbbbbbbbbbbbbbbbbbb rust 102 "MSRV Gate" Succeeded 13
write_job ci-runner-jit-python-cccccccccccccccccccc python 103 "Python tests" Succeeded 14
write_job ci-runner-jit-go-dddddddddddddddddddd go 104 "Go tests" Cancelled 15
[ "$(wc -l <"$JIT_RECENT_ACTIVITY_FILE")" -eq 3 ] || crf_fail "recent activity cap was not enforced"
! grep -Fq "$r1" "$JIT_RECENT_ACTIVITY_FILE" || crf_fail "old activity was not evicted"

STATUS_RECENT_ACTIVITY_MAX=2
status_recent_activity_json
printf '%s
' "$STATUS_RECENT_ACTIVITY_JSON" | jq -e 'length==2 and .[0].job=="Go tests" and .[0].conclusion=="cancelled" and .[1].job=="Python tests"' >/dev/null

printf 'not-json\n' >>"$JIT_RECENT_ACTIVITY_FILE"
chmod 0600 "$JIT_RECENT_ACTIVITY_FILE"
status_recent_activity_json
printf '%s
' "$STATUS_RECENT_ACTIVITY_JSON" | jq -e 'length==2' >/dev/null || crf_fail "malformed activity poisoned valid rows"

echo "recent-activity: OK"
