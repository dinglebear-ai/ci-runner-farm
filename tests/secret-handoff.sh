#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

task_tmp="$(mktemp -d)"
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf 'secret-handoff: failed with status %s\n' "$status" >&2
    for stderr_path in "$task_tmp"/stderr "$task_tmp"/*-stderr; do
      if [ -s "$stderr_path" ]; then
        printf '%s\n' "--- $stderr_path ---" >&2
        cat "$stderr_path" >&2
      fi
    done
  fi
  rm -rf "$task_tmp"
  exit "$status"
}
trap cleanup EXIT
sentinel='crf_secret_SENTINEL_7f91'
entrypoint=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh
engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh

wait_for_secret_fifo() {
  local label="$1" stderr_path="$2" attempt
  attempt=0
  while [ "$attempt" -lt 500 ]; do
    if [ -f "$CRF_SECRET_DIR/ready" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.02
  done
  [ -f "$stderr_path" ] && cat "$stderr_path" >&2
  crf_fail "$label entrypoint did not become ready"
}

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
CRF_CREDENTIAL_KIND=registration \
  "$entrypoint" "$task_tmp/final-command" >"$task_tmp/stdout" 2>"$task_tmp/stderr" &
entry_pid=$!
wait_for_secret_fifo registration "$task_tmp/stderr"
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
if [ "${CRF_TEST_EFFECTIVE_USER:-}" = runner ]; then
  [ "$HOME" = /home/runner ]
  [ "$USER" = runner ]
  [ "$LOGNAME" = runner ]
  [ -w "$RUNNER_WORKDIR" ]
fi
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
  RUN_AS_ROOT=true \
  START_DOCKER_SERVICE=true CRF_DOCKER_SUPERVISE=false \
  CRF_DOCKER_READY_MARKER="$task_tmp/docker-ready" CRF_DOCKER_LOG="$task_tmp/dockerd.log" \
  CRF_DOCKER_PID_FILE="$task_tmp/docker.pid" \
  PATH="$task_tmp/bin:$PATH" \
  "$entrypoint" >"$task_tmp/jit-stdout" 2>"$task_tmp/jit-stderr" &
entry_pid=$!
wait_for_secret_fifo JIT "$task_tmp/jit-stderr"
printf '%s\n' "$descriptor" >"$CRF_SECRET_DIR/secret.in"
if ! wait "$entry_pid"; then
  cat "$task_tmp/jit-stderr" >&2
  crf_fail "JIT entrypoint failed"
fi
crf_assert_eq jit "$(cat "$CRF_TEST_RESULT")" "JIT entrypoint lifecycle"
if grep -Fq "$descriptor" "$task_tmp/jit-stdout" "$task_tmp/jit-stderr"; then
  crf_fail "JIT descriptor leaked to output"
fi

# A JIT listener that never receives its one job must not reserve capacity
# forever. The runner's job-start hook is authoritative: an unfired hook
# retires the listener, while a fired hook protects a running job regardless of
# how long that job subsequently runs.
cat >"$task_tmp/waiting-jit-runner" <<EOF
#!/usr/bin/env bash
trap 'exit 42' TERM
: > "$task_tmp/waiting-started"
while true; do sleep 1; done
EOF
chmod +x "$task_tmp/waiting-jit-runner"
mkdir -p "$task_tmp/waiting-config"
export CRF_SECRET_DIR="$task_tmp/waiting-secret"
CRF_CREDENTIAL_KIND=jit CRF_JIT_CONFIG_DIR="$task_tmp/waiting-config" \
  CRF_JIT_RUNNER="$task_tmp/waiting-jit-runner" CRF_JIT_JOB_START_TIMEOUT_SECONDS=3 \
  START_DOCKER_SERVICE=false RUN_AS_ROOT=true \
  "$entrypoint" >"$task_tmp/waiting-stdout" 2>"$task_tmp/waiting-stderr" &
entry_pid=$!
wait_for_secret_fifo waiting-JIT "$task_tmp/waiting-stderr"
printf '%s\n' "$descriptor" >"$task_tmp/waiting-secret/secret.in"
set +e
wait "$entry_pid"
waiting_status=$?
set -e
[ -e "$task_tmp/waiting-started" ] || crf_fail 'never-started JIT listener did not launch'
[ "$waiting_status" -eq 42 ] || crf_fail "never-started JIT listener exited with $waiting_status instead of watchdog status 42"

cat >"$task_tmp/started-jit-runner" <<'EOF'
#!/usr/bin/env bash
"$ACTIONS_RUNNER_HOOK_JOB_STARTED"
sleep 2
EOF
chmod +x "$task_tmp/started-jit-runner"
mkdir -p "$task_tmp/started-config"
export CRF_SECRET_DIR="$task_tmp/started-secret"
CRF_CREDENTIAL_KIND=jit CRF_JIT_CONFIG_DIR="$task_tmp/started-config" \
  CRF_JIT_RUNNER="$task_tmp/started-jit-runner" CRF_JIT_JOB_START_TIMEOUT_SECONDS=3 \
  START_DOCKER_SERVICE=false RUN_AS_ROOT=true \
  "$entrypoint" >"$task_tmp/started-stdout" 2>"$task_tmp/started-stderr" &
entry_pid=$!
wait_for_secret_fifo started-JIT "$task_tmp/started-stderr"
printf '%s\n' "$descriptor" >"$task_tmp/started-secret/secret.in"
wait "$entry_pid" || crf_fail 'job-started JIT listener was retired'
[ -e "$task_tmp/started-config/.crf-job-started" ] || crf_fail 'JIT job-start hook did not record the transition'
if grep -Fq 'received no job' "$task_tmp/started-stderr"; then
  crf_fail 'watchdog retired a JIT runner after its job started'
fi

# Non-root JIT mode keeps privileged bootstrap in the wrapper, then transfers
# only the listener files and workdir before dropping to the runner account.
cat > "$task_tmp/bin/id" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -u ] && [ "$2" = runner ]
printf '1001\n'
SCRIPT
cat > "$task_tmp/bin/chown" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CRF_TEST_CHOWN"
SCRIPT
cat > "$task_tmp/bin/gosu" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = runner ]; shift
[ "$1" = env ]; shift
export CRF_TEST_EFFECTIVE_USER=runner
exec env "$@"
SCRIPT
chmod 0755 "$task_tmp/bin/id" "$task_tmp/bin/chown" "$task_tmp/bin/gosu"
rm -rf "$CRF_SECRET_DIR" "$task_tmp/jit-config" "$task_tmp/jit-work"
mkdir -p "$task_tmp/jit-config" "$task_tmp/jit-work"
: >"$CRF_TEST_RESULT"; : >"$task_tmp/chown-args"; : >"$task_tmp/docker-ready"
CRF_CREDENTIAL_KIND=jit CRF_JIT_RUNNER="$task_tmp/jit-runner" \
  CRF_JIT_CONFIG_DIR="$task_tmp/jit-config" RUNNER_WORKDIR="$task_tmp/jit-work" \
  RUN_AS_ROOT=false START_DOCKER_SERVICE=false CRF_TEST_CHOWN="$task_tmp/chown-args" \
  CRF_DOCKER_READY_MARKER="$task_tmp/docker-ready" \
  PATH="$task_tmp/bin:$PATH" \
  "$entrypoint" >"$task_tmp/nonroot-jit-stdout" 2>"$task_tmp/nonroot-jit-stderr" &
entry_pid=$!
wait_for_secret_fifo nonroot-JIT "$task_tmp/nonroot-jit-stderr"
printf '%s\n' "$descriptor" >"$CRF_SECRET_DIR/secret.in"
wait "$entry_pid" || { cat "$task_tmp/nonroot-jit-stderr" >&2; crf_fail 'non-root JIT entrypoint failed'; }
crf_assert_eq jit "$(cat "$CRF_TEST_RESULT")" 'non-root JIT lifecycle'
grep -Fxq runner:runner "$task_tmp/chown-args" || crf_fail 'non-root JIT ownership did not target runner:runner'
for owned_path in .runner .credentials .credentials_rsaparams; do
  grep -Fxq "$task_tmp/jit-config/$owned_path" "$task_tmp/chown-args" || crf_fail "non-root JIT did not transfer $owned_path"
done
grep -Fxq "$task_tmp/jit-work" "$task_tmp/chown-args" || crf_fail 'non-root JIT did not transfer its workdir'

# Invalid privilege configuration fails closed before the listener starts.
rm -rf "$CRF_SECRET_DIR" "$task_tmp/jit-config"
mkdir -p "$task_tmp/jit-config"
: >"$CRF_TEST_RESULT"
CRF_CREDENTIAL_KIND=jit CRF_JIT_RUNNER="$task_tmp/jit-runner" \
  CRF_JIT_CONFIG_DIR="$task_tmp/jit-config" RUNNER_WORKDIR="$task_tmp/jit-work" \
  RUN_AS_ROOT=unexpected START_DOCKER_SERVICE=false \
  CRF_DOCKER_READY_MARKER="$task_tmp/docker-ready" PATH="$task_tmp/bin:$PATH" \
  "$entrypoint" >"$task_tmp/invalid-user-stdout" 2>"$task_tmp/invalid-user-stderr" &
entry_pid=$!
wait_for_secret_fifo invalid-user-JIT "$task_tmp/invalid-user-stderr"
printf '%s\n' "$descriptor" >"$CRF_SECRET_DIR/secret.in"
if wait "$entry_pid"; then crf_fail 'JIT entrypoint accepted an invalid RUN_AS_ROOT value'; fi
[ ! -s "$CRF_TEST_RESULT" ] || crf_fail 'invalid RUN_AS_ROOT started the listener'
grep -Fq 'RUN_AS_ROOT must be true or false' "$task_tmp/invalid-user-stderr" ||
  crf_fail 'invalid RUN_AS_ROOT did not report its configuration error'

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
wait_for_secret_fifo bad-JIT "$task_tmp/bad-jit-stderr"
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
wait_for_secret_fifo rename-failure "$task_tmp/rename-jit-stderr"
printf '%s\n' "$descriptor" >"$CRF_SECRET_DIR/secret.in"
if wait "$entry_pid"; then
  crf_fail "JIT entrypoint ignored a credential rename failure"
fi
[ -z "$(find "$task_tmp/jit-config" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  crf_fail "JIT entrypoint left a partial credential set after rename failure"

echo "secret-handoff: OK"
