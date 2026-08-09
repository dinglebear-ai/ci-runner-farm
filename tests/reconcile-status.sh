#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d)"
lookalike_pid=""
worker_pid=""
cleanup() {
  [ -z "$lookalike_pid" ] || kill "$lookalike_pid" 2>/dev/null || true
  [ -z "$worker_pid" ] || kill -- "-$worker_pid" 2>/dev/null || true
  [ -z "$lookalike_pid" ] || wait "$lookalike_pid" 2>/dev/null || true
  [ -z "$worker_pid" ] || wait "$worker_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

for fn in reconcile_proc_record reconcile_identity_read reconcile_group_live reconcile_group_owned reconcile_pid_active cmd_reconcile_status; do
  sed -n "/^${fn}()/,/^}/p" "$engine" >>"$tmp/functions.sh"
done
# shellcheck disable=SC1090,SC1091
. "$tmp/functions.sh"

RUNDIR="$tmp/run"
mkdir -p "$RUNDIR"
RECONCILE_IDENTITY="$RUNDIR/reconcile.identity"

bash -c 'exec -a runner-farm.sh-reconcile-drain sleep 30' &
lookalike_pid=$!
status="$(cmd_reconcile_status)"
crf_assert_contains "$status" '"active":false' 'unrelated argv lookalike counted as reconciliation ownership'
kill -0 "$lookalike_pid" || crf_fail 'reconciliation status disturbed an unrelated argv lookalike'

helper="$tmp/reconcile-worker.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$helper"
chmod 0700 "$helper"
token=dddddddddddddddddddddddddddddddd
setsid env CRF_RECONCILE_SESSION_TOKEN="$token" "$helper" reconcile-drain &
worker_pid=$!
for _ in $(seq 1 100); do
  record="$(reconcile_proc_record "$worker_pid" 2>/dev/null || true)"
  [ -n "$record" ] && break
  sleep 0.01
done
[ -n "${record:-}" ] || crf_fail 'test reconciliation worker did not start'
read -r _ _ _ starttime <<<"$record"
printf '%s %s %s %s\n' "$worker_pid" "$starttime" "$token" "$helper" >"$RECONCILE_IDENTITY"
status="$(cmd_reconcile_status)"
crf_assert_contains "$status" '"active":true' 'exact reconciliation identity was not reported active'
crf_assert_contains "$status" "\"pid\":$worker_pid" 'reconciliation status lost the exact owner pid'

printf 'malformed\n' >"$RECONCILE_IDENTITY"
set +e
status="$(cmd_reconcile_status)"
rc=$?
set -e
[ "$rc" -ne 0 ] || crf_fail 'malformed reconciliation identity did not fail closed'
crf_assert_contains "$status" '"ok":false' 'malformed reconciliation identity reported success'
crf_assert_contains "$status" '"active":true' 'malformed reconciliation identity failed open'

rm -f "$RECONCILE_IDENTITY"
ln -s "$tmp/missing-identity-target" "$RECONCILE_IDENTITY"
set +e
status="$(cmd_reconcile_status)"
rc=$?
set -e
[ "$rc" -ne 0 ] || crf_fail 'dangling reconciliation identity symlink did not fail closed'
crf_assert_contains "$status" '"active":true' 'dangling reconciliation identity symlink failed open'

echo 'reconcile-status: OK'
