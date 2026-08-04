#!/usr/bin/env bash
# Behavioral regression coverage for runner-pool parsing and source contracts.
set -euo pipefail
cd "$(dirname "$0")/.."

HELPER="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh"
ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
FLEET="src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page"
SETTINGS="src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page"
POOLS_PAGE="src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page"
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
valid_v2='v2|rust|ci-rust|rust,build|3|2|5|1|4|16g;v2|python|ci-python|python,build|1|1|2|1|2|4g'
accept single '' repo
accept pools "$valid" org
[ "$POOL_RECORDS" = "$valid" ] && ok || bad 'valid records were not normalized'

POOL_BACKEND=classic RUNNER_CPUS=8 RUNNER_MEMORY=16g
accept pools "$valid_v2" org
[ "$POOL_CONFIG_VERSION" = v2 ] && ok || bad 'V2 version was not detected'
[ "$POOL_SERIALIZED_V2" = 'v2|rust|ci-rust|rust,build|3|2|5|1|4|17179869184;v2|python|ci-python|python,build|1|1|2|1|2|4294967296' ] &&
  ok || bad 'V2 canonical serialization differs'
POOL_BACKEND=scaleset
accept pools 'v2|rust|ci-pool-rust||3|0|auto|0|8|10g' org
POOL_BACKEND=classic
RUNNER_MODE=pools RUNNER_POOLS="$valid_v2" GH_SCOPE=org GH_OWNER=acme
[ "$(pool_routing_label python)" = ci-python ] && ok || bad 'explicit routing label was not preserved'
[ "$(pool_additional_labels rust)" = rust,build ] && ok || bad 'additional labels were not preserved'
[ "$(pool_effective_labels rust)" = ci-rust,rust,build ] && ok || bad 'effective labels are wrong'
[ "$(pool_cpu_milli rust)" = 4000 ] && ok || bad 'CPU claim did not normalize to milli-CPU'
[ "$(pool_memory_bytes python)" = 4294967296 ] && ok || bad 'memory claim did not normalize to bytes'
[ "$(pool_cpu_source rust)" = 4 ] && ok || bad 'CPU source provenance was lost'
[ "$(pool_config_revision)" != '' ] && ok || bad 'config revision is empty'
[ "$(pool_runner_spec_hash rust | wc -c)" -eq 65 ] && ok || bad 'runner spec hash is not SHA-256'

RUNNER_POOLS='v2|inherit|ci-inherit||1|1|2|0|inherit|inherit'
[ "$(pool_cpu_milli inherit)" = 8000 ] && ok || bad 'inherited CPU claim did not resolve'
[ "$(pool_memory_bytes inherit)" = 17179869184 ] && ok || bad 'inherited memory claim did not resolve'
[ "$(pool_cpu_source inherit)" = inherit ] && ok || bad 'inherit CPU provenance was lost'

POOL_BACKEND=scaleset RUNNER_POOLS='v2|zero|ci-zero||1|0|auto|0|1|1g'
accept pools "$RUNNER_POOLS" org
[ "$(pool_capacity_ceiling zero)" = 64 ] && ok || bad 'auto maximum did not resolve to the emergency fuse for numeric fallback'
POOL_BACKEND=classic
reject pools "$RUNNER_POOLS" org

RUNNER_MODE=pools RUNNER_POOLS="$valid" GH_SCOPE=org AUTOSCALE=true POOL_AUTOSCALE=inherit
[ "$(pool_label python)" = 'ci-pool-python' ] && ok || bad 'routing label was not derived'
[ "$(pool_configured_target rust)" = 2 ] && ok || bad 'autoscale target is not pool min'
[ "$(pool_autoscale_enabled rust; echo $?)" = 0 ] && ok || bad 'inherit did not enable every pool under the global master'
POOL_AUTOSCALE=''
if pool_autoscale_enabled rust || pool_autoscale_enabled python; then bad 'empty per-pool selection did not keep every pool fixed'; else ok; fi
[ "$(pool_configured_target rust)" = 3 ] && ok || bad 'empty per-pool selection did not use fixed capacity'
POOL_AUTOSCALE=rust
if pool_autoscale_enabled rust && ! pool_autoscale_enabled python; then ok; else bad 'explicit mixed-pool selection was not isolated'; fi
[ "$(pool_configured_target rust)" = 2 ] && [ "$(pool_configured_target python)" = 1 ] && ok || bad 'mixed auto/fixed targets are wrong'
AUTOSCALE=false
[ "$(pool_configured_target rust)" = 3 ] && ok || bad 'fixed target is not pool fixed count'
POOL_AUTOSCALE=inherit

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
reject pools 'rust|1|1|1|1;v2|python|ci-python||1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-rust||1|1|2|1|1|1g|extra' org
reject pools 'v2|Rust|ci-rust||1|1|2|1|1|1g' org
reject pools 'v2|rust|self-hosted||1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-rust|linux|1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-rust|ci-pool-python|1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-rust|build,build|1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-rust|ci-rust|1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-rust||1|1|2|1|0|1g' org
reject pools 'v2|rust|ci-rust||1|1|2|1|1|1m' org
reject pools 'v2|rust|ci-rust||1|1|2|1|01|1g' org
reject pools 'v2|rust|ci-rust||1|1|2|1|1.0000|1g' org
reject pools 'v2|rust|ci-one|shared|1|1|2|1|1|1g;v2|python|ci-two|ci-one|1|1|2|1|1|1g' org
reject pools 'v2|rust|ci-same||1|1|2|1|1|1g;v2|python|ci-same||1|1|2|1|1|1g' org
large=''
for id in a b c d e f g h; do
  rec="v2|$id|route-$id|label-$id|64|1|64|1|256|1t"
  large="${large}${large:+;}${rec}"
