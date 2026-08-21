#!/usr/bin/env bash
# Behavioral coverage for fixed-runner recycle cleanup and protected credential handoff.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
RUNTIME="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-runtime.sh"
tmpdir="$(mktemp -d)"
snippet="$tmpdir/functions.sh"
trap 'rm -rf "$tmpdir"' EXIT

for fn in runner_registration_secret_clear recreate_runner; do
  sed -n "/^${fn}()/,/^}/p" "$ENGINE" >>"$snippet"
done
# shellcheck disable=SC1090
. "$RUNTIME"
# shellcheck disable=SC1090
. "$snippet"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }

state="$tmpdir/state"
mkdir -p "$state"
current_id_file="$state/current-id"
cleanup_log="$state/cleanup"
lock_log="$state/locks"
handoff_log="$state/handoff"
invalidate_log="$state/invalidate"
out="$state/out"

ACCESS_TOKEN=test-token
GH_SCOPE=org
GH_OWNER=acme
IMAGE_SOURCE=builtin
BUILD_MODE=ok
RUN_RESULT=ok
HANDOFF_RESULT=ok
IMAGE_AVAILABLE=true
SUSPEND_RESULT=ok
RESUME_RESULT=ok

runner_identity_validate() { return 0; }
runner_index() { printf '1\n'; }
runner_pool() { printf 'default\n'; }
pool_mode_enabled() { return 1; }
repo_for_index() { printf 'acme/example\n'; }
provision_base() { return 0; }
pool_record() { return 0; }
runner_state() { printf 'idle\n'; }
deregister_runner_api() { return 0; }
remove_runner_container() { return 0; }
remove_runner_force() { return 0; }
log() { :; }

build_args() {
  CRF_REGISTRATION_SECRET=registration-secret
  ARGS=(--name "$2" test-image)
  if [ "$BUILD_MODE" = bad-index ]; then CRF_IMAGE_ARG_INDEX=99
  else CRF_IMAGE_ARG_INDEX=2; fi
}

fleet_lock_suspend() {
  printf 'suspend\n' >>"$lock_log"
  [ "$SUSPEND_RESULT" = ok ]
}

fleet_lock_resume() {
  printf 'resume\n' >>"$lock_log"
  [ "$RESUME_RESULT" = ok ]
}

runner_secret_inject() {
  printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >>"$handoff_log"
  case "$HANDOFF_RESULT" in
    ok) return 0 ;;
    fail) return 1 ;;
    race) printf 'concurrent-replacement-id\n' >"$current_id_file"; return 0 ;;
    *) return 2 ;;
  esac
}

github_runner_inventory_invalidate() { printf '%s\n' "$1" >>"$invalidate_log"; }

docker() {
  case "${1:-}:${2:-}" in
    image:inspect)
      [ "$IMAGE_AVAILABLE" = true ]
      ;;
    run:*)
      if [ "$RUN_RESULT" = fail ]; then
        printf 'partial-container-id\n' >"$current_id_file"
        return 1
      fi
      printf 'created-container-id\n' >"$current_id_file"
      printf 'created-container-id\n'
      ;;
    inspect:--format)
      [ -f "$current_id_file" ] && cat "$current_id_file"
      ;;
    stop:-t)
      printf 'stop|%s|%s\n' "${3:-}" "${4:-}" >>"$cleanup_log"
      return "${DOCKER_STOP_RC:-0}"
      ;;
    rm:-f)
      local target="${3:-}"
      printf '%s\n' "$target" >>"$cleanup_log"
      if [ -f "$current_id_file" ]; then
        local current
        current="$(cat "$current_id_file")"
        if [ "$target" = ci-runner-1 ] || [ "$target" = "$current" ]; then
          command rm -f "$current_id_file"
        fi
      fi
      return 0
      ;;
    rm:ci-runner-1)
      printf 'remove|%s\n' "${2:-}" >>"$cleanup_log"
      return 0
      ;;
    pull:*) return 0 ;;
    *) printf 'unexpected docker call: %s\n' "$*" >>"$state/unexpected"; return 99 ;;
  esac
}

