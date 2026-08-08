#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
sed -n '/^crf_confgen_prepare()/,/^}/p' "$ENGINE" > "$tmpdir/functions.sh"
sed -n '/^crf_confgen()/,/^}/p' "$ENGINE" >> "$tmpdir/functions.sh"
sed -n '/^effective_image()/,/^}/p' "$ENGINE" >> "$tmpdir/functions.sh"
# shellcheck disable=SC1090
. "$tmpdir/functions.sh"

SCRIPT_DIR="$tmpdir"
printf 'entrypoint-v1\n' > "$SCRIPT_DIR/runner-entrypoint.sh"
RUNNER_MODE=pools
POOL_CONFIG_VERSION=v2
GH_SCOPE=org
GH_OWNER=dinglebear-ai
RUNNER_GROUP=trusted
EPHEMERAL=false
RUNNER_CPUS=8
RUNNER_MEMORY=8g
WORK_TMPFS_SIZE=""
CACHE_MOUNTS='cargo:/home/runner/.cargo'
DIND=true
SHARE_DOCKER_SOCK=false
RUN_AS_ROOT=true
IMAGE_SOURCE=builtin
IMAGE=""
BUILTIN_IMAGE=ci-runner-farm-runner:latest
REGISTRY_SERVER=""
REGISTRY_USERNAME=""
SHARED_IMAGE_CACHE=true
MIRROR_PORT=5000
NETWORK_ISOLATION=isolate
RUNNER_NETWORK=ci-runner-net
CACHE_ROOT=/mnt/cache/runner
RESOURCE_PIDS_LIMIT=4096
RESOURCE_MEMORY_SWAP=none
GH_REPOS=""
RUNNER_LABELS=""
CRF_TEST_IMAGE_ID=sha256:image-v1
docker_calls="$tmpdir/docker.calls"

pool_mode_enabled() { return 0; }
pool_snapshot_load() { POOL_CONFIG_VERSION=v2; return 0; }
pool_runner_spec_hash() { printf '%s\n' pool-spec-v1; }
docker() {
  [ "${1:-}" = image ] && [ "${2:-}" = inspect ] || return 1
  local calls=0
  [ ! -f "$docker_calls" ] || calls="$(cat "$docker_calls")"
  printf '%s\n' "$((calls+1))" > "$docker_calls"
  [ -n "$CRF_TEST_IMAGE_ID" ] || return 1
  printf '%s\n' "$CRF_TEST_IMAGE_ID"
}

crf_confgen_prepare
baseline="$(crf_confgen rust 'org:dinglebear-ai')"
repeat="$(crf_confgen rust 'org:dinglebear-ai')"
[ "$baseline" = "$repeat" ] || crf_fail 'prepared fingerprint changed without config drift'
[ "$(cat "$docker_calls")" = 1 ] || crf_fail 'prepared fingerprint repeated Docker image inspection'
CRF_TEST_IMAGE_ID=""
if crf_confgen_prepare; then crf_fail 'missing image produced a synthetic fingerprint identity'; fi
grep -Fq "Runner image '$BUILTIN_IMAGE' is unavailable" <<<"$CRF_CONFGEN_ERROR" || crf_fail 'missing image error was not explicit'
CRF_TEST_IMAGE_ID=sha256:image-v1
crf_confgen_prepare
CACHE_MOUNTS='cargo:/home/runner/.cargo kache-aws:/home/runner/.aws:ro'
mount_changed="$(crf_confgen rust 'org:dinglebear-ai')"
[ "$baseline" != "$mount_changed" ] || crf_fail 'v2 fingerprint ignored CACHE_MOUNTS'

CACHE_MOUNTS='cargo:/home/runner/.cargo'
CRF_TEST_IMAGE_ID=sha256:image-v2
crf_confgen_prepare
image_changed="$(crf_confgen rust 'org:dinglebear-ai')"
[ "$baseline" != "$image_changed" ] || crf_fail 'v2 fingerprint ignored built-in image digest drift'

CRF_TEST_IMAGE_ID=sha256:image-v1
RESOURCE_MEMORY_SWAP=double
swap_changed="$(crf_confgen rust 'org:dinglebear-ai')"
[ "$baseline" != "$swap_changed" ] || crf_fail 'v2 fingerprint ignored memory-swap policy'

RESOURCE_MEMORY_SWAP=none
printf 'entrypoint-v2\n' > "$SCRIPT_DIR/runner-entrypoint.sh"
crf_confgen_prepare
entrypoint_changed="$(crf_confgen rust 'org:dinglebear-ai')"
[ "$baseline" != "$entrypoint_changed" ] || crf_fail 'v2 fingerprint ignored protected entrypoint content'

echo 'config-fingerprint: OK'
