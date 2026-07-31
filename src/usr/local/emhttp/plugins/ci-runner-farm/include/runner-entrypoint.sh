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
  jit_config="$runner_credential"
  runner_credential=""
  unset runner_credential
  export RUNNER_ALLOW_RUNASROOT=1
  exec "$jit_runner" --jitconfig "$jit_config"
else
  # The base image consumes RUNNER_TOKEN while configuring, unexports it before
  # subprocesses, and UNSET_CONFIG_VARS removes it before the long-lived listener.
  export RUNNER_TOKEN="$runner_credential"
  export UNSET_CONFIG_VARS=true
  runner_credential=""
  unset runner_credential
  exec "$base_entrypoint" "$@"
fi
