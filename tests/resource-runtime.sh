#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. tests/lib/assert.sh
# shellcheck disable=SC1091
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
# shellcheck disable=SC1091
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-resources.sh
# shellcheck disable=SC2034 # fixture globals are consumed by extracted build_args

task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
sed -n '/^build_args()/,/^}/p' "$ENGINE" > "$task_tmp/build-args.sh"
# shellcheck disable=SC1090,SC1091
. "$task_tmp/build-args.sh"

export RUNNER_MODE=pools
export RUNNER_POOLS='v2|rust|ci-rust|rust,build|1|1|4|1|2.5|4g'
export POOL_BACKEND=classic GH_SCOPE=org GH_OWNER=acme GH_REPOS=''
export RUNNER_GROUP=trusted RUNNER_LABELS=legacy RUNNER_CPUS='' RUNNER_MEMORY=16g
export RESOURCE_PIDS_LIMIT=2048 RESOURCE_MEMORY_SWAP=none
export EPHEMERAL=false RUN_AS_ROOT=false ACCESS_TOKEN='' NO_REGISTER=1
export CACHE_MOUNTS='' NETWORK_ISOLATION=off DIND=false SHARE_DOCKER_SOCK=false
export WORK_TMPFS_SIZE=2g SHARED_IMAGE_CACHE=false IMAGE_SOURCE=builtin IMAGE=''
export BUILTIN_IMAGE=test-image LABEL_NS=net.unraid.ci-runner-farm
export MANAGED_LABEL="$LABEL_NS.managed=true"
export CACHE_ROOT="$task_tmp/cache"
export SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$CACHE_ROOT"

runner_name_for() { printf 'ci-runner-%s-%s\n' "$2" "$1"; }
host() { echo testhost; }
crf_safe_mount_subdir() { printf '%s/%s\n' "$CACHE_ROOT" "$1"; }
crf_confgen_prepare() { :; }
crf_confgen() { echo spec123; }
effective_image() { echo test-image; }
repo_for_index() { echo acme/repo; }
registration_token() { echo secret; }

build_args 1 ci-runner-rust-1 rust org:acme
joined="$(printf '%s\n' "${ARGS[@]}")"
crf_assert_contains "$joined" 'LABELS=ci-rust,rust,build' "effective labels"
crf_assert_contains "$joined" '--cpus=2.5' "V2 CPU limit"
crf_assert_contains "$joined" '--memory=4294967296' "V2 memory limit"
crf_assert_contains "$joined" '--memory-swap=4294967296' "no-swap policy"
crf_assert_contains "$joined" '--pids-limit=2048' "PIDs limit"
crf_assert_contains "$joined" '--entrypoint' "protected entrypoint option"
crf_assert_contains "$joined" '/usr/local/bin/crf-runner-entrypoint' "protected entrypoint path"
crf_assert_contains "$joined" '/usr/local/bin/wait-docker.sh' "base listener startup command"
crf_assert_contains "$joined" './bin/Runner.Listener' "base listener executable"
crf_assert_contains "$joined" '--startuptype' "base listener startup mode"
[ "${ARGS[$CRF_IMAGE_ARG_INDEX]}" = test-image ] ||
  crf_fail "image argument index is not recorded"
[ "${ARGS[$((CRF_IMAGE_ARG_INDEX + 1))]}" = /usr/local/bin/wait-docker.sh ] ||
  crf_fail "image CMD was not preserved after the custom entrypoint"
crf_assert_contains "$joined" 'effective-labels=ci-rust,rust,build' "effective label metadata"
crf_assert_contains "$joined" 'backend=classic' "backend metadata"
case "$joined" in *'/var/run/docker.sock'*) crf_fail "host Docker socket was mounted" ;; esac

echo "resource-runtime: OK"
