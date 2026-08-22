#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-compat-operations.XXXXXX)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/include" "$root/config" "$root/run"
cp src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-operations.sh "$root/include/"
cp src/usr/local/emhttp/plugins/ci-runner-farm/include/operation-record.php "$root/include/"
cp src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-operation-workers.sh "$root/include/"
SCRIPT_DIR="$root/include"
CFGDIR="$root/config"
RUNDIR="$root/run"
OPERATION_DIR="$CFGDIR/operations"
OPERATION_RUNTIME_DIR="$RUNDIR/operations"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operations.sh"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operation-workers.sh"

sha="$(printf config | sha256sum | cut -d' ' -f1)"
old_sha="$(printf old-config | sha256sum | cut -d' ' -f1)"
printf '%s\n' "$sha" >"$root/current.sha"
config_revision(){ cat "$root/current.sha"; }
SCALESET_COMPAT="$CFGDIR/scaleset-compatibility.json"
SCALESET_PROBE_CONFIG="$RUNDIR/probe-config.json"
probe_calls="$root/probe.calls"
scaleset_probe_config_write(){
  [ "${CRF_TEST_PROBE_CONFIG_FAIL:-0}" = 0 ] || return 1
  printf '%s\n' '{"schema_version":1}' >"$SCALESET_PROBE_CONFIG"
  chmod 0600 "$SCALESET_PROBE_CONFIG"
}
scaleset_bound_identity(){ printf '%s' 'plugin|image|dockerfile|entrypoint|owner|installation|host'; }
cat >"$root/fake-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"$CRF_TEST_PROBE_CALLS"
if [ "${1:-}" = check-compatibility ]; then
  [ "${CRF_TEST_CHECK_FAIL:-0}" = 0 ] || exit 8
  exit 0
fi
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] || exit 9
owner=owner; [ "${CRF_TEST_BAD_IDENTITY:-0}" = 0 ] || owner=foreign
printf '{"schema_version":1,"compatibility_record_id":"%s","plugin_digest":"plugin","image_digest":"image","dockerfile_digest":"dockerfile","entrypoint_digest":"entrypoint","owner":"%s","installation_id":"installation","host_id":"host"}\n' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$owner" >"$out"
chmod 0600 "$out"
printf 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz\n'
printf 'github_pat_abcdefghijklmnopqrstuvwxyz\n'
if [ -n "${CRF_TEST_MUTATE_CONFIG_FILE:-}" ]; then
  printf '%s\n' "$CRF_TEST_MUTATE_CONFIG_SHA" >"$CRF_TEST_MUTATE_CONFIG_FILE"
fi
exit "${CRF_TEST_PROBE_RC:-0}"
EOF
chmod 0755 "$root/fake-helper"
SCALESET_HELPER="$root/fake-helper"
export CRF_TEST_PROBE_CALLS="$probe_calls"

