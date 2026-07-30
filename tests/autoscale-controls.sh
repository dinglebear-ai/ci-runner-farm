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
sed -n '/^cmd_scale()/,/^}/p' "$ENGINE" | grep -q 'cmd_scale_internal "\$1"' || fail 'manual scale no longer delegates to internal scaler'
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
current_count() { echo 5; }
called=''
cmd_scale_internal() { called="$1"; }
export AUTOSCALE=true
export AUTOSCALE_MAX=6
cmd_scale 6 || fail 'autoscale manual scale-up rejected'
[ "$called" = 6 ] || fail 'autoscale manual scale-up did not reach internal scaler'
if cmd_scale 5; then fail 'autoscale manual same-size request accepted'; fi
if cmd_scale 7; then fail 'autoscale manual scale above max accepted'; fi

echo 'autoscale-controls: OK'
