#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-image-build-operations.XXXXXX)"
worker_pid=
exec 8>&- 2>/dev/null || true
trap '[ -z "$worker_pid" ] || kill "$worker_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
mkdir -p "$root/include" "$root/config" "$root/run"
for file in runner-operations.sh operation-record.php runner-operation-workers.sh; do
  cp "src/usr/local/emhttp/plugins/ci-runner-farm/include/$file" "$root/include/"
done
SCRIPT_DIR="$root/include"
CFGDIR="$root/config"
RUNDIR="$root/run"
OPERATION_DIR="$CFGDIR/operations"
OPERATION_RUNTIME_DIR="$RUNDIR/operations"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operations.sh"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operation-workers.sh"

printf 'FROM scratch\nLABEL version=1\n' >"$CFGDIR/Dockerfile"
expected="$(sha256sum "$CFGDIR/Dockerfile" | cut -d' ' -f1)"
config_sha="$(printf config | sha256sum | cut -d' ' -f1)"
config_revision(){ printf '%s\n' "$config_sha"; }
public_code(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["code"]??"";'; }
public_state(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["state"]??"";'; }

build_calls="$root/build.calls"
cmd_build_image(){
  local snapshot="$1"
  printf '%s\n' "$snapshot" >>"$build_calls"
  crf_assert_file_mode "$snapshot" 600
  crf_assert_eq "$CRF_TEST_EXPECTED_SHA" "$(sha256sum "$snapshot" | cut -d' ' -f1)" 'worker snapshot SHA'
  printf 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz\n'
  printf 'github_pat_abcdefghijklmnopqrstuvwxyz\n'
  return "${CRF_TEST_BUILD_RC:-0}"
}
export CRF_TEST_EXPECTED_SHA="$expected"

success_id='30000001-0000-0000-0000-000000000001'
CRF_OPERATION_ID="$success_id" operation_create image_build "$config_sha" image_build_log >/dev/null
success_snapshot="$(operation_image_snapshot_prepare "$success_id" "$expected")"
crf_assert_file_mode "$success_snapshot" 600
operation_image_build_worker "$success_id" "$expected"
crf_assert_eq succeeded "$(public_state "$success_id")" 'image build success state'
crf_assert_eq image_built "$(public_code "$success_id")" 'image build success code'
[ ! -e "$success_snapshot" ] || crf_fail 'successful image build left Dockerfile snapshot'
crf_assert_file_mode "$RUNDIR/build.log" 600
grep -Fq '__BUILD_RC__=0' "$RUNDIR/build.log" || crf_fail 'successful image build sentinel missing'
success_public="$(operation_read_public "$success_id")"
printf '%s' "$success_public" | php -r '
$j=json_decode(stream_get_contents(STDIN),true);$text=implode("\n",$j["output"]??[]);
exit(strpos($text,"abcdefghijklmnopqrstuvwxyz")===false&&strpos($text,"[REDACTED]")!==false?0:1);
' || crf_fail 'image build summary leaked credentials'

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
status_snippet="$root/build-status.sh"
sed -n '/^cmd_build_status()/,/^}/p' "$engine" >"$status_snippet"
# shellcheck disable=SC1090
. "$status_snippet"
json_string(){ php -r '$v=stream_get_contents(STDIN);echo json_encode($v,JSON_UNESCAPED_SLASHES);'; }
status="$(cmd_build_status)"
crf_assert_contains "$status" '"running":false' 'durable build still reports running'
crf_assert_contains "$status" '"rc":0' 'durable build status lost success code'

failure_id='30000002-0000-0000-0000-000000000002'
CRF_OPERATION_ID="$failure_id" operation_create image_build "$config_sha" image_build_log >/dev/null
operation_image_snapshot_prepare "$failure_id" "$expected" >/dev/null
CRF_TEST_BUILD_RC=7 operation_image_build_worker "$failure_id" "$expected"
crf_assert_eq failed "$(public_state "$failure_id")" 'image build failure state'
crf_assert_eq build_failed "$(public_code "$failure_id")" 'image build failure code'
grep -Fq '__BUILD_RC__=7' "$RUNDIR/build.log" || crf_fail 'failed image build sentinel missing'
status="$(cmd_build_status)"
crf_assert_contains "$status" '"rc":7' 'durable build status lost failure code'

stale_id='30000003-0000-0000-0000-000000000003'
CRF_OPERATION_ID="$stale_id" operation_create image_build "$config_sha" image_build_log >/dev/null
stale_snapshot="$(operation_image_snapshot_prepare "$stale_id" "$expected")"
printf '# changed\n' >>"$stale_snapshot"
before_calls="$(wc -l <"$build_calls")"
operation_image_build_worker "$stale_id" "$expected"
after_calls="$(wc -l <"$build_calls")"
crf_assert_eq "$before_calls" "$after_calls" 'stale image snapshot reached build'
crf_assert_eq stale_dockerfile "$(public_code "$stale_id")" 'stale image snapshot code'
[ ! -e "$stale_snapshot" ] || crf_fail 'stale image snapshot was not removed'

lock_id='30000004-0000-0000-0000-000000000004'
CRF_OPERATION_ID="$lock_id" operation_create image_build "$config_sha" image_build_log >/dev/null
lock_snapshot="$(operation_image_snapshot_prepare "$lock_id" "$expected")"
exec 8>"$RUNDIR/build.lock"
chmod 0600 "$RUNDIR/build.lock"
flock -n 8
operation_image_build_worker "$lock_id" "$expected"
crf_assert_eq operation_running "$(public_code "$lock_id")" 'legacy build lock conflict code'
[ ! -e "$lock_snapshot" ] || crf_fail 'lock-conflicted image snapshot was not removed'
flock -u 8
exec 8>&-

active_id='30000005-0000-0000-0000-000000000005'
CRF_OPERATION_ID="$active_id" operation_create image_build "$config_sha" image_build_log >/dev/null
set +e
active_reply="$(cmd_image_build_operation_start "$expected")"
active_rc=$?
set -e
crf_assert_eq 4 "$active_rc" 'duplicate image build start exit code'
crf_assert_contains "$active_reply" '"code":"operation_running"' 'duplicate image build start code'
crf_assert_contains "$active_reply" "$active_id" 'duplicate image build operation ID'
operation_finish "$active_id" failed test_cleanup 'Test cleanup.' >/dev/null

printf 'FROM scratch\nLABEL version=2\n' >"$CFGDIR/Dockerfile"
set +e
stale_reply="$(cmd_image_build_operation_start "$expected")"
stale_rc=$?
set -e
crf_assert_eq 3 "$stale_rc" 'stale Dockerfile start exit code'
crf_assert_contains "$stale_reply" '"code":"stale_dockerfile"' 'stale Dockerfile start code'
printf 'FROM scratch\nLABEL version=1\n' >"$CFGDIR/Dockerfile"
crf_assert_eq "$expected" "$(operation_image_source_hash)" 'restored Dockerfile identity'

launch_id='30000006-0000-0000-0000-000000000006'
export CRF_OPERATION_ID="$launch_id" CRF_OPERATION_WORKER_LAUNCHER="$root/missing-launcher"
set +e
launch_reply="$(cmd_image_build_operation_start "$expected")"
launch_rc=$?
set -e
unset CRF_OPERATION_ID CRF_OPERATION_WORKER_LAUNCHER
crf_assert_eq 5 "$launch_rc" 'image build launch failure exit code'
crf_assert_contains "$launch_reply" '"code":"backend_unavailable"' 'image build launch failure code'
crf_assert_eq launch_failed "$(public_code "$launch_id")" 'durable image build launch failure'
[ ! -e "$OPERATION_RUNTIME_DIR/$launch_id.Dockerfile" ] || crf_fail 'launch failure left Dockerfile snapshot'

cat >"$root/launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$CRF_TEST_LAUNCH_PID"
printf '%s\n' "$*" >"$CRF_TEST_LAUNCH_ARGS"
exec sleep 30
EOF
chmod 0755 "$root/launcher"
start_id='30000007-0000-0000-0000-000000000007'
export CRF_OPERATION_ID="$start_id" CRF_OPERATION_WORKER_LAUNCHER="$root/launcher"
export CRF_TEST_LAUNCH_PID="$root/launch.pid" CRF_TEST_LAUNCH_ARGS="$root/launch.args"
start_reply="$(cmd_image_build_operation_start "$expected")"
unset CRF_OPERATION_ID CRF_OPERATION_WORKER_LAUNCHER
crf_assert_contains "$start_reply" '"ok":true' 'image build start success'
crf_assert_contains "$start_reply" "$start_id" 'image build start operation ID'
for _ in $(seq 1 100); do [ -s "$root/launch.pid" ] && break; sleep 0.02; done
[ -s "$root/launch.pid" ] || crf_fail 'image build launcher did not start'
worker_pid="$(cat "$root/launch.pid")"
crf_assert_eq "image-build-operation-worker $start_id $expected" "$(cat "$root/launch.args")" 'image build launcher arguments'
start_snapshot="$OPERATION_RUNTIME_DIR/$start_id.Dockerfile"
crf_assert_file_mode "$start_snapshot" 600
crf_assert_eq "$expected" "$(sha256sum "$start_snapshot" | cut -d' ' -f1)" 'queued image snapshot identity'
kill "$worker_pid" 2>/dev/null || true
worker_pid=
rm -f -- "$start_snapshot"
operation_finish "$start_id" failed test_cleanup 'Test cleanup.' >/dev/null

set +e
invalid_reply="$(cmd_image_build_operation_start bad)"
invalid_rc=$?
set -e
crf_assert_eq 2 "$invalid_rc" 'invalid image build SHA exit code'
crf_assert_contains "$invalid_reply" '"code":"invalid_revision"' 'invalid image build SHA code'

echo 'image-build-operations: OK'
