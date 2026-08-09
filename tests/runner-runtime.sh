#!/usr/bin/env bash
# Behavioral tests for the metadata inventory and GitHub batch caches.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
HELPER="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh"
tmpdir="$(mktemp -d)"
snippet="$tmpdir/functions.sh"
trap 'rm -rf "$tmpdir"' EXIT

# shellcheck disable=SC1090
. "$HELPER"
for fn in github_scope_validate github_scope_base legacy_runner_scope_target fleet_inventory_invalidate \
  fleet_inventory_refresh inventory_names inventory_field inventory_count runner_pool runner_index runner_scope_target \
  runner_identity_validate github_registration_token registration_token \
  github_runner_inventory github_runner_inventory_invalidate github_runner_inventory_forget github_runner_id; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >> "$snippet"
done
# shellcheck disable=SC1090
. "$snippet"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
inc() { local f="$1" n=0; [ -f "$f" ] && n="$(cat "$f")"; printf '%s\n' "$((n+1))" > "$f"; }

RUNDIR="$tmpdir/run"
mkdir -p "$RUNDIR"
INVENTORY_FILE="$RUNDIR/fleet-inventory.tsv"
INVENTORY_ACTIVE=0
MANAGED_LABEL="net.unraid.ci-runner-farm.managed=true"
LABEL_NS="net.unraid.ci-runner-farm"
NAME_PREFIX="ci-runner"
ps_calls="$tmpdir/ps.calls"
inspect_calls="$tmpdir/inspect.calls"

docker() {
  case "$1" in
    ps)
      inc "$ps_calls"
      printf '%s\n' ci-runner-1 ci-runner-python-1 ci-runner-rust-1 ci-runner-jit-python-0123456789abcdefabcd
      ;;
    inspect)
      inc "$inspect_calls"
      if [[ "$*" == *'.Config.Env'* ]]; then
        printf '%s\n' RUNNER_SCOPE=repo REPO_URL=https://github.com/acme/legacy
      else
        cat <<'EOF'
/ci-runner-1|running|healthy|2000000000|17179869184|legacygen|<no value>|<no value>|<no value>|1|true|<no value>|<no value>|classic
/ci-runner-python-1|running|healthy|2000000000|17179869184|pygen|python|org:acme|1|1|true|1|python|classic
/ci-runner-rust-1|running|healthy|2000000000|17179869184|rustgen|rust|repo:acme/example|1|1|true|1|rust|classic
/ci-runner-jit-python-0123456789abcdefabcd|running|healthy|1000000000|2147483648|jitgen|python|org:acme|501|501|true|2|python|scaleset
EOF
      fi
      ;;
    *) fail "unexpected docker call: $*" ;;
  esac
}

fleet_inventory_refresh || fail 'inventory refresh failed'
assert_eq "$(cat "$ps_calls")" 1 'inventory did not use exactly one docker ps'
assert_eq "$(cat "$inspect_calls")" 1 'inventory did not use exactly one batched inspect'
assert_eq "$(stat -c %a "$INVENTORY_FILE")" 600 'inventory cache is not mode 0600'
assert_eq "$(inventory_count)" 4 'inventory lost managed rows'
assert_eq "$(inventory_count python)" 2 'pool filter did not use parsed metadata'
assert_eq "$(inventory_field ci-runner-1 pool)" default 'legacy runner fallback was not preserved'
assert_eq "$(inventory_field ci-runner-python-1 scope)" org:acme 'stamped scope was not authoritative'
assert_eq "$(inventory_field ci-runner-rust-1 identity)" invalid-managed 'forged repo-scoped pool identity was adopted'
runner_identity_validate ci-runner-python-1 || fail 'valid pool identity was rejected'
runner_identity_validate ci-runner-jit-python-0123456789abcdefabcd || fail 'valid scale-set JIT identity was rejected'
if runner_identity_validate ci-runner-rust-1; then fail 'invalid-managed pool identity was authorized'; fi
assert_eq "$(cat "$ps_calls")" 1 'inventory consumer rescanned docker ps'
assert_eq "$(cat "$inspect_calls")" 1 'inventory consumer rescanned docker inspect'
assert_eq "$(legacy_runner_scope_target ci-runner-1)" repo:acme/legacy 'legacy original scope was recomputed instead of recovered'

# Discovery failure must preserve the last complete cache instead of publishing
# an empty farm and authorizing duplicate provisioning or stale cleanup.
inventory_before="$(sha256sum "$INVENTORY_FILE" | awk '{print $1}')"
docker() { [ "$1" != ps ] || return 42; fail "unexpected docker call after failed ps: $*"; }
if fleet_inventory_refresh; then fail 'failed Docker discovery was published as an empty inventory'; fi
assert_eq "$(sha256sum "$INVENTORY_FILE" | awk '{print $1}')" "$inventory_before" 'failed discovery replaced the last complete inventory'

