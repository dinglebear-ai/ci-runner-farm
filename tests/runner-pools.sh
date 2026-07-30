#!/usr/bin/env bash
# Behavioral regression coverage for runner-pool parsing and source contracts.
set -euo pipefail
cd "$(dirname "$0")/.."

HELPER="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh"
ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
FLEET="src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page"
SETTINGS="src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page"
EXEC="src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php"

# shellcheck disable=SC1090
. "$HELPER"
GH_OWNER=acme

pass=0
fail=0
ok() { pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=$((fail+1)); }
accept() {
  if pool_config_validate "$1" "$2" "$3"; then ok; else bad "expected valid: mode=$1 pools=$2 scope=$3 ($POOL_CONFIG_ERROR)"; fi
}
reject() {
  if pool_config_validate "$1" "$2" "$3"; then bad "expected rejection: mode=$1 pools=$2 scope=$3"; else ok; fi
}

valid='rust|3|2|5|1;python|1|1|2|1;typescript|1|1|2|1'
accept single '' repo
accept pools "$valid" org
[ "$POOL_RECORDS" = "$valid" ] && ok || bad 'valid records were not normalized'

RUNNER_MODE=pools RUNNER_POOLS="$valid" GH_SCOPE=org AUTOSCALE=true
[ "$(pool_label python)" = 'ci-pool-python' ] && ok || bad 'routing label was not derived'
[ "$(pool_configured_target rust)" = 2 ] && ok || bad 'autoscale target is not pool min'
AUTOSCALE=false
[ "$(pool_configured_target rust)" = 3 ] && ok || bad 'fixed target is not pool fixed count'

RUNNER_MODE=single RUNNER_COUNT=4 RUNNER_LABELS='self-hosted,unraid,build'
AUTOSCALE_MIN=2 AUTOSCALE_MAX=16 AUTOSCALE_MIN_IDLE=2 GH_SCOPE=repo
[ "$(pool_records)" = 'default|4|2|16|2' ] && ok || bad 'single mode did not synthesize the legacy pool'
[ "$(pool_label default)" = "$RUNNER_LABELS" ] && ok || bad 'single mode did not preserve legacy labels'

reject broken "$valid" org
reject pools '' org
reject pools "$valid" repo
reject pools 'Rust|1|1|1|1' org
reject pools 'default|1|1|1|1' org
reject pools 'invalid|1|1|1|1' org
reject pools 'rust-|1|1|1|1' org
reject pools '-rust|1|1|1|1' org
reject pools 'r/ust|1|1|1|1' org
reject pools 'rust dev|1|1|1|1' org
reject pools $'rust|1|1|1|1\npython|1|1|1|1' org
reject pools 'rust|1|1|1' org
reject pools 'rust|1|1|1|1|extra' org
reject pools 'rust|1|1|1|1|' org
reject pools 'rust|1|1|1|1||' org
reject pools 'rust||1|1|1' org
reject pools 'rust|01|1|1|1' org
reject pools 'rust|-1|1|1|1' org
reject pools 'rust|1e2|1|1|1' org
reject pools 'rust|999999999999999999999|1|1|1' org
reject pools 'rust|1|3|2|1' org
reject pools 'rust|1|1|2|3' org
reject pools 'rust|1|1|1|1;rust|1|1|1|1' org
reject pools 'rust|1|1|1|1;' org
reject pools ';rust|1|1|1|1' org
reject pools 'rust|1|1|1|1;;python|1|1|1|1' org
reject pools 'a|1|1|1|1;b|1|1|1|1;c|1|1|1|1;d|1|1|1|1;e|1|1|1|1;f|1|1|1|1;g|1|1|1|1;h|1|1|1|1;i|1|1|1|1' org
reject pools 'a|64|1|64|1;b|1|1|1|1' org
reject pools 'a|1|1|64|1;b|1|1|1|1' org
if pool_config_validate pools "$valid" org ''; then bad 'empty organization owner was accepted'; else ok; fi
if pool_config_validate pools "$valid" org 'bad/owner'; then bad 'unsafe organization owner was accepted'; else ok; fi
for owner in . .. bad_owner -leading trailing- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
  if pool_config_validate pools "$valid" org "$owner"; then bad "unsafe organization owner was accepted: $owner"; else ok; fi
done

# Source-level contracts filled in by later implementation tasks. Keeping them in
# this suite makes `tests/*.sh` one executable acceptance surface.
grep -q 'RUNNER_MODE="single"' "$ENGINE" && ok || bad 'engine lacks backward-compatible single mode'
grep -q 'RUNNER_POOLS' "$SETTINGS" && ok || bad 'Settings lacks the pool config source'
grep -q 'id="crf-pools-errors".*aria-live="polite"' "$SETTINGS" && ok || bad 'Settings pool errors are not announced'
grep -q 'ci-pool-python' "$FLEET" "$SETTINGS" "$ENGINE" && ok || bad 'derived pool selector is absent'
grep -q "action:'scale',pool,n" "$FLEET" && ok || bad 'Fleet does not send a pool-aware scale action'
grep -q 'data-crf-mutation' "$FLEET" && ok || bad 'Fleet mutations cannot be disabled on invalid config'
grep -q "case 'validate-pools'" "$EXEC" && ok || bad 'server pool validation endpoint missing'
grep -q 'scheduling routes, not trust boundaries' README.md && ok || bad 'routing/security boundary is undocumented'
grep -q 'Deploy the plugin while.*Single fleet' README.md && ok || bad 'safe single-mode activation is undocumented'
grep -q 'runs-on: \[self-hosted, ci-pool-rust\]' README.md && ok || bad 'Rust selector is undocumented'
grep -q 'runs-on: \[self-hosted, ci-pool-python\]' README.md && ok || bad 'Python selector is undocumented'
grep -q 'runs-on: \[self-hosted, ci-pool-typescript\]' README.md && ok || bad 'TypeScript selector is undocumented'
grep -q 'never edits workflow files in sibling repositories' README.md && ok || bad 'workflow migration ownership is undocumented'
if grep -qi 'queue-aware autoscal' README.md src/usr/local/emhttp/plugins/ci-runner-farm/README.md; then
  bad 'documentation still claims queue-aware autoscaling'
else
  ok
fi

printf 'runner-pools: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