public_code(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["code"]??"";'; }
public_state(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["state"]??"";'; }

success_id='10000001-0000-0000-0000-000000000001'
CRF_OPERATION_ID="$success_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
operation_compatibility_worker "$success_id"
crf_assert_eq succeeded "$(public_state "$success_id")" 'compatibility success state'
crf_assert_eq compatible "$(public_code "$success_id")" 'compatibility success code'
crf_assert_file_mode "$SCALESET_COMPAT" 600
success_public="$(operation_read_public "$success_id")"
printf '%s' "$success_public" | php -r '
$j=json_decode(stream_get_contents(STDIN),true);$text=implode("\n",$j["output"]??[]);
exit(strpos($text,"abcdefghijklmnopqrstuvwxyz")===false&&strpos($text,"[REDACTED]")!==false?0:1);
' || crf_fail 'compatibility summary leaked credentials'
canonical_hash="$(sha256sum "$SCALESET_COMPAT" | cut -d' ' -f1)"
bad_identity_id='10000001-0000-0000-0000-000000000011'
CRF_OPERATION_ID="$bad_identity_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
export CRF_TEST_BAD_IDENTITY=1
operation_compatibility_worker "$bad_identity_id"
unset CRF_TEST_BAD_IDENTITY
crf_assert_eq evidence_invalid "$(public_code "$bad_identity_id")" 'bound identity mismatch code'
crf_assert_eq "$canonical_hash" "$(sha256sum "$SCALESET_COMPAT" | cut -d' ' -f1)" 'invalid evidence replaced canonical record'
[ ! -e "$SCALESET_COMPAT.operation.$bad_identity_id.tmp" ] || crf_fail 'identity mismatch left temporary evidence'

failure_id='10000002-0000-0000-0000-000000000002'
CRF_OPERATION_ID="$failure_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
export CRF_TEST_PROBE_RC=7
operation_compatibility_worker "$failure_id"
unset CRF_TEST_PROBE_RC
crf_assert_eq failed "$(public_state "$failure_id")" 'probe failure state'
crf_assert_eq probe_failed "$(public_code "$failure_id")" 'probe failure code'
[ ! -e "$SCALESET_COMPAT.operation.$failure_id.tmp" ] || crf_fail 'probe failure left temporary evidence'

invalid_id='10000003-0000-0000-0000-000000000003'
CRF_OPERATION_ID="$invalid_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
CRF_TEST_PROBE_CONFIG_FAIL=1 operation_compatibility_worker "$invalid_id"
crf_assert_eq evidence_invalid "$(public_code "$invalid_id")" 'invalid evidence code'

stale_id='10000004-0000-0000-0000-000000000004'
CRF_OPERATION_ID="$stale_id" operation_create compatibility_test "$old_sha" compatibility_log >/dev/null
before_calls="$(wc -l <"$probe_calls")"
operation_compatibility_worker "$stale_id"
after_calls="$(wc -l <"$probe_calls")"
crf_assert_eq "$before_calls" "$after_calls" 'stale configuration reached compatibility helper'
crf_assert_eq stale_config "$(public_code "$stale_id")" 'pre-probe stale configuration code'

mutated_id='10000005-0000-0000-0000-000000000005'
CRF_OPERATION_ID="$mutated_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
export CRF_TEST_MUTATE_CONFIG_FILE="$root/current.sha" CRF_TEST_MUTATE_CONFIG_SHA="$old_sha"
operation_compatibility_worker "$mutated_id"
unset CRF_TEST_MUTATE_CONFIG_FILE CRF_TEST_MUTATE_CONFIG_SHA
crf_assert_eq stale_config "$(public_code "$mutated_id")" 'post-probe stale configuration code'
[ ! -e "$SCALESET_COMPAT.operation.$mutated_id.tmp" ] || crf_fail 'post-probe config drift left temporary evidence'
printf '%s\n' "$sha" >"$root/current.sha"

active_id='10000006-0000-0000-0000-000000000006'
CRF_OPERATION_ID="$active_id" operation_create compatibility_test "$sha" compatibility_log >/dev/null
set +e
active_reply="$(cmd_compatibility_operation_start "$sha")"
active_rc=$?
set -e
crf_assert_eq 4 "$active_rc" 'duplicate compatibility start exit code'
crf_assert_contains "$active_reply" '"code":"operation_running"' 'duplicate compatibility start code'
crf_assert_contains "$active_reply" "$active_id" 'duplicate compatibility operation ID'
operation_finish "$active_id" failed test_cleanup 'Test cleanup.' >/dev/null

launch_id='10000007-0000-0000-0000-000000000007'
export CRF_OPERATION_ID="$launch_id" CRF_OPERATION_WORKER_LAUNCHER="$root/missing-launcher"
set +e
launch_reply="$(cmd_compatibility_operation_start "$sha")"
launch_rc=$?
set -e
unset CRF_OPERATION_ID CRF_OPERATION_WORKER_LAUNCHER
crf_assert_eq 5 "$launch_rc" 'compatibility launch failure exit code'
crf_assert_contains "$launch_reply" '"code":"backend_unavailable"' 'compatibility launch failure response'
crf_assert_eq failed "$(public_state "$launch_id")" 'compatibility launch failure state'
crf_assert_eq launch_failed "$(public_code "$launch_id")" 'compatibility launch failure durable code'

set +e
stale_reply="$(cmd_compatibility_operation_start "$old_sha")"
stale_rc=$?
set -e
crf_assert_eq 3 "$stale_rc" 'compatibility stale start exit code'
crf_assert_contains "$stale_reply" '"code":"stale_config"' 'compatibility stale start response'

printf 'compatibility-operations: OK\n'
