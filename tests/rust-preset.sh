#!/usr/bin/env bash
# Rust runner-image preset guard.
#
# Keeps the one-click Rust toolchain, its pinned sccache binary, and the shared
# Cargo cache defaults aligned. The preset is a nowdoc embedded in a PHP page.
set -euo pipefail
cd "$(dirname "$0")/.."

D="src/usr/local/emhttp/plugins/ci-runner-farm"
IMAGE="$D/RunnerFarmImage.page"
ENGINE="$D/include/runner-farm.sh"
CFG="$D/default.cfg"
UI="$D/RunnerFarmSettings.page"

fail=0
bad() { printf 'RUST PRESET FAIL: %s\n' "$*" >&2; fail=1; }

rust_block="$(awk '/^# >>> ci-runner-farm toolchain: rust >>>/{f=1} f{print} /^# <<< ci-runner-farm toolchain: rust <<</{exit}' "$IMAGE")"
[ -n "$rust_block" ] || bad "Rust toolchain block is missing"

need() { grep -Fq "$1" <<<"$rust_block" || bad "Rust block lacks: $1"; }
need 'ARG SCCACHE_VERSION=0.16.0'
need 'CARGO_HOME=/home/runner/.cargo'
need 'RUSTC_WRAPPER=/usr/local/bin/sccache'
need 'CARGO_INCREMENTAL=0'
need 'SCCACHE_DIR=/home/runner/.cache/sccache'
need 'SCCACHE_CACHE_SIZE=10G'
need 'SCCACHE_IDLE_TIMEOUT=0'
need 'SCCACHE_BASEDIRS=/_work'
need 'build-essential clang lld cmake pkg-config libssl-dev'
need 'aec995a83ad3dff3d14b6314e08858b7b73d35ca85a5bcf3d3a9ec07dee35588'
need 'f73a5c39f96bb6ebb89cc7915cf182260d4cbf30765322c5e793d0fe8bd80784'
need 'sha256sum -c -'
need 'install -m 0755'

if grep -Fq '.sha256' <<<"$rust_block"; then
  bad "sccache checksum is fetched beside the binary instead of pinned in source"
fi

for file in "$ENGINE" "$CFG" "$UI"; do
  grep -Fq 'cargo-registry:/home/runner/.cargo/registry' "$file" || bad "$file lacks the Cargo registry cache mount"
  grep -Fq 'cargo-git:/home/runner/.cargo/git' "$file" || bad "$file lacks the Cargo git cache mount"
done

cache_default="$(grep -m1 '^CACHE_MOUNTS=' "$ENGINE")"
if grep -Fq 'sccache:/home/runner/.cache/sccache' <<<"$cache_default"; then
  bad "one writable local sccache directory must not be shared by all runners"
fi

if [ "$fail" -ne 0 ]; then
  echo 'rust-preset: FAILED' >&2
  exit 1
fi

echo 'rust-preset: OK: Rust toolchain, pinned sccache, and Cargo caches agree.'
