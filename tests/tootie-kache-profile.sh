#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=deployments/tootie/runner.Dockerfile
OVERLAY=deployments/tootie/kache-overlay.Dockerfile
SUPERVISOR=deployments/tootie/kache-supervise.sh

bash -n "$SUPERVISOR"
for dockerfile in "$FULL" "$OVERLAY"; do
  grep -Fq 'php-cli ripgrep file' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_TAG=v0.13.0' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_ARCHIVE_SHA256=30aeded4dc6e620c400aa3aaf7ab163dc95c703a0f3ddb4d0ba56c51f23f0bd0' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_BINARY_SHA256=5490686480adca08df1849d6dfba449e7e898e187135a452cfa6c6c40f9ff972' "$dockerfile"
  grep -Fq '/opt/hostedtoolcache/kache/0.13.0/x64/kache' "$dockerfile"
  grep -Fq 'ln -sfn /opt/hostedtoolcache/kache/0.13.0/x64/kache /usr/local/bin/kache' "$dockerfile"
  grep -Fq 'ENV KACHE_VERIFY_RESTORES=sampled' "$dockerfile"
  grep -Fq '"prefetch_enabled = false"' "$dockerfile"
  grep -Fq '"modified_input_guard = true"' "$dockerfile"
  grep -Eq 'local_max_size.*80GiB' "$dockerfile"
  grep -Fq '"[cc]"' "$dockerfile"
  grep -Fq '"extra_allowlist_flags = [\"-fmerge-all-constants\"]"' "$dockerfile"
  ! grep -Fq 'prefetch_max_bytes' "$dockerfile"
done

grep -Fq 'FROM ci-runner-farm-runner:s3-v7-kache-013-20260803' "$OVERLAY"
! grep -Fq 'remote key cache populated' "$SUPERVISOR"
! grep -Fq 'daemon status' "$SUPERVISOR"
grep -Fq 'KACHE_VERIFY_RESTORES=sampled' "$SUPERVISOR"
grep -Fq 'daemon ready; speculative prefetch disabled, exact remote cache active' "$SUPERVISOR"
grep -Fq 'pgrep -u' "$SUPERVISOR"

echo 'tootie-kache-profile: OK'
