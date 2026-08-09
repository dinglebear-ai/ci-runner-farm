#!/usr/bin/env bash
# Regression coverage for the Fleet tab's autoscale controls. These checks stay
# Docker-free: they exercise the config writer directly and assert that the
# autoscaler retains its private scaling path.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The autoscaler must bypass the manual-mode guard, while the public command
# still delegates to the shared implementation in fixed mode.
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

# Extract just the small, filesystem-only setter so sourcing it cannot dispatch
# the full runner manager.
sed -n '/^cmd_autoscale_set_max()/,/^}/p' "$ENGINE" > "$tmpdir/setter.sh"
# shellcheck disable=SC1091 # extracted from the tested engine above
. "$tmpdir/setter.sh"
log() { :; }
err() { :; }
export PLUGIN='ci-runner-farm'
export CFGDIR="$tmpdir/config"
export CFG="$CFGDIR/ci-runner-farm.cfg"
mkdir -p "$CFGDIR"
printf 'GH_OWNER="example"\nAUTOSCALE_MIN="2"\nAUTOSCALE_MAX="4"\n' > "$CFG"
export AUTOSCALE=true
export AUTOSCALE_MIN=2

cmd_autoscale_set_max 5 || fail 'valid autoscale max rejected'
grep -q '^GH_OWNER="example"$' "$CFG" || fail 'setter replaced unrelated Settings content'
[ "$(awk -F'"' '/^AUTOSCALE_MAX=/{value=$2} END{print value}' "$CFG")" = 5 ] || fail 'last autoscale max was not persisted'
if cmd_autoscale_set_max 1; then fail 'max below min was accepted'; fi
export AUTOSCALE=false
if cmd_autoscale_set_max 6; then fail 'autoscale max was changed while autoscaling was off'; fi

echo 'autoscale-controls: OK'
