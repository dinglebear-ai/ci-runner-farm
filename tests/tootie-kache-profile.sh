#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=deployments/tootie/runner.Dockerfile
OVERLAY=deployments/tootie/kache-overlay.Dockerfile
SUPERVISOR=deployments/tootie/kache-supervise.sh

bash -n "$SUPERVISOR"
grep -Eq 'php-cli ripgrep file .*clang' "$FULL"
for dockerfile in "$FULL" "$OVERLAY"; do
  grep -Fq 'ARG KACHE_FLEET_TAG=fleet-v0.13.0-prefetch-controls.1' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_ARCHIVE_SHA256=f9250450073dd48c23ee457093bb860a9acafc037608f11a1643471c0d00af6b' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_BINARY_SHA256=87cddc742db80394a77e3c9e9cd53fb280bf2b3da2b2fd4c344d70820df46b06' "$dockerfile"
  grep -Fq '/opt/hostedtoolcache/kache/0.13.0/x64/kache' "$dockerfile"
  grep -Fq 'ln -sfn /opt/hostedtoolcache/kache/0.13.0/x64/kache /usr/local/bin/kache' "$dockerfile"
  grep -Fq 'ENV KACHE_VERIFY_RESTORES=sampled' "$dockerfile"
  grep -Fq '"prefetch_enabled = false"' "$dockerfile"
  grep -Fq '"modified_input_guard = true"' "$dockerfile"
  grep -Eq 'local_max_size.*80GiB' "$dockerfile"
  ! grep -Fq 'prefetch_max_bytes' "$dockerfile"
done

grep -Fq 'FROM ci-runner-farm-runner:s3-v5-20260802' "$OVERLAY"
! grep -Fq 'remote key cache populated' "$SUPERVISOR"
! grep -Fq 'daemon status' "$SUPERVISOR"
grep -Fq 'KACHE_VERIFY_RESTORES=sampled' "$SUPERVISOR"
grep -Fq 'daemon ready; speculative prefetch disabled, exact remote cache active' "$SUPERVISOR"
grep -Fq 'pgrep -u' "$SUPERVISOR"

echo 'tootie-kache-profile: OK'
