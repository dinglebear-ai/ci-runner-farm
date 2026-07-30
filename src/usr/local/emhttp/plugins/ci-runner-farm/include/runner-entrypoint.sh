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

IFS= read -r runner_token < "$secret_dir/secret.in"
rm -f "$secret_dir/secret.in"
[ -n "$runner_token" ] || {
  echo "ci-runner-farm: empty runner credential" >&2
  exit 1
}

# The base image consumes RUNNER_TOKEN while configuring, unexports it before
# subprocesses, and UNSET_CONFIG_VARS removes it before the long-lived listener.
export RUNNER_TOKEN="$runner_token"
export UNSET_CONFIG_VARS=true
runner_token=""
unset runner_token
: > "$secret_dir/consumed"
chmod 0600 "$secret_dir/consumed"

exec "$base_entrypoint" "$@"