# After one teardown invalidates the shared inventory, later JIT removals fall
# back to direct labels. That path must recognize the bounded JIT identity too.
INVENTORY_ACTIVE=0
docker() {
  case "$*" in
    *"${MANAGED_LABEL%=*}"*) printf '%s\n' true ;;
    *"${LABEL_NS}.pool-index"*) printf '%s\n' 501 ;;
    *"${LABEL_NS}.pool\""*) printf '%s\n' python ;;
    *"${LABEL_NS}.scope-target"*) printf '%s\n' org:acme ;;
    *"${LABEL_NS}.identity-version"*) printf '%s\n' 2 ;;
    *"${LABEL_NS}.backend"*) printf '%s\n' scaleset ;;
    *) return 1 ;;
  esac
}
runner_identity_validate ci-runner-jit-python-0123456789abcdefabcd ||
  fail 'direct-label fallback rejected a valid scale-set JIT identity'
INVENTORY_ACTIVE=1

# Registration-token cache: two requests in one batch/scope produce one API call.
ACCESS_TOKEN=test-pat
token_calls="$tmpdir/token.calls"
gh_api() {
  inc "$token_calls"
  printf '{"token":"registration_token_123","expires_at":"2099-01-01T00:00:00Z"}'
}
assert_eq "$(github_registration_token org:acme)" registration_token_123 'registration token parse failed'
assert_eq "$(github_registration_token org:acme)" registration_token_123 'registration token cache failed'
assert_eq "$(cat "$token_calls")" 1 'registration token was not reused per scope'
[ "$(stat -c %a "$RUNDIR"/registration-token.*)" = 600 ] || fail 'registration token cache is not mode 0600'

# Runner inventory cache parses compact JSON and avoids a second list request.
runner_calls="$tmpdir/runner.calls"
GH_STATUS=""
GH_RESPONSE=""
gh_api_request() {
  inc "$runner_calls"
  GH_STATUS=200
  GH_RESPONSE='{"total_count":2,"runners":[{"id":11,"name":"devhost-ci-runner-python-1","os":"linux","status":"online","busy":false},{"id":12,"name":"devhost-ci-runner-rust-1","os":"linux","status":"online","busy":true}]}'
  return 0
}
first="$(github_runner_inventory org:acme)"
second="$(github_runner_inventory org:acme)"
assert_eq "$first" "$second" 'GitHub runner inventory cache changed content'
assert_eq "$(cat "$runner_calls")" 1 'GitHub runner inventory was not reused per scope'
assert_eq "$(github_runner_id org:acme devhost-ci-runner-rust-1)" 12 'runner name-to-id lookup failed'
github_runner_inventory_forget org:acme 11
assert_eq "$(github_runner_id org:acme devhost-ci-runner-python-1)" '' 'deleted runner id remained in batch inventory'
assert_eq "$(cat "$runner_calls")" 1 'forgetting one runner discarded the whole batch inventory'
github_runner_inventory_invalidate org:acme
github_runner_inventory org:acme >/dev/null
assert_eq "$(cat "$runner_calls")" 2 'GitHub runner inventory mutation invalidation did not force a refresh'

# Source contracts for the remaining UI invariants. Reconcile Stop behavior is
# exercised against real process groups and locks by reconcile-stop-lifecycle.sh.
grep -Fq 'fleet_inventory_refresh' "$ENGINE" || fail 'status/autoscale do not use the shared inventory'
grep -Fq 'blocked_capacity' "$ENGINE" || fail 'blocked transition capacity is not reported'
grep -Fq 'X-GitHub-Api-Version: 2026-03-10' "$ENGINE" || fail 'GitHub API version header missing'
grep -Fq 'provision_base || { err "reconcile: provisioning preflight failed' "$ENGINE" || fail 'reconcile healing bypasses provisioning preflight'
grep -Fq 'ceiling="$(pool_effective_total)"' "$ENGINE" || fail 'reconcile healing ignores fixed runtime overrides'
grep -Fq 'return "$start_rc"' "$ENGINE" || fail 'Start does not return its accumulated provisioning result'
grep -Fq 'strict_firewall_ensure || return 1' "$ENGINE" || fail 'replacement provisioning does not verify strict firewall rules'
grep -Fq 'ensure_network || return 1' "$ENGINE" || fail 'network creation failure is not propagated'
grep -Fq 'runner_authoritatively_failed "$c" || continue' "$ENGINE" || fail 'generic log errors can authorize destructive reconciliation'
grep -Fq 'github_runner_inventory_forget "$target" "$id"' "$ENGINE" || fail 'batch runner inventory is discarded after each delete'
grep -Fq 'scaleset_make_ineligible "$MIGRATION_OWNERSHIP_REVISION"' "$ENGINE" ||
  fail 'Stop does not quarantine active scale sets'
