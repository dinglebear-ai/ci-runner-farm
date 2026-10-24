#!/usr/bin/env bash
# Native adapter must not detach classic workers, including fresh-cache polls.
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp="$(mktemp -d)"
trap 'rm -rf -- "$task_tmp"' EXIT
export CRF_CFGDIR="$task_tmp/config" CRF_RUNDIR="$task_tmp/runtime" CRF_SOURCE_ONLY=1 CRF_NATIVE_MODE=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
flock() { : > "$task_tmp/unowned-refresh"; return 1; }
docker() { return 0; }
shared_capacity_enabled() { return 1; }
managed_names() { return 0; }
managed_github_names() { return 0; }
export AUTOSCALE=true IMAGE_AUTOUPDATE=true
: > "$RUNDIR/warn.cache"
: > "$RUNDIR/sec.cache"
for function in autoscale_start recommendation_history_start lifecycle_start imageupdate_start; do
  "$function"
done
for freshness in fresh stale; do
  : > "$RUNDIR/usage.cache"
  if [ "$freshness" = stale ]; then touch -t 202001010000 "$RUNDIR/usage.cache"; fi
  cmd_dashboard_json > "$task_tmp/dashboard.json"
  cmd_status_json > "$task_tmp/status.json"
  wait
  [ ! -e "$task_tmp/unowned-refresh" ] || { echo 'native status detached a refresh worker' >&2; exit 1; }
done
reconcile_start
[ -f "$RUNDIR/native-reconcile.pending" ]
for file in autoscale.pid history.pid lifecycle.pid imageupdate.pid reconcile.pid; do
  [ ! -e "$RUNDIR/$file" ] || { echo "native worker detached: $file" >&2; exit 1; }
done
# Failed Docker enumeration must never turn into permission to unload.
docker() { return 1; }
if cmd_native_unload_inventory > "$task_tmp/unload.json"; then
  echo 'native unload accepted unavailable Docker' >&2; exit 1
fi
managed_names() { return 1; }
if cmd_status_json >/dev/null; then echo 'native status hid Docker failure' >&2; exit 1; fi
if cmd_dashboard_json >/dev/null; then echo 'native dashboard hid Docker failure' >&2; exit 1; fi
managed_names() { return 0; }
docker() { return 0; }
cmd_native_unload_inventory > "$task_tmp/unload.json"
php -r '$s=json_decode(file_get_contents($argv[1]),true);exit(($s["schema"]??"")==="native-unload-v1" && $s["containers"]===0 ? 0 : 1);' "$task_tmp/unload.json"
# Native cache clearing must finish its refresh inside the owned operation.
crf_cache_mutation_idle() { return 0; }
crf_safe_cache_root() { printf '%s\n' "$task_tmp/cache"; }
cmd_cache_usage_refresh() { : > "$task_tmp/cache-refresh-owned"; }
mkdir -p "$task_tmp/cache/npm"
CACHE_PKG_DIRS=npm
cmd_cache_clear_pkg >/dev/null
[ -f "$task_tmp/cache-refresh-owned" ]
# Busy drains yield immediately; native scheduling owns retries, including timeout.
runner_busy() { return 0; }
sleep() { echo 'native drain slept instead of yielding' >&2; exit 99; }
IMAGE_DRAIN_TIMEOUT=1 IMAGE_AUTOUPDATE_INTERVAL=1800
if drain_and_recreate test-runner; then echo 'busy runner was recycled' >&2; exit 1; fi
[ -f "$RUNDIR/native-drain.test-runner.started" ]
printf '1\n' > "$RUNDIR/native-drain.test-runner.started"
if drain_and_recreate test-runner; then exit 1; fi
[ -f "$RUNDIR/native-drain.test-runner.defer" ]
[ ! -f "$RUNDIR/native-drain.test-runner.started" ]
# A config drain likewise executes one bounded pass and retains its retry marker.
load_cfg() { :; }
reload_secret_files() { :; }
count_stale_runners() { echo 1; }
with_fleet_lock() { return 0; }
IMAGE_DRAIN_TIMEOUT=3600
set +e
( cmd_reconcile_drain )
native_result=$?
set -e
[ "$native_result" = 75 ] || { echo "native reconcile returned $native_result" >&2; exit 1; }
echo 'native-lifecycle: PASS — polling and worker requests remain native-owner controlled'
