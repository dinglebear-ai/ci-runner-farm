#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

rg -q '^rust = "1\.97\.1"$' .mise.toml ||
  crf_fail '.mise.toml must pin the CI Rust release'
rg -q 'rustc_version="\$\(rustc --version\)"' scripts/worktree-setup.sh ||
  crf_fail 'worktree setup must verify rustc'
rg -q 'cargo_version="\$\(cargo --version\)"' scripts/worktree-setup.sh ||
  crf_fail 'worktree setup must verify cargo'

echo 'worktree-toolchain: OK'
