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
# The shell must never mutate a cache outside the Core-held binding.
CRF_SOURCE_ONLY=0 CRF_NATIVE_ACTION=start CRF_BOUND_CACHE_ROOT=/mnt/cache/claimed CACHE_ROOT=/mnt/cache/old
if native_cache_binding_matches; then echo 'unclaimed native cache accepted' >&2; exit 1; fi
CACHE_ROOT=/mnt/cache/claimed
native_cache_binding_matches
shared_capacity_enabled() { return 0; }
if native_cache_binding_matches; then echo 'legacy shared ownership bypassed' >&2; exit 1; fi
if cmd_native_standalone_preflight; then echo 'legacy shared owner replaced' >&2; exit 1; fi
shared_capacity_enabled() { return 1; }
CRF_SOURCE_ONLY=1
# Native scheduler state is not a nonexistent classic PID daemon.
: > "$CFGDIR/native-fleet.enabled"
for function in autoscale_status lifecycle_status imageupdate_status; do
  [ "$("$function")" = 'native scheduled' ]
done
rm "$CFGDIR/native-fleet.enabled"
[ "$(autoscale_status)" = stopped ]
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
# Native Fleet summaries reuse the classic cached readers without remote refresh.
printf 'github %s 3\n' "$(date +%s)" > "$RUNDIR/queued.cache"
printf 'github %s 8 2 1 0 11\n' "$(date +%s)" > "$RUNDIR/stats.cache"
printf '%s 4096 1024\n' "$(date +%s)" > "$RUNDIR/cache-usage.cache"
cmd_native_fleet_overview_json > "$task_tmp/overview.json"
php -r '$s=json_decode(file_get_contents($argv[1]),true);exit(is_array($s["fleet"]["runners"]??null) && $s["queue"]["queued"]===3 && $s["stats"]["total"]===11 && $s["cache"]["pkg"]===1024 ? 0 : 1);' "$task_tmp/overview.json"
[ ! -e "$task_tmp/unowned-refresh" ] || { echo 'native overview detached remote refresh' >&2; exit 1; }
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
# The actual native adapter forwards repository identity into pool validation.
CI_PROVIDER=github GH_SCOPE=repo GH_OWNER=dinglebear-ai GH_REPOS=dinglebear-ai/labby
RUNNER_MODE=pools RUNNER_POOLS='v3|build|farm-smoke-steamy-20261025||1|1|1|0|2|12g|builtin'
[ "$(cmd_native_build_limits)" = '1|1|12288|2' ] || { echo 'repository native limits rejected' >&2; exit 1; }
GH_REPOS='dinglebear-ai/labby other/repo'
if cmd_native_build_limits >/dev/null 2>&1; then echo 'multiple repository pools accepted' >&2; exit 1; fi
echo 'native-lifecycle: PASS — polling and worker requests remain native-owner controlled'
