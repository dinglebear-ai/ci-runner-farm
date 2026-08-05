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

# Host pipefail can report the FIFO producer as SIGPIPE after the container
# already consumed the credential. The durable consumed acknowledgement must win.
sed -n '/^runner_secret_inject()/,/^}/p' "$engine" > "$task_tmp/runner-secret-inject.sh"
# shellcheck disable=SC1090
. "$task_tmp/runner-secret-inject.sh"
NAME_PREFIX=ci-runner
runner_identity_validate() { return 0; }
docker() {
  if [ "${1:-}" = exec ] && [ "${2:-}" = -i ]; then
    cat >/dev/null
    : > "$task_tmp/fifo-writer-called"
    return 141
  fi
  case "$*" in
    *'/run/crf/ready'*) return 0 ;;
    *'/run/crf/consumed'*) return 0 ;;
  esac
  return 1
}
if ! runner_secret_inject ci-runner-python-1 "$sentinel" container-id; then
  crf_fail 'successful consumed marker was overridden by FIFO producer SIGPIPE'
fi
[ -f "$task_tmp/fifo-writer-called" ] || crf_fail 'host FIFO writer was not exercised'
unset -f docker runner_identity_validate

# JIT mode consumes the same FIFO, materializes only the three allowlisted
# mode-0600 runner files, and invokes the listener without putting the opaque
# descriptor in argv or the environment.
cat > "$task_tmp/jit-runner" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 0 ]
[ -z "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ]
[ "$(stat -c %a "$CRF_JIT_CONFIG_DIR/.runner")" = 600 ]
[ "$(stat -c %a "$CRF_JIT_CONFIG_DIR/.credentials")" = 600 ]
[ "$(stat -c %a "$CRF_JIT_CONFIG_DIR/.credentials_rsaparams")" = 600 ]
[ "$(cat "$CRF_JIT_CONFIG_DIR/.runner")" = runner-config ]
[ "$(cat "$CRF_JIT_CONFIG_DIR/.credentials")" = credential-config ]
[ "$(cat "$CRF_JIT_CONFIG_DIR/.credentials_rsaparams")" = rsa-config ]
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
descriptor="$(php -r 'echo base64_encode(json_encode([
  ".runner"=>base64_encode("runner-config"),
  ".credentials"=>base64_encode("credential-config"),
  ".credentials_rsaparams"=>base64_encode("rsa-config"),
],JSON_UNESCAPED_SLASHES));')"
rm -rf "$CRF_SECRET_DIR"; mkdir -p "$task_tmp/jit-config"; : >"$CRF_TEST_RESULT"
CRF_CREDENTIAL_KIND=jit CRF_JIT_RUNNER="$task_tmp/jit-runner" \
  CRF_JIT_CONFIG_DIR="$task_tmp/jit-config" \
  START_DOCKER_SERVICE=true CRF_DOCKER_SUPERVISE=false \
  CRF_DOCKER_READY_MARKER="$task_tmp/docker-ready" CRF_DOCKER_LOG="$task_tmp/dockerd.log" \
  CRF_DOCKER_PID_FILE="$task_tmp/docker.pid" \
  PATH="$task_tmp/bin:$PATH" \
  "$entrypoint" >"$task_tmp/jit-stdout" 2>"$task_tmp/jit-stderr" &
entry_pid=$!
for _ in $(seq 1 50); do [ -f "$CRF_SECRET_DIR/ready" ] && break; sleep 0.02; done
printf '%s\n' "$descriptor" >"$CRF_SECRET_DIR/secret.in"
if ! wait "$entry_pid"; then
  cat "$task_tmp/jit-stderr" >&2
  crf_fail "JIT entrypoint failed"
fi
crf_assert_eq jit "$(cat "$CRF_TEST_RESULT")" "JIT entrypoint lifecycle"
if grep -Fq "$descriptor" "$task_tmp/jit-stdout" "$task_tmp/jit-stderr"; then
  crf_fail "JIT descriptor leaked to output"
fi

# Unknown JIT payload keys are never materialized or ignored silently.
bad_descriptor="$(php -r 'echo base64_encode(json_encode([
  ".runner"=>base64_encode("runner-config"),
  ".credentials"=>base64_encode("credential-config"),
  ".credentials_rsaparams"=>base64_encode("rsa-config"),
  ".foreign"=>base64_encode("must-not-write"),
]));')"
rm -rf "$CRF_SECRET_DIR" "$task_tmp/jit-config"; mkdir -p "$task_tmp/jit-config"
CRF_CREDENTIAL_KIND=jit CRF_JIT_RUNNER="$task_tmp/jit-runner" \
  CRF_JIT_CONFIG_DIR="$task_tmp/jit-config" START_DOCKER_SERVICE=false \
  "$entrypoint" >"$task_tmp/bad-jit-stdout" 2>"$task_tmp/bad-jit-stderr" &
entry_pid=$!
for _ in $(seq 1 50); do [ -f "$CRF_SECRET_DIR/ready" ] && break; sleep 0.02; done
printf '%s\n' "$bad_descriptor" >"$CRF_SECRET_DIR/secret.in"
if wait "$entry_pid"; then
  crf_fail "JIT entrypoint accepted an unknown descriptor key"
fi
[ ! -e "$task_tmp/jit-config/.foreign" ] ||
  crf_fail "JIT entrypoint wrote an unknown descriptor key"

# A rename failure after the first credential file must roll the whole set back.
mkdir -p "$task_tmp/fail-bin"
cat > "$task_tmp/fail-bin/mv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
case "${*: -1}" in */.credentials) exit 1 ;; esac
exec /bin/mv "$@"
SCRIPT
chmod 0755 "$task_tmp/fail-bin/mv"
rm -rf "$CRF_SECRET_DIR" "$task_tmp/jit-config"; mkdir -p "$task_tmp/jit-config"
CRF_CREDENTIAL_KIND=jit CRF_JIT_RUNNER="$task_tmp/jit-runner" \
  CRF_JIT_CONFIG_DIR="$task_tmp/jit-config" START_DOCKER_SERVICE=false \
  PATH="$task_tmp/fail-bin:$PATH" \
  "$entrypoint" >"$task_tmp/rename-jit-stdout" 2>"$task_tmp/rename-jit-stderr" &
entry_pid=$!
for _ in $(seq 1 50); do [ -f "$CRF_SECRET_DIR/ready" ] && break; sleep 0.02; done
printf '%s\n' "$descriptor" >"$CRF_SECRET_DIR/secret.in"
if wait "$entry_pid"; then
  crf_fail "JIT entrypoint ignored a credential rename failure"
fi
[ -z "$(find "$task_tmp/jit-config" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  crf_fail "JIT entrypoint left a partial credential set after rename failure"

echo "secret-handoff: OK"
