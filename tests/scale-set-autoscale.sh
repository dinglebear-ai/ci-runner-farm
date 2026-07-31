#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
RUNDIR="$root/run"
CFGDIR="$root/cfg"
CACHE_ROOT="$root/cache"
SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT"

RUNNER_MODE=pools
RUNNER_POOLS='v2|python|python|node|1|0|auto|0|1|2g'
POOL_BACKEND=scaleset
GH_SCOPE=org
GH_OWNER=dinglebear-ai
NAME_PREFIX=ci-runner
SCALESET_STATE_DIR="$RUNDIR/scalesets"
SCALESET_SNAPSHOT="$SCALESET_STATE_DIR/snapshot.json"
mkdir -p "$SCALESET_STATE_DIR"

. "$SCRIPT_DIR/runner-pools.sh"
. "$SCRIPT_DIR/runner-resources.sh"
. "$SCRIPT_DIR/runner-scheduler.sh"
. "$SCRIPT_DIR/runner-scalesets.sh"
pool_snapshot_load
config_revision(){ printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
backend_scaleset_admission_allowed(){ return 0; }
fleet_inventory_refresh(){ : >"$RUNDIR/inventory"; INVENTORY_FILE="$RUNDIR/inventory"; }
resource_snapshot_refresh(){
  RESOURCE_CPU_BUDGET_MILLI=4000
  RESOURCE_MEMORY_BUDGET_BYTES=8589934592
  RESOURCE_CPU_ADMISSIBLE_MILLI=4000
  RESOURCE_MEMORY_ADMISSIBLE_BYTES=8589934592
}
scaleset_snapshot_refresh(){
  cat >"$SCALESET_SNAPSHOT" <<'EOF'
{"schema_version":1,"controller_instance_id":"controller","config_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ownership_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sequence":2,"observed_at":"2026-07-30T12:00:00Z","valid_until":"2099-07-30T12:00:00Z","pools":[{"pool_id":"python","scale_set_id":41,"assigned_jobs":1,"advertised_capacity":0,"last_message_id":9,"session_healthy":true,"acquired_handles":[501]}]}
EOF
  chmod 0600 "$SCALESET_SNAPSHOT"
}
calls="$root/calls"
scaleset_request(){
  local payload="${2-}"
  [ -n "$payload" ] || payload='{}'
  printf '%s|%s\n' "$1" "$payload" >>"$calls"
  case "$1" in
    publish_capacity_leases) printf '{"schema_version":1,"request_id":"r","ok":true}\n' ;;
    issue_jit) printf '{"schema_version":1,"request_id":"r","ok":true,"result":{"descriptor":"QUJDRA==","scale_set_id":41}}\n' ;;
    *) return 1 ;;
  esac
}
jit_execute(){
  local descriptor
  IFS= read -r descriptor
  printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$descriptor" >>"$root/jit"
}

run_autoscale_tick(){
  scaleset_autoscale_tick
}
run_autoscale_tick
# GitHub's max-capacity header is the total number of jobs this scale set may
# own, not the number of new starts admitted during this tick. With 4 CPUs and
# a 1-CPU pool, the listener must keep advertising four slots after the first
# warm runner starts; otherwise future jobs remain queued forever.
grep -q '^publish_capacity_leases|.*"python":4' "$calls"
grep -q '^issue_jit|.*"work_handle":501' "$calls"
grep -q '^python|lease-python-.*|501|[0-9a-f]\{64\}|a\{64\}|QUJDRA==$' "$root/jit"
lease="$(find "$RUNDIR/reservations" -type f -name 'lease-python-*.state' | head -1)"
[ -f "$lease" ]
[ "$(reservation_field "$lease" phase)" = assigned ]

echo "scale-set-autoscale: OK"
