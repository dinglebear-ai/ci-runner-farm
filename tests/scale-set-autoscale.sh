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
RUNNER_POOLS='v2|python|python|node|1|2|2|0|1|2g'
POOL_BACKEND=scaleset
AUTOSCALE=true
POOL_AUTOSCALE=''
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
  printf '%s\n' "{\"schema_version\":1,\"controller_instance_id\":\"controller\",\"config_revision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"ownership_revision\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"sequence\":2,\"observed_at\":\"$now\",\"valid_until\":\"$until\",\"pools\":[{\"pool_id\":\"python\",\"scale_set_id\":41,\"assigned_jobs\":5,\"advertised_capacity\":0,\"last_message_id\":9,\"session_healthy\":true,\"acquired_handles\":[501],\"observed_at\":\"$now\",\"valid_until\":\"$until\"}]}" >"$SCALESET_SNAPSHOT"
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
printf 'target=65\nconfig_revision=%s\nexpires=%s\n' "$(config_revision)" "$(( $(date +%s) + 60 ))" >"$prewarm"
chmod 0600 "$prewarm"
! scaleset_prewarm_target python "$(config_revision)"
[ ! -e "$prewarm" ]
truncate -s 2048 "$prewarm"
chmod 0600 "$prewarm"
! scaleset_prewarm_target python "$(config_revision)"
[ ! -e "$prewarm" ]

# Fixed scale-set pools may take a temporary target above their unused
# autoscale ceiling, while automatic peers remain ceiling-bound. The record is
# bound to the same full config revision Fleet submits and the tick consumes.
scheduler_prewarm_set python 8 "$(config_revision)"
[ "$(scaleset_prewarm_target python "$(config_revision)")" = 8 ]
rm -f "$prewarm"
POOL_AUTOSCALE=python
! scheduler_prewarm_set python 3 "$(config_revision)"
[ "$(scaleset_scheduler_policy python 0 "$(config_revision)")" = '0|2|2' ]
[ "$(scaleset_scheduler_policy python 1 "$(config_revision)")" = '1|1|2' ]
scheduler_prewarm_set python 0 "$(config_revision)"
[ "$(scaleset_scheduler_policy python 0 "$(config_revision)")" = '0|2|2' ]
rm -f "$prewarm"
POOL_AUTOSCALE=''
[ "$(scaleset_scheduler_policy python 5 "$(config_revision)")" = '5|0|64' ]
printf 'target=2\nconfig_revision=%064d\nexpires=%s\n' 2 "$(( $(date +%s) + 60 ))" >"$prewarm"
chmod 0600 "$prewarm"
! scaleset_prewarm_target python "$(config_revision)"
[ ! -e "$prewarm" ]

run_autoscale_tick(){
  scaleset_autoscale_tick
}
run_autoscale_tick
# Five already-assigned jobs remain admitted, but the fixed pool does not add
# its idle value as demand headroom (an automatic peer would desire six here).
grep -q '^publish_capacity_leases|.*"python":2' "$calls"
grep -q '^python|5|2|' "$SCALESET_STATE_DIR/last-plan.tsv"
grep -q '^issue_jit|.*"work_handle":501' "$calls"
grep -q '^python|lease-python-.*|501|[0-9a-f]\{64\}|a\{64\}|QUJDRA==$' "$root/jit"
lease="$(grep -l '^phase=assigned$' "$RUNDIR"/reservations/lease-python-*.state | head -1)"
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