done
accept pools "$large" org
if pool_config_validate pools "$valid" org ''; then bad 'empty organization owner was accepted'; else ok; fi
if pool_config_validate pools "$valid" org 'bad/owner'; then bad 'unsafe organization owner was accepted'; else ok; fi
for owner in . .. bad_owner -leading trailing- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
  if pool_config_validate pools "$valid" org "$owner"; then bad "unsafe organization owner was accepted: $owner"; else ok; fi
done

# Source-level contracts filled in by later implementation tasks. Keeping them in
# this suite makes `tests/*.sh` one executable acceptance surface.
grep -q 'RUNNER_MODE="single"' "$ENGINE" && ok || bad 'engine lacks backward-compatible single mode'
grep -q 'RUNNER_POOLS' "$SETTINGS" && ok || bad 'Settings lacks the pool config source'
grep -q 'id="crf-pools-errors".*aria-live="polite"' "$POOLS_PAGE" && ok || bad 'Pools tab errors are not announced'
grep -q 'ci-pool-python' "$FLEET" "$POOLS_PAGE" "$ENGINE" && ok || bad 'derived pool selector is absent'
grep -q "action:'scale',pool,n" "$FLEET" && ok || bad 'Fleet does not send a pool-aware scale action'
grep -q 'data-crf-mutation' "$FLEET" && ok || bad 'Fleet mutations cannot be disabled on invalid config'
grep -q "case 'validate-pools'" "$EXEC" && ok || bad 'server pool validation endpoint missing'
grep -q 'scheduling routes, not trust boundaries' README.md && ok || bad 'routing/security boundary is undocumented'
grep -q 'Deploy the plugin while.*Single fleet' README.md && ok || bad 'safe single-mode activation is undocumented'
grep -q 'runs-on: ci-pool-rust' README.md && ok || bad 'Rust selector is undocumented'
grep -q 'runs-on: ci-pool-python' README.md && ok || bad 'Python selector is undocumented'
grep -q 'runs-on: ci-pool-typescript' README.md && ok || bad 'TypeScript selector is undocumented'
grep -q 'never edits workflow files in sibling repositories' README.md && ok || bad 'workflow migration ownership is undocumented'

WORKFLOW_DIR=".github/workflows"
route_jobs="$(awk '/^[[:space:]]*runs-on:/ { n++ } END { print n + 0 }' "$WORKFLOW_DIR"/*.yml)"
[ "$route_jobs" -eq 6 ] && ok || bad "expected 6 workflow jobs with runner routes, found $route_jobs"
ops_routes="$(awk '/^[[:space:]]*runs-on:.*ci-pool-ops/ { n++ } END { print n + 0 }' "$WORKFLOW_DIR"/*.yml)"
[ "$ops_routes" -eq 6 ] && ok || bad "expected 6 trusted ops-pool routes, found $ops_routes"
hosted_fallbacks="$(awk '/^[[:space:]]*runs-on:.*ubuntu-latest/ { n++ } END { print n + 0 }' "$WORKFLOW_DIR"/*.yml)"
[ "$hosted_fallbacks" -eq 6 ] && ok || bad "expected 6 hosted fork fallbacks, found $hosted_fallbacks"
owner_guards="$(awk '/^[[:space:]]*runs-on:.*github.repository_owner.*dinglebear-ai/ { n++ } END { print n + 0 }' "$WORKFLOW_DIR"/*.yml)"
[ "$owner_guards" -eq 6 ] && ok || bad "expected 6 dinglebear-ai owner guards, found $owner_guards"
same_repo_guards="$(awk '/^[[:space:]]*runs-on:.*github.event.pull_request.head.repo.full_name == github.repository/ { n++ } END { print n + 0 }' "$WORKFLOW_DIR"/*.yml)"
[ "$same_repo_guards" -eq 6 ] && ok || bad "expected 6 same-repository PR guards, found $same_repo_guards"
if grep -RInE '^[[:space:]]*runs-on:[[:space:]]*(ubuntu-latest|self-hosted|ci-pool-ops)[[:space:]]*$' "$WORKFLOW_DIR"; then
  bad 'workflow has an unguarded direct runner selector'
else
  ok
fi

if grep -qi 'queue-aware autoscal' README.md src/usr/local/emhttp/plugins/ci-runner-farm/README.md; then
  bad 'documentation still claims queue-aware autoscaling'
else
  ok
fi

printf 'runner-pools: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