grep -Fq 'scaleset_supervisor_stop' "$ENGINE" ||
  fail 'Stop does not terminate the scale-set supervisor'
grep -Fq 'scaleset_supervisor_start' "$ENGINE" ||
  fail 'Start does not restore the scale-set supervisor'
grep -Fq 'scaleset_activate_eligible "$MIGRATION_OWNERSHIP_REVISION"' "$ENGINE" ||
  fail 'Start does not restore scale-set eligibility'
grep -Fq 'auth_credentials_configured' "$ENGINE" ||
  fail 'GitHub App credentials cannot pass Start or boot autostart'
grep -Fq 'scaleset_snapshot_refresh >/dev/null 2>&1 || true' "$ENGINE" ||
  fail 'Fleet does not materialize the current in-memory scale-set heartbeat'
grep -Fq 'pidx _routing identity backend started_at;' "$ENGINE" ||
  fail 'Fleet status does not parse the scale-set backend and start-time inventory columns'
grep -Fq '\"started_at\":\"$(printf' "$ENGINE" ||
  fail 'Fleet status does not publish live runner start times for uptime display'

# Strict isolation must verify every required rule, rather than accepting a
# partially intact tagged ruleset. Exercise the live validator with one exact
# rule missing at a time, plus its repair path.
firewall_snippet="$tmpdir/firewall-functions.sh"
for fn in strict_firewall_rules_valid strict_firewall_ensure; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >> "$firewall_snippet"
done
# shellcheck disable=SC1090
. "$firewall_snippet"
NETWORK_ISOLATION=strict
RUNNER_NETWORK=ci-runner-net
MIRROR_NAME=ci-runner-mirror
FW_TAG=ci-runner-farm
MISSING_RULE=""
APPLY_CALLS=0
log() { :; }
err() { :; }
docker() {
  if [ "$1" = network ]; then
    case "$*" in
      *Subnet*) printf '%s\n' 172.30.0.0/24 ;;
      *Gateway*) printf '%s\n' 172.30.0.1 ;;
      *) return 1 ;;
    esac
  else
    printf '%s\n' 172.30.0.2
  fi
}
iptables() {
  local args=" $* "
  [ -z "$MISSING_RULE" ] || [[ "$args" != *" --comment $MISSING_RULE "* ]]
}
firewall_apply() {
  APPLY_CALLS=$((APPLY_CALLS+1))
  [ "${REPAIR_RULES:-0}" = 1 ] && MISSING_RULE=""
}
strict_firewall_ensure || fail 'complete strict firewall ruleset was rejected'
assert_eq "$APPLY_CALLS" 0 'complete firewall ruleset was needlessly reapplied'
for suffix in mirror estab host lan10 lan172 lan192 cgnat in-estab in-drop; do
  MISSING_RULE="$FW_TAG:$suffix"
  REPAIR_RULES=0
  if strict_firewall_ensure; then fail "strict firewall accepted missing $suffix rule"; fi
done
MISSING_RULE="$FW_TAG:lan192"
REPAIR_RULES=1
APPLY_CALLS=0
strict_firewall_ensure || fail 'strict firewall did not accept a repaired ruleset'

# Exited one-job JIT containers must be reclaimed; Docker inspect alone also
# succeeds for stopped containers and cannot be the liveness predicate.
JIT="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh"
CACHE_ROOT="$tmpdir/cache"
mkdir -p "$CACHE_ROOT"
# shellcheck disable=SC1090
. "$JIT"
JIT_TEST_RUNNING=true
docker() {
  case "$1:$2" in
    inspect:--format) printf '%s\n' "$JIT_TEST_RUNNING" ;;
    *) return 1 ;;
  esac
}
jit_container_running ci-runner-jit-python-0123456789abcdefabcd ||
  fail 'running JIT container was treated as terminal'
JIT_TEST_RUNNING=false
if jit_container_running ci-runner-jit-python-0123456789abcdefabcd; then
  fail 'exited JIT container was treated as running'
fi
assert_eq "$APPLY_CALLS" 1 'strict firewall did not attempt one repair'

echo 'runner-runtime: OK'
