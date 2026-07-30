#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
RUNDIR="$tmp/run"; mkdir -p "$RUNDIR/reservations"
INVENTORY_FILE="$tmp/inventory.tsv"
printf 'ci-runner-python-1|running|healthy|1000000000|2147483648|g|python|org:test|1|python|valid\n' > "$INVENTORY_FILE"
RESERVATION_DIR="$RUNDIR/reservations"
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

cat > "$RESERVATION_DIR/op.state" <<'EOF'
operation_id=op
pool_id=python
runner_name=ci-runner-python-2
cpu_milli=1000
memory_bytes=2147483648
deadline=999
phase=reserved
EOF

status_model_refresh
[ "$STATUS_OBSERVED_AT" -gt 0 ] || fail 'observed_at is not an integer timestamp'
[[ "$STATUS_INVENTORY_REVISION" =~ ^[0-9a-f]{64}$ ]] || fail 'inventory revision is not sha256'
printf '%s' "$STATUS_RESOURCES_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["cpu_milli"]["admissible"]??-1)===6000?0:1);'
printf '%s' "$STATUS_RESERVATIONS_JSON" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j[0]["operation_id"]??"")==="op"?0:1);'
echo 'pool-status: OK'
