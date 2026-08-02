#!/usr/bin/env bash
# Busy runners must publish the active GitHub Actions job into the Fleet status cache.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmpdir="$(mktemp -d)"
snippet="$tmpdir/functions.sh"
trap 'rm -rf "$tmpdir"' EXIT

sed -n '/^cmd_usage_refresh()/,/^}/p' "$ENGINE" > "$snippet"
# shellcheck disable=SC1090
. "$snippet"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
inc() { local f="$1" n=0; [ -f "$f" ] && n="$(cat "$f")"; printf '%s\n' "$((n+1))" > "$f"; }
count() { local f="$1"; [ -f "$f" ] && cat "$f" || printf '0\n'; }
_b64() { local v; v="$(printf '%s' "$1" | base64 -w0 2>/dev/null)"; printf '%s' "${v:-_}"; }

RUNDIR="$tmpdir/run"
mkdir -p "$RUNDIR"
logs_calls="$tmpdir/logs.calls"

cache_root_problem() { :; }
public_repo_problem() { :; }
managed_names() { printf '%s\n' ci-runner-busy ci-runner-idle; }
github_phase_refresh() { :; }
runner_state() { [ "$1" = ci-runner-busy ] && printf 'busy\n' || printf 'idle\n'; }
to_mib() { printf '256\n'; }

docker() {
  case "$1" in
    stats)
      printf '%s\n' \
        'ci-runner-busy|42.5%|256MiB / 4GiB' \
        'ci-runner-idle|0.0%|128MiB / 4GiB'
      ;;
    logs)
      inc "$logs_calls"
      [ "${5:-}" = ci-runner-busy ] || fail "read logs for non-busy runner: $*"
      printf '%s\n' \
        '2026-08-02T20:24:01.008430280Z 2026-08-02 20:24:01Z: Running job: Cargo Deny / deny' \
        '2026-08-02T20:24:38.694590977Z 2026-08-02 20:24:38Z: Job Cargo Deny / deny completed with result: Succeeded' \
        '2026-08-02T20:28:54.248223887Z 2026-08-02 20:28:54Z: Running job: Test'
      ;;
    exec) fail "job visibility used docker exec: $*" ;;
    *) fail "unexpected docker call: $*" ;;
  esac
}

cmd_usage_refresh

busy="$(grep '^ci-runner-busy ' "$RUNDIR/usage.cache")"
idle="$(grep '^ci-runner-idle ' "$RUNDIR/usage.cache")"
# shellcheck disable=SC2086
set -- $busy
[ "$5" != _ ] || fail 'busy runner job metadata was empty'
assert_eq "$(printf '%s' "$5" | base64 -d)" 'Test' 'active job name was not cached'
assert_eq "$6" '2026-08-02T20:28:54.248223887Z' 'active job start timestamp was not cached'
# shellcheck disable=SC2086
set -- $idle
assert_eq "$5" _ 'idle runner unexpectedly retained a job name'
assert_eq "$6" _ 'idle runner unexpectedly retained a job timestamp'
assert_eq "$(count "$logs_calls")" 1 'usage refresh did not inspect exactly one busy runner log'

echo 'job-visibility: OK'