reset_case() {
  rm -f "$state"/*
  BUILD_MODE=ok
  RUN_RESULT=ok
  HANDOFF_RESULT=ok
  IMAGE_AVAILABLE=true
  SUSPEND_RESULT=ok
  RESUME_RESULT=ok
  unset CRF_REGISTRATION_SECRET CRF_IMAGE_ARG_INDEX
  ARGS=()
}

expect_failure() {
  local label="$1" rc
  set +e
  recreate_runner ci-runner-1 force >"$out"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded"
}

# Any validation failure after token minting must scrub the credential.
reset_case
BUILD_MODE=bad-index
expect_failure 'invalid image index'
assert_contains "$out" 'replacement image argument is unavailable' 'invalid image index error missing'
assert_eq "${CRF_REGISTRATION_SECRET:-}" '' 'invalid image index retained registration credential'

# A failed Docker start may leave a named partial container. Clean it before returning.
reset_case
RUN_RESULT=fail
expect_failure 'failed replacement start'
assert_contains "$cleanup_log" 'ci-runner-1' 'failed start did not clean the partial named container'
[ ! -e "$current_id_file" ] || fail 'failed start left a partial container behind'
assert_eq "${CRF_REGISTRATION_SECRET:-}" '' 'failed start retained registration credential'
[ ! -e "$lock_log" ] || fail 'failed start released a fleet lock before a container existed'

# The long credential handoff runs without the fleet lock, then reacquires it.
# Failure cleanup targets the exact created container ID, never a reused name.
reset_case
HANDOFF_RESULT=fail
expect_failure 'credential handoff'
assert_eq "$(tr '\n' ' ' <"$lock_log")" 'suspend resume ' 'credential handoff did not suspend and resume the fleet lock'
assert_contains "$handoff_log" 'ci-runner-1|registration-secret|created-container-id' 'credential handoff did not target the exact created container'
assert_contains "$cleanup_log" 'created-container-id' 'credential handoff failure did not remove the created container ID'
assert_eq "${CRF_REGISTRATION_SECRET:-}" '' 'credential handoff failure retained registration credential'

# A successful handoff leaves the exact created container running and invalidates inventory.
reset_case
recreate_runner ci-runner-1 force >"$out"
assert_contains "$out" '"ok":true' 'successful recycle did not return success'
assert_eq "$(tr '\n' ' ' <"$lock_log")" 'suspend resume ' 'successful handoff did not suspend and resume the fleet lock'
[ ! -e "$cleanup_log" ] || fail 'successful recycle unexpectedly removed a container'
assert_eq "$(cat "$current_id_file")" 'created-container-id' 'successful recycle lost the created container'
assert_contains "$invalidate_log" 'org:acme' 'successful recycle did not invalidate GitHub inventory'
assert_eq "${CRF_REGISTRATION_SECRET:-}" '' 'successful recycle retained registration credential'

# If another operator replaces the runner while the lock is released, do not
# delete that newer container when the original handoff finishes.
reset_case
HANDOFF_RESULT=race
expect_failure 'concurrent replacement'
assert_contains "$out" 'replacement changed during credential handoff' 'concurrent replacement was not detected'
[ ! -e "$cleanup_log" ] || fail 'concurrent replacement cleanup targeted the newer container'
assert_eq "$(cat "$current_id_file")" 'concurrent-replacement-id' 'concurrent replacement was deleted or overwritten'
assert_eq "${CRF_REGISTRATION_SECRET:-}" '' 'concurrent replacement retained registration credential'

# Production classic runner creation must stay behind the shared runtime boundary.
if grep -Fq 'docker run "${ARGS[@]}" >/dev/null' "$ENGINE"; then fail 'classic runner still owns a raw docker run'; fi
grep -Fq 'crf_runtime_run_prepared' "$ENGINE" || fail 'classic runner bypasses shared runtime launch'

# Shared runtime rejects incomplete/unsafe mutation requests before Docker.
reset_case
ARGS=()
if crf_runtime_run_prepared; then fail 'shared runtime accepted empty prepared argv'; fi
if crf_runtime_force_remove ""; then fail 'shared runtime accepted empty force-remove identity'; fi
if crf_runtime_stop_remove ci-runner-1 nope; then fail 'shared runtime accepted nonnumeric stop timeout'; fi
if crf_runtime_stop_remove ci-runner-1 301; then fail 'shared runtime accepted oversized stop timeout'; fi
[ ! -e "$state/unexpected" ] || fail 'invalid runtime request reached Docker'

# Shared runtime graceful teardown preserves the legacy 30-second stop then remove sequence.
reset_case
crf_runtime_stop_remove ci-runner-1 30 || fail 'shared runtime graceful stop/remove failed'
assert_eq "$(tr '\n' ' ' <"$cleanup_log")" 'stop|30|ci-runner-1 remove|ci-runner-1 ' 'shared runtime graceful teardown order drifted'

# Legacy semantics still attempt removal when Docker stop races/fails.
reset_case
DOCKER_STOP_RC=9
export DOCKER_STOP_RC
crf_runtime_stop_remove ci-runner-1 30 || fail 'stop failure prevented legacy remove attempt'
unset DOCKER_STOP_RC
assert_eq "$(tr '\n' ' ' <"$cleanup_log")" 'stop|30|ci-runner-1 remove|ci-runner-1 ' 'stop failure changed legacy remove sequencing'

echo 'recycle-runtime: OK'
