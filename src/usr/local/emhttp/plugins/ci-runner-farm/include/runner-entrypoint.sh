#!/usr/bin/env bash
# Protected registration/JIT handoff wrapper for the runner image.
# Secret material arrives over stdin through a container-local FIFO on tmpfs.

set -euo pipefail

secret_dir="${CRF_SECRET_DIR:-/run/crf}"
base_entrypoint="${CRF_BASE_ENTRYPOINT:-/entrypoint.sh}"
mkdir -p "$secret_dir"
chmod 0700 "$secret_dir"
rm -f "$secret_dir/secret.in" "$secret_dir/ready" "$secret_dir/consumed"
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
