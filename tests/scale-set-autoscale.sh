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
err(){ :; }
backend_scaleset_admission_allowed(){ return 0; }
fleet_inventory_refresh(){ : >"$RUNDIR/inventory"; INVENTORY_FILE="$RUNDIR/inventory"; }
resource_snapshot_refresh(){
  RESOURCE_CPU_BUDGET_MILLI=4000
  RESOURCE_MEMORY_BUDGET_BYTES=8589934592
  RESOURCE_CPU_ADMISSIBLE_MILLI=4000
  RESOURCE_MEMORY_ADMISSIBLE_BYTES=8589934592
}
scaleset_snapshot_refresh(){
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  until="$(date -u -d '+20 seconds' +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "{\"schema_version\":1,\"controller_instance_id\":\"controller\",\"config_revision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"ownership_revision\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"sequence\":2,\"observed_at\":\"$now\",\"valid_until\":\"$until\",\"pools\":[{\"pool_id\":\"python\",\"scale_set_id\":41,\"assigned_jobs\":1,\"advertised_capacity\":0,\"last_message_id\":9,\"session_healthy\":true,\"acquired_handles\":[501],\"observed_at\":\"$now\",\"valid_until\":\"$until\"}]}" >"$SCALESET_SNAPSHOT"
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

prewarm="$RUNDIR/prewarm.python"
printf 'target=2\nconfig_revision=%064d\nexpires=%s\n' 1 "$(( $(date +%s) - 1 ))" >"$prewarm"
chmod 0600 "$prewarm"
! scaleset_prewarm_target python "$(config_revision)"
[ ! -e "$prewarm" ]
printf 'target=2\nconfig_revision=%064d\nexpires=%s\n' 2 "$(( $(date +%s) + 60 ))" >"$prewarm"
chmod 0600 "$prewarm"
! scaleset_prewarm_target python "$(config_revision)"
[ ! -e "$prewarm" ]

run_autoscale_tick(){
  scaleset_autoscale_tick
}
run_autoscale_tick
# The one admitted offer is the resource-backed slot for the already assigned
# handle; assigned demand is not counted a second time.
grep -q '^publish_capacity_leases|.*"python":1' "$calls"
grep -q '^issue_jit|.*"work_handle":501' "$calls"
grep -q '^python|lease-python-.*|501|[0-9a-f]\{64\}|a\{64\}|QUJDRA==$' "$root/jit"
lease="$(find "$RUNDIR/reservations" -type f -name 'lease-python-*.state' | head -1)"
[ -f "$lease" ]
[ "$(reservation_field "$lease" phase)" = assigned ]

# A second scheduling transaction cannot enter the snapshot/plan/commit region.
(
  exec 9>"$RUNDIR/scaleset.tick.lock"
  flock 9
  : >"$root/lock-ready"
  sleep 2
) &
lock_pid=$!
while [ ! -e "$root/lock-ready" ]; do sleep .05; done
SCALESET_TICK_LOCK_TIMEOUT_SECONDS=1
! scaleset_autoscale_tick
wait "$lock_pid"

echo "scale-set-autoscale: OK"
