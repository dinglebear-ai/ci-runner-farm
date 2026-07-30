#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
sentinel='crf_secret_SENTINEL_7f91'
entrypoint=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh
engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

cat > "$task_tmp/base-entrypoint" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "${RUNNER_TOKEN:-}" = "${CRF_EXPECTED_SECRET:-}" ]
[ "${UNSET_CONFIG_VARS:-}" = true ]
printf 'configured\n' > "$CRF_TEST_RESULT"
unset RUNNER_TOKEN UNSET_CONFIG_VARS
exec "$@"
SCRIPT
chmod 0755 "$task_tmp/base-entrypoint"

cat > "$task_tmp/final-command" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${RUNNER_TOKEN:-}" ]
printf 'listener\n' >> "$CRF_TEST_RESULT"
SCRIPT
chmod 0755 "$task_tmp/final-command"

export CRF_SECRET_DIR="$task_tmp/run"
export CRF_BASE_ENTRYPOINT="$task_tmp/base-entrypoint"
export CRF_EXPECTED_SECRET="$sentinel"
export CRF_TEST_RESULT="$task_tmp/result"
"$entrypoint" "$task_tmp/final-command" >"$task_tmp/stdout" 2>"$task_tmp/stderr" &
entry_pid=$!
for _ in $(seq 1 50); do [ -f "$CRF_SECRET_DIR/ready" ] && break; sleep 0.02; done
[ -f "$CRF_SECRET_DIR/ready" ] || crf_fail "entrypoint did not become ready"
printf '%s\n' "$sentinel" > "$CRF_SECRET_DIR/secret.in"
wait "$entry_pid"
crf_assert_eq $'configured\nlistener' "$(cat "$task_tmp/result")" "entrypoint lifecycle"
[ -f "$CRF_SECRET_DIR/consumed" ] || crf_fail "consumed acknowledgement missing"
[ ! -e "$CRF_SECRET_DIR/secret.in" ] || crf_fail "secret FIFO was not removed"
if grep -R -F "$sentinel" "$task_tmp" --exclude=base-entrypoint --exclude=result >/dev/null 2>&1; then
  crf_fail "sentinel leaked into entrypoint output/runtime files"
fi

# shellcheck disable=SC2016 # the literal $reg pattern must not expand
if grep -Eq -- '-e[[:space:]]+RUNNER_TOKEN|RUNNER_TOKEN="\$reg"' "$engine"; then
  crf_fail "registration token is still injected through Docker Env"
fi
grep -Fq -- '--entrypoint /usr/local/bin/crf-runner-entrypoint' "$engine" ||
  crf_fail "protected entrypoint is not installed in Docker args"
grep -Fq -- 'cat > /run/crf/secret.in' "$engine" ||
  crf_fail "host does not inject the secret through stdin"
grep -Fq -- '-e UNSET_CONFIG_VARS="true"' "$engine" ||
  crf_fail "base image is not told to clear configuration variables"

echo "secret-handoff: OK"
