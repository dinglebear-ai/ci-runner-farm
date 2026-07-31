#!/usr/bin/env bash
# Protected registration/JIT handoff wrapper for the runner image.
# Secret material arrives over stdin through a container-local FIFO on tmpfs.

set -euo pipefail

secret_dir="${CRF_SECRET_DIR:-/run/crf}"
base_entrypoint="${CRF_BASE_ENTRYPOINT:-/entrypoint.sh}"
docker_log="${CRF_DOCKER_LOG:-/var/log/dockerd.log}"
docker_pid_file="${CRF_DOCKER_PID_FILE:-/var/run/docker.pid}"
mkdir -p "$secret_dir"
chmod 0700 "$secret_dir"
rm -f "$secret_dir/secret.in" "$secret_dir/ready" "$secret_dir/consumed"

# The classic path enters the base image first, which starts its DinD service,
# and its CMD then waits for Docker before accepting jobs. JIT deliberately
# bypasses that entrypoint so the opaque descriptor is handed straight to
# run.sh; therefore it must establish the same readiness boundary here. Do this
# before publishing the secret FIFO so the descriptor never sits in a shell
# argv while a cold daemon starts.
crf_docker_service_start() {
  rm -f "$docker_pid_file"
  service docker start >>"$docker_log" 2>&1 || true
}
crf_docker_supervise() {
  while true; do
    sleep 3
    docker info >/dev/null 2>&1 || crf_docker_service_start
  done
}
if [ "${CRF_CREDENTIAL_KIND:-registration}" = jit ] &&
   [ "${START_DOCKER_SERVICE:-false}" = true ]; then
  docker info >/dev/null 2>&1 || crf_docker_service_start
  docker_ready=false
  for _ in $(seq 1 90); do
    if docker info >/dev/null 2>&1; then
      docker_ready=true
      break
    fi
    sleep 1
  done
  [ "$docker_ready" = true ] || {
    echo "ci-runner-farm: Docker-in-Docker did not become ready within 90 seconds" >&2
    exit 1
  }
  if [ "${CRF_DOCKER_SUPERVISE:-true}" = true ]; then
    crf_docker_supervise &
  fi
fi

mkfifo -m 0600 "$secret_dir/secret.in"
: > "$secret_dir/ready"
chmod 0600 "$secret_dir/ready"

IFS= read -r runner_credential < "$secret_dir/secret.in"
rm -f "$secret_dir/secret.in"
[ -n "$runner_credential" ] || {
  echo "ci-runner-farm: empty runner credential" >&2
  exit 1
}

: > "$secret_dir/consumed"
chmod 0600 "$secret_dir/consumed"

if [ "${CRF_CREDENTIAL_KIND:-registration}" = jit ]; then
  jit_runner="${CRF_JIT_RUNNER:-./run.sh}"
  jit_config_dir="${CRF_JIT_CONFIG_DIR:-$(pwd)}"
  if ! command -v jq >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
    echo "ci-runner-farm: JIT descriptor decoding requires jq and base64" >&2
    exit 1
  fi
  [ "${#runner_credential}" -le 65536 ] || {
    echo "ci-runner-farm: JIT descriptor exceeds the 64 KiB limit" >&2
    exit 1
  }
  [ -d "$jit_config_dir" ] && [ ! -L "$jit_config_dir" ] || {
    echo "ci-runner-farm: JIT runner configuration directory is invalid" >&2
    exit 1
  }
  jit_json="$(printf '%s' "$runner_credential" | base64 --decode 2>/dev/null)" || {
    echo "ci-runner-farm: JIT descriptor is not valid base64" >&2
    exit 1
  }
  runner_credential=""
  unset runner_credential
  # REVIEW(crf-v3q.13.1, MUST-CHECK): GitHub documents --jitconfig as an argv
  # value, but that leaves the credential visible in /proc for the listener's
  # lifetime. Materialize only the runner's three documented files from the
  # protected FIFO and start the already-configured listener with no secret in
  # argv or Env. Unknown keys fail closed rather than becoming arbitrary files.
  printf '%s' "$jit_json" | jq -e '
    type == "object" and
    (keys | sort) == [".credentials", ".credentials_rsaparams", ".runner"] and
    all(.[]; type == "string" and length > 0 and length <= 65536)
  ' >/dev/null || {
    echo "ci-runner-farm: JIT descriptor has an invalid file manifest" >&2
    exit 1
  }
  umask 077
  jit_tmp_files=()
  crf_jit_tmp_cleanup() {
    local path
    for path in "${jit_tmp_files[@]:-}"; do rm -f "$path"; done
  }
  trap crf_jit_tmp_cleanup EXIT
  for jit_file in .runner .credentials .credentials_rsaparams; do
    jit_tmp="$(mktemp "$jit_config_dir/.crf-jit.XXXXXX")" || exit 1
    jit_tmp_files+=("$jit_tmp")
    printf '%s' "$jit_json" | jq -er --arg key "$jit_file" '.[$key]' |
      base64 --decode >"$jit_tmp" || {
        echo "ci-runner-farm: JIT descriptor contains invalid file data" >&2
        exit 1
      }
    [ -s "$jit_tmp" ] && [ "$(stat -c %s "$jit_tmp")" -le 65536 ] || {
      echo "ci-runner-farm: JIT configuration file is empty or oversized" >&2
      exit 1
    }
    chmod 0600 "$jit_tmp"
  done
  for jit_index in 0 1 2; do
    jit_file=(.runner .credentials .credentials_rsaparams)
    mv -f "${jit_tmp_files[$jit_index]}" "$jit_config_dir/${jit_file[$jit_index]}"
  done
  trap - EXIT
  jit_json=""
  unset jit_json jit_tmp jit_tmp_files jit_file jit_index
  export RUNNER_ALLOW_RUNASROOT=1
  exec "$jit_runner"
else
  # The base image consumes RUNNER_TOKEN while configuring, unexports it before
  # subprocesses, and UNSET_CONFIG_VARS removes it before the long-lived listener.
  export RUNNER_TOKEN="$runner_credential"
  export UNSET_CONFIG_VARS=true
  runner_credential=""
  unset runner_credential
  exec "$base_entrypoint" "$@"
fi
