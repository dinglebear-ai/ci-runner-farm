#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. tests/lib/assert.sh

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
snippet="$TEST_ROOT/functions.sh"
for fn in \
  fixed_quiesce_dir_ensure \
  fixed_quiesce_marker \
  github_runner_labels_replace \
  fixed_quiesce_runner \
  fixed_quiesce_restore \
  fixed_quiesce_forget \
  reconcile_stale_runners; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >> "$snippet"
done
# shellcheck disable=SC1090
. "$snippet"

CFGDIR="$TEST_ROOT/cfg"
RUNDIR="$TEST_ROOT/run"
mkdir -p "$CFGDIR" "$RUNDIR"
ACCESS_TOKEN=test-token
GH_STATUS=
GH_RESPONSE=
runner_identity_validate(){ [[ "${1:-}" =~ ^ci-runner-[a-z0-9-]+$ ]]; }
runner_scope_target(){ printf 'org:dinglebear-ai\n'; }
github_scope_validate(){ return 0; }
github_scope_base(){ printf '/orgs/dinglebear-ai\n'; }
host(){ printf 'tootie\n'; }
github_runner_id(){ printf '42\n'; }
github_runner_inventory_invalidate(){ :; }
runner_pool(){ printf 'rust\n'; }
pool_effective_labels(){ printf 'ci-pool-rust,unraid\n'; }
log(){ :; }
err(){ printf '%s\n' "$*" >&2; }
gh_api_request(){
  printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >> "$TEST_ROOT/api-calls"
  GH_STATUS=200
  GH_RESPONSE='{"total_count":4}'
}

fixed_quiesce_runner ci-runner-rust-4
marker="$CFGDIR/fixed-quiesced/ci-runner-rust-4.state"
[ -f "$marker" ] || crf_fail 'quiesce marker was not persisted'
crf_assert_file_mode "$CFGDIR/fixed-quiesced" 700
crf_assert_file_mode "$marker" 600
crf_assert_eq 1 "$(wc -l < "$TEST_ROOT/api-calls")" 'first quiesce API call count'
grep -Fxq 'PUT|/orgs/dinglebear-ai/actions/runners/42/labels|{"labels":["crf-retiring"]}' "$TEST_ROOT/api-calls" ||
  crf_fail 'quiesce did not replace custom labels with the retirement marker'
fixed_quiesce_runner ci-runner-rust-4
crf_assert_eq 1 "$(wc -l < "$TEST_ROOT/api-calls")" 'idempotent quiesce API call count'
fixed_quiesce_restore ci-runner-rust-4
[ ! -e "$marker" ] || crf_fail 'restored runner kept its quiesce marker'
grep -Fxq 'PUT|/orgs/dinglebear-ai/actions/runners/42/labels|{"labels":["ci-pool-rust","unraid"]}' "$TEST_ROOT/api-calls" ||
  crf_fail 'restore did not reapply the configured pool labels'
fixed_quiesce_runner ci-runner-rust-4
fixed_quiesce_forget ci-runner-rust-4
[ ! -e "$marker" ] || crf_fail 'runner removal did not forget the quiesce marker'

echo 'fixed-drain-labels: OK'

