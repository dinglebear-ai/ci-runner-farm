#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-operation-timeout.XXXXXX)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/include" "$root/config" "$root/run"
for file in runner-operations.sh operation-record.php runner-operation-workers.sh; do
  cp "src/usr/local/emhttp/plugins/ci-runner-farm/include/$file" "$root/include/"
done
cat >"$root/hung-command" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
( trap '' TERM; while :; do sleep 1; done ) &
printf '%s\n' "$!" >"$CRF_TEST_DESCENDANT_PID"
while :; do sleep 1; done
EOF
chmod 0755 "$root/hung-command"

SCRIPT_DIR="$root/include"
CFGDIR="$root/config"
RUNDIR="$root/run"
OPERATION_DIR="$CFGDIR/operations"
OPERATION_RUNTIME_DIR="$RUNDIR/operations"
CRF_OPERATION_COMMAND_LAUNCHER="$root/hung-command"
OPERATION_PROVISIONING_TIMEOUT_SECONDS=1
OPERATION_KILL_AFTER_SECONDS=1
export CRF_TEST_DESCENDANT_PID="$root/descendant.pid"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operations.sh"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operation-workers.sh"

sha="$(printf config | sha256sum | cut -d' ' -f1)"
config_revision(){ printf '%s\n' "$sha"; }
public_field(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j[$argv[1]]??"";' "$2"; }

id=80000001-0000-4000-8000-000000000001
CRF_OPERATION_ID="$id" operation_create provisioning_validation "$sha" provisioning_log >/dev/null
operation_provisioning_worker "$id"
crf_assert_eq failed "$(public_field "$id" state)" 'timed out operation state'
crf_assert_eq timed_out "$(public_field "$id" code)" 'timed out operation code'
[ -s "$CRF_TEST_DESCENDANT_PID" ] || crf_fail 'hung descendant PID was not captured'
descendant="$(cat "$CRF_TEST_DESCENDANT_PID")"
if kill -0 "$descendant" 2>/dev/null; then
  state="$(ps -o stat= -p "$descendant" 2>/dev/null || true)"
  case "$state" in Z*) ;; *) crf_fail 'timeout left a live descendant process' ;; esac
fi

next=80000002-0000-4000-8000-000000000002
CRF_OPERATION_ID="$next" operation_create_unique provisioning_validation "$sha" provisioning_log >/dev/null ||
  crf_fail 'timed out operation blocked the next operation of its kind'

echo 'operation-worker-timeouts: OK'
