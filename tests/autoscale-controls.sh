#!/usr/bin/env bash
# Regression coverage for the Fleet tab's autoscale controls. These checks stay
# Docker-free: they exercise the config writer directly and assert that the
# autoscaler retains its private scaling path.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The autoscaler must bypass the manual scale-up guard, while the public command
# delegates to the shared implementation in fixed and autoscale modes.
# shellcheck disable=SC2016 # Match the literal shell variable in the source.
grep -q 'cmd_scale_internal "\$floor"' "$ENGINE" || fail 'autoscale floor does not use internal scaler'
# shellcheck disable=SC2016 # Match the literal shell variable in the source.
grep -q 'cmd_scale_internal "\$target"' "$ENGINE" || fail 'autoscale demand growth does not use internal scaler'
# shellcheck disable=SC2016 # Match the literal shell variable in the source.
sed -n '/^cmd_scale()/,/^}/p' "$ENGINE" | grep -q 'cmd_scale_internal "\$target"' || fail 'manual scale no longer delegates to internal scaler'
# shellcheck disable=SC2016 # Match the literal guard expression in the source.
if sed -n '/^cmd_scale_internal()/,/^}/p' "$ENGINE" | grep -q '\[ "\$AUTOSCALE"'; then
  fail 'internal scaler is still guarded by autoscale mode'
fi

# The manual Autoscale path must allow only scale-up within the configured max.
sed -n '/^cmd_scale()/,/^}/p' "$ENGINE" | grep -q 'manual scale with Autoscaling on can only add runners' || fail 'autoscale scale-up guard missing'
sed -n '/^cmd_scale()/,/^}/p' "$ENGINE" | grep -q 'exceeds autoscale max' || fail 'autoscale max guard missing'

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -n '/^cmd_scale()/,/^}/p' "$ENGINE" > "$tmp"
# shellcheck disable=SC1090,SC1091 # extracted from the tested engine above
. "$tmp"
err() { :; }
log() { :; }
validate_runtime_config() { return 0; }
pool_mode_enabled() { return 1; }
current_count() { echo 5; }
called=''
cmd_scale_internal() { called="$1"; }
RUNDIR="$(mktemp -d)"
trap 'rm -f "$tmp"; rm -rf "$RUNDIR"' EXIT
export AUTOSCALE=true
export AUTOSCALE_MAX=6
cmd_scale 6 || fail 'autoscale manual scale-up rejected'
[ "$called" = 6 ] || fail 'autoscale manual scale-up did not reach internal scaler'
if cmd_scale 5; then fail 'autoscale manual same-size request accepted'; fi
if cmd_scale 7; then fail 'autoscale manual scale above max accepted'; fi

# Pool mode passes the selected pool and applies that pool's ceiling.
pool_mode_enabled() { return 0; }
pool_record() { [ "$1" = python ]; }
pool_max() { echo 8; }
current_count() { echo 3; }
pool_state_generation() { echo test; }
called=''
cmd_scale_internal() { called="$1:$2"; }
cmd_scale python 6 || fail 'pool autoscale manual scale-up rejected'
[ "$called" = python:6 ] || fail 'pool autoscale scale-up targeted the wrong pool'
if cmd_scale python 9; then fail 'pool autoscale scale above pool max accepted'; fi

# Fixed pool scaling persists an override and starts the drain worker when busy
# excess capacity prevents the immediate target from being reached.
AUTOSCALE=false
pool_records() { echo 'python|3|1|8|1'; }
pool_effective_target() { echo 3; }
reconcile_called=0
reconcile_start() { reconcile_called=1; }
called=''
cmd_scale_internal() { called="$1:$2"; }
cmd_scale python 1 || fail 'fixed pool scale-down rejected'
[ "$called" = python:1 ] || fail 'fixed scale targeted the wrong pool'
[ "$reconcile_called" = 1 ] || fail 'busy fixed scale-down did not start persistent reconciliation'
[ "$(cat "$RUNDIR/scale-override.python.test")" = 1 ] || fail 'fixed runtime override was not persisted'

# Pool ticks are globally bounded and rotated so the first configured pool
# cannot monopolize every cycle.
grep -q 'AUTOSCALE_ADD_BUDGET=8' "$ENGINE" || fail 'pool autoscale additions are not bounded per tick'
grep -q 'AUTOSCALE_REMOVE_BUDGET=2' "$ENGINE" || fail 'pool autoscale removals are not bounded per tick'
grep -q 'autoscale.cursor' "$ENGINE" || fail 'pool autoscale evaluation does not rotate'

# A failed legacy autoscale growth must remain a failed tick and must not reset
# the grace-state file as though capacity had been created.
tick_tmp="$(mktemp)"
sed -n '/^autoscale_tick()/,/^}/p' "$ENGINE" > "$tick_tmp"
# shellcheck disable=SC1090,SC1091 # extracted from the tested engine above
. "$tick_tmp"
validate_runtime_config() { return 0; }
cleanup_pool_runtime_state() { :; }
fleet_inventory_refresh() { INVENTORY_ACTIVE=1; }
reap_dead_runners() { :; }
pool_mode_enabled() { return 1; }
current_count() { echo 0; }
busy_count() { echo 0; }
autoscale_floor() { echo 2; }
cmd_scale_internal() { return 1; }
reconcile_stale_runners() { :; }
INVENTORY_ACTIVE=1
AUTOSCALE=true
AUTOSCALE_MIN_IDLE=1
AUTOSCALE_MAX=4
AUTOSCALE_STEP=1
printf '7\n' > "$RUNDIR/autoscale.state"
if autoscale_tick; then fail 'legacy autoscale masked a scale-up failure'; fi
[ "$(cat "$RUNDIR/autoscale.state")" = 7 ] || fail 'failed autoscale growth reset grace state'
rm -f "$tick_tmp"

echo 'autoscale-controls: OK'
