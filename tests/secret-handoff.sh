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

# JIT mode consumes the same FIFO but invokes the listener's one-job path
# without exporting the descriptor into Docker metadata.
cat > "$task_tmp/jit-runner" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --jitconfig ]
[ "$2" = "$CRF_EXPECTED_SECRET" ]
[ -f "$CRF_DOCKER_READY_MARKER" ]
printf 'jit\n' > "$CRF_TEST_RESULT"
SCRIPT
chmod 0755 "$task_tmp/jit-runner"
mkdir -p "$task_tmp/bin"
cat > "$task_tmp/bin/docker" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = info ]
[ -f "$CRF_DOCKER_READY_MARKER" ]
SCRIPT
cat > "$task_tmp/bin/service" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = docker ]
[ "$2" = start ]
: > "$CRF_DOCKER_READY_MARKER"
SCRIPT
chmod 0755 "$task_tmp/bin/docker" "$task_tmp/bin/service"
rm -rf "$CRF_SECRET_DIR"; : >"$CRF_TEST_RESULT"
CRF_CREDENTIAL_KIND=jit CRF_JIT_RUNNER="$task_tmp/jit-runner" \
  START_DOCKER_SERVICE=true CRF_DOCKER_SUPERVISE=false \
  CRF_DOCKER_READY_MARKER="$task_tmp/docker-ready" CRF_DOCKER_LOG="$task_tmp/dockerd.log" \
  CRF_DOCKER_PID_FILE="$task_tmp/docker.pid" \
  PATH="$task_tmp/bin:$PATH" \
  "$entrypoint" >"$task_tmp/jit-stdout" 2>"$task_tmp/jit-stderr" &
entry_pid=$!
for _ in $(seq 1 50); do [ -f "$CRF_SECRET_DIR/ready" ] && break; sleep 0.02; done
printf '%s\n' "$sentinel" >"$CRF_SECRET_DIR/secret.in"
if ! wait "$entry_pid"; then
  cat "$task_tmp/jit-stderr" >&2
  crf_fail "JIT entrypoint failed"
fi
crf_assert_eq jit "$(cat "$CRF_TEST_RESULT")" "JIT entrypoint lifecycle"
if grep -Fq "$sentinel" "$task_tmp/jit-stdout" "$task_tmp/jit-stderr"; then
  crf_fail "JIT descriptor leaked to output"
fi

echo "secret-handoff: OK"
