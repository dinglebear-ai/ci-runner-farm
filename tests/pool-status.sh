#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"; mkdir -p "$RUNDIR/reservations" "$RUNDIR/scalesets"
INVENTORY_FILE="$tmp/inventory.tsv"
printf 'ci-runner-python-1|running|healthy|1000000000|2147483648|g|python|org:test|1|python|valid\n' > "$INVENTORY_FILE"
RESERVATION_DIR="$RUNDIR/reservations"
SCALESET_STATE_DIR="$RUNDIR/scalesets"
SCALESET_SNAPSHOT="$SCALESET_STATE_DIR/snapshot.json"
SCALESET_OWNERSHIP="$tmp/ownership.json"
RESOURCE_CPU_RESERVE=1
RESOURCE_MEMORY_RESERVE=1g

config_revision(){ printf '%064d\n' 1; }
json_escape(){ sed 's/\\/\\\\/g;s/"/\\"/g'; }
reservation_field(){ sed -n "s/^$2=//p" "$1" | head -1; }
resource_snapshot_refresh(){
  RESOURCE_CPU_BUDGET_MILLI=7000 RESOURCE_MEMORY_BUDGET_BYTES=7516192768
  RESOURCE_CPU_RESERVED_MILLI=1000 RESOURCE_MEMORY_RESERVED_BYTES=2147483648
  RESOURCE_CPU_ADMISSIBLE_MILLI=6000 RESOURCE_MEMORY_ADMISSIBLE_BYTES=5368709120
}
parse_cpu_milli(){ printf '1000\n'; }
parse_memory_bytes(){ printf '1073741824\n'; }
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-status.sh

cat >"$SCALESET_SNAPSHOT" <<EOF
{"schema_version":1,"controller_instance_id":"controller-1","config_revision":"$(printf '%064d' 1)","ownership_revision":"$(printf '%064d' 2)","sequence":9,"observed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","valid_until":"$(date -u -d '+20 seconds' +%Y-%m-%dT%H:%M:%SZ)","pools":[{"pool_id":"python","scale_set_id":77,"assigned_jobs":3,"advertised_capacity":2,"last_message_id":10,"session_healthy":true,"acquired_handles":[]}]}
EOF
chmod 0600 "$SCALESET_SNAPSHOT"
cat >"$SCALESET_OWNERSHIP" <<'EOF'
{"schema_version":2,"installation_id":"install","owner":"dinglebear-ai","production_runner_group_id":7,"quarantine_runner_group_id":8,"config_revision":"a","identity_revision":"b","records":[{"pool_id":"python","remote_name":"crf-python","scale_set_id":77,"runner_group_id":7,"configured_labels":["python"],"applied_labels":["python"],"remote_spec_revision":"c","state":"eligible","updated_at":"2026-07-30T20:00:00Z"}]}
EOF
chmod 0600 "$SCALESET_OWNERSHIP"
printf 'python|5|2|cpu_exhausted|1|2|2|4|3\n' >"$SCALESET_STATE_DIR/last-plan.tsv"
chmod 0600 "$SCALESET_STATE_DIR/last-plan.tsv"

cat > "$RESERVATION_DIR/op.state" <<'EOF'
operation_id=op
pool_id=python
runner_name=ci-runner-python-2
cpu_milli=1000
memory_bytes=2147483648
deadline=999
phase=reserved
EOF
cat > "$RESERVATION_DIR/bad.state" <<'EOF'
operation_id=bad
pool_id=python
runner_name=ci-runner-python-3
cpu_milli=
memory_bytes=999999999999999999999
deadline=
phase=unknown
EOF
ln -s "$RESERVATION_DIR/op.state" "$RESERVATION_DIR/link.state"

status_model_refresh
[ "$STATUS_OBSERVED_AT" -gt 0 ] || fail 'observed_at is not an integer timestamp'
[[ "$STATUS_INVENTORY_REVISION" =~ ^[0-9a-f]{64}$ ]] || fail 'inventory revision is not sha256'
printf '%s' "$STATUS_RESOURCES_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["cpu_milli"]["admissible"]??-1)===6000?0:1);'
printf '%s' "$STATUS_RESERVATIONS_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&count($j)===1&&($j[0]["operation_id"]??"")==="op"?0:1);'
row="$(status_scaleset_pool_tsv python)"
crf_assert_eq '3|2|1|77|eligible|0|0|5|2|3' "$row" 'live scale-set status projection'
chmod 0644 "$SCALESET_SNAPSHOT"
crf_assert_eq '-1|0|0|0|unknown|0|0|0|0|0' "$(status_scaleset_pool_tsv python)" 'unsafe snapshot mode must fail closed'
chmod 0600 "$SCALESET_SNAPSHOT"
STATUS_RESOURCES_JSON='{"stale":true}'
resource_snapshot_refresh(){ return 1; }
status_model_refresh
printf '%s' "$STATUS_RESOURCES_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["cpu_milli"]["budget"]??-1)===0?0:1);'

# Before a transition exists, Fleet must publish the exact scale-set ownership
# identity (including both runner groups), not the older generic fallback.
expected_ownership="$(printf '%064d' 9)"
migration_load(){
  MIGRATION_EFFECTIVE_BACKEND=classic MIGRATION_PHASE=classic_active
  MIGRATION_TRANSITION_ID= MIGRATION_REVISION="$(printf '%064d' 8)"
  MIGRATION_OWNERSHIP_REVISION=
}
scaleset_ownership_revision(){ printf '%s\n' "$expected_ownership"; }
status_backend_refresh
actual_ownership="$(printf '%s' "$STATUS_BACKEND_JSON" |
  php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["ownership_revision"]??"";')"
crf_assert_eq "$expected_ownership" "$actual_ownership" 'pre-migration scale-set ownership revision'
echo 'pool-status: OK'