# Four running Rust identities with target two must designate exactly the two
# highest identities as surplus. Busy jobs stay alive, but only those two lose
# eligibility; lower identities must not be quiesced.
rm -f "$TEST_ROOT/quiesced" "$TEST_ROOT/restored" "$TEST_ROOT/removed"
(
  # shellcheck disable=SC1090
  . "$snippet"
  validate_runtime_config(){ return 0; }
  cleanup_pool_runtime_state(){ :; }
  fleet_inventory_refresh(){ return 0; }
  crf_confgen_prepare(){ :; }
  pool_mode_enabled(){ return 0; }
  count_pool_missing_capacity(){ printf '0\n'; }
  managed_names(){
    printf '%s\n' ci-runner-rust-1 ci-runner-rust-2 ci-runner-rust-3 ci-runner-rust-4
  }
  runner_identity_validate(){ return 0; }
  runner_pool(){ printf 'rust\n'; }
  pool_record(){ return 0; }
  pool_records(){ printf 'rust|record\n'; }
  pool_autoscale_enabled(){ return 1; }
  pool_effective_target(){ printf '2\n'; }
  current_count(){ printf '4\n'; }
  inventory_field(){ printf 'running\n'; }
  runner_credential_handoff_stalled(){ return 1; }
  runner_state(){ printf 'busy\n'; }
  runner_authoritatively_failed(){ return 1; }
  fixed_quiesce_runner(){ printf '%s\n' "$1" >> "$TEST_ROOT/quiesced"; }
  fixed_quiesce_restore(){ printf '%s\n' "$1" >> "$TEST_ROOT/restored"; }
  remove_runner(){ printf '%s\n' "$1" >> "$TEST_ROOT/removed"; return 1; }
  remove_runner_force(){ printf '%s\n' "$1" >> "$TEST_ROOT/removed"; return 1; }
  crf_confgen(){ printf 'current\n'; }
  runner_confgen(){ printf 'current\n'; }
  start_one_missing_desired(){ :; }
  log(){ :; }
  err(){ printf '%s\n' "$*" >&2; }
  GH_OWNER=dinglebear-ai
  reconcile_stale_runners
)
printf '%s\n' ci-runner-rust-4 ci-runner-rust-3 > "$TEST_ROOT/expected-quiesced"
printf '%s\n' ci-runner-rust-2 ci-runner-rust-1 > "$TEST_ROOT/expected-restored"
diff -u "$TEST_ROOT/expected-quiesced" "$TEST_ROOT/quiesced"
diff -u "$TEST_ROOT/expected-restored" "$TEST_ROOT/restored"
[ ! -e "$TEST_ROOT/removed" ] || crf_fail 'busy excess runner was removed'

echo 'fixed-drain-selection: OK'

# A failed label replacement must preserve even an apparently idle runner. The
# next pass retries quiescing instead of risking a new assignment racing removal.
rm -f "$TEST_ROOT/removed"
(
  # shellcheck disable=SC1090
  . "$snippet"
  validate_runtime_config(){ return 0; }
  cleanup_pool_runtime_state(){ :; }
  fleet_inventory_refresh(){ return 0; }
  crf_confgen_prepare(){ :; }
  pool_mode_enabled(){ return 0; }
  count_pool_missing_capacity(){ printf '0\n'; }
  managed_names(){ printf '%s\n' ci-runner-rust-1 ci-runner-rust-2; }
  runner_identity_validate(){ return 0; }
  runner_pool(){ printf 'rust\n'; }
  pool_record(){ return 0; }
  pool_records(){ printf 'rust|record\n'; }
  pool_autoscale_enabled(){ return 1; }
  pool_effective_target(){ printf '1\n'; }
  current_count(){ printf '2\n'; }
  inventory_field(){ printf 'running\n'; }
  runner_credential_handoff_stalled(){ return 1; }
  runner_state(){ printf 'idle\n'; }
  runner_authoritatively_failed(){ return 1; }
  fixed_quiesce_runner(){ return 1; }
  fixed_quiesce_restore(){ return 0; }
  remove_runner(){ printf '%s\n' "$1" > "$TEST_ROOT/removed"; }
  remove_runner_force(){ printf '%s\n' "$1" > "$TEST_ROOT/removed"; }
  crf_confgen(){ printf 'current\n'; }
  runner_confgen(){ printf 'current\n'; }
  start_one_missing_desired(){ :; }
  log(){ :; }
  err(){ :; }
  GH_OWNER=dinglebear-ai
  reconcile_stale_runners
)
[ ! -e "$TEST_ROOT/removed" ] || crf_fail 'runner was removed after quiescing failed'

echo 'fixed-drain-fail-closed: OK'
