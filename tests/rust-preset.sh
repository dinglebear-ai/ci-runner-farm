#!/usr/bin/env bash
# Rust runner-image preset guard.
#
# Keeps the one-click Rust toolchain, its pinned sccache binary, and the safe
# cache-mount defaults aligned. The preset is a nowdoc embedded in a PHP page.
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

need() { grep -Fq -- "$1" <<<"$rust_block" || bad "Rust block lacks: $1"; }
need 'ARG RUST_TOOLCHAIN=1.97.1'
need 'ARG RUSTUP_INIT_VERSION=1.28.2'
need 'ARG SCCACHE_VERSION=0.16.0'
need 'CARGO_HOME=/home/runner/.cargo'
need 'RUSTC_WRAPPER=/usr/local/bin/sccache'
need 'CARGO_INCREMENTAL=0'
need 'SCCACHE_DIR=/home/runner/.cache/sccache'
need 'SCCACHE_CACHE_SIZE=10G'
need 'SCCACHE_IDLE_TIMEOUT=0'
need 'SCCACHE_BASEDIRS=/_work'
need 'build-essential clang lld cmake pkg-config libssl-dev'
need '20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c'
need 'e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c'
need 'static.rust-lang.org/rustup/archive/$RUSTUP_INIT_VERSION/$rustup_target/rustup-init'
need 'aec995a83ad3dff3d14b6314e08858b7b73d35ca85a5bcf3d3a9ec07dee35588'
need 'f73a5c39f96bb6ebb89cc7915cf182260d4cbf30765322c5e793d0fe8bd80784'
need 'sha256sum -c -'
need 'install -m 0755'

if grep -Fq '.sha256' <<<"$rust_block"; then
  bad "a checksum is fetched beside a binary instead of pinned in source"
fi
if grep -Fq 'sh.rustup.rs' <<<"$rust_block" || grep -Eq 'curl[^|]*\|[[:space:]]*sh' <<<"$rust_block"; then
  bad "rustup uses a mutable installer script instead of the pinned rustup-init binary"
fi
need '-o /tmp/rustup-init'
need 'echo "$rustup_sha256  /tmp/rustup-init" | sha256sum -c -'
need '/tmp/rustup-init -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN"'

for file in "$ENGINE" "$CFG" "$UI"; do
  if grep -Fq 'cargo-registry:/home/runner/.cargo/registry' "$file"; then
    bad "$file shares one writable Cargo registry across concurrent runners"
  fi
  if grep -Fq 'cargo-git:/home/runner/.cargo/git' "$file"; then
    bad "$file shares one writable Cargo git cache across concurrent runners"
  fi
done

cache_default="$(grep -m1 '^CACHE_MOUNTS=' "$ENGINE")"
if grep -Fq 'sccache:/home/runner/.cache/sccache' <<<"$cache_default"; then
  bad "one writable local sccache directory must not be shared by all runners"
fi

if [ "$fail" -ne 0 ]; then
  echo 'rust-preset: FAILED' >&2
  exit 1
fi

echo 'rust-preset: OK: Rust toolchain and cache defaults avoid shared writable Cargo state.'
