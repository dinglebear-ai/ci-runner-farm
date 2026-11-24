#!/usr/bin/env bash
# Named-pool autoscaling: each pool grows, floors and shrinks within its own
# min/max/idle values and never counts or removes another pool's runners.
# shellcheck disable=SC2034  # the sourced engine reads these through dynamic scope
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
fail() { printf 'POOL AUTOSCALE FAIL: %s\n' "$*" >&2; exit 1; }

CI_PROVIDER=github GH_SCOPE=org GH_OWNER=example RUNNER_MODE=pools IMAGE_AUTOUPDATE=false
AUTOSCALE=true AUTOSCALE_MIN=9 AUTOSCALE_MAX=9 AUTOSCALE_MIN_IDLE=9 AUTOSCALE_STEP=2 AUTOSCALE_IDLE_GRACE=1
build='v3|build|ci-build|linux|1|1|3|1|2|4g|builtin'
large='v3|large|ci-large|linux|1|0|2|1|4|8g|builtin'
RUNNER_POOLS="$build;$large"
validate_runner_mode || fail "pools with autoscale were rejected: $POOL_CONFIG_ERROR"

fx_names="$tmp/names" fx_busy="$tmp/busy" fx_scales="$tmp/scales" fx_removed="$tmp/removed"
owned_managed_names() { sort -V "$fx_names"; }
managed_runner_snapshot() { printf '%064d|github|runner|%s|gen\n' 1 "${1##*-}"; }
runner_state() { if grep -qx "$1" "$fx_busy"; then echo busy; else echo idle; fi; }
cmd_scale() { printf '%s %s %s\n' "$CRF_SCALE_POOL" "$NAME_PREFIX" "$1" >> "$fx_scales"; }
remove_runner() { echo "$1" >> "$fx_removed"; grep -vx "$1" "$fx_names" > "$tmp/n" || true; mv "$tmp/n" "$fx_names"; }
crf_storage_pressure_cleanup() { :; }
reap_dead_runners() { :; }
heal_poisoned_runners() { :; }
reconcile_stale_runners() { :; }
fixture() { printf '%s\n' "$@" > "$fx_names"; : > "$fx_busy"; : > "$fx_scales"; : > "$fx_removed"; rm -f "$RUNDIR"/autoscale.state*; }

# A busy pool grows by STEP up to its own max; a pool with an idle runner holds.
fixture ci-runner-build-1 ci-runner-large-1
echo ci-runner-build-1 > "$fx_busy"
autoscale_tick || fail 'tick failed'
[ "$(cat "$fx_scales")" = 'build ci-runner-build 3' ] || fail "unexpected growth: $(cat "$fx_scales")"

# A pool at its max does not grow even when every runner is busy.
fixture ci-runner-build-1 ci-runner-build-2 ci-runner-build-3 ci-runner-large-1
printf '%s\n' ci-runner-build-1 ci-runner-build-2 ci-runner-build-3 > "$fx_busy"
autoscale_tick || fail 'tick at max failed'
[ ! -s "$fx_scales" ] || fail "grew past pool max: $(cat "$fx_scales")"

# A pool below its own min is restored to that floor.
fixture ci-runner-large-1
autoscale_tick || fail 'floor tick failed'
[ "$(cat "$fx_scales")" = 'build ci-runner-build 1' ] || fail "floor not restored: $(cat "$fx_scales")"

# Shrink removes only the idle pool's highest slots and stops at its min.
RUNNER_POOLS='v3|build|ci-build|linux|1|1|3|0|2|4g|builtin;'"$large"
fixture ci-runner-build-1 ci-runner-build-2 ci-runner-build-3 ci-runner-large-1 ci-runner-large-2
echo ci-runner-large-1 > "$fx_busy"
autoscale_tick || fail 'shrink tick failed'
[ "$(cat "$fx_removed")" = $'ci-runner-build-3\nci-runner-build-2' ] || fail "wrong runners removed: $(cat "$fx_removed")"
[ -f "$RUNDIR/autoscale.state.build" ] && [ -f "$RUNDIR/autoscale.state.large" ] || fail 'anti-flap state is not per pool'

# Manual scale stays unavailable in pool mode; Start launches each pool's min.
unset -f cmd_scale
# shellcheck source=/dev/null
source <(sed -n '/^cmd_scale() {/,/^}/p' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh)
if cmd_scale 2 2>/dev/null; then fail 'manual scale accepted in pool mode'; fi
[ "$(pool_configured_target build)" = 1 ] && [ "$(pool_configured_target large)" = 0 ] || fail 'start target is not pool min'

echo 'pool-autoscale: per-pool growth, max, floor, shrink and manual-scale guard passed'
