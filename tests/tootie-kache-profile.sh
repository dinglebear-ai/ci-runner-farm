#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=deployments/tootie/runner.Dockerfile
OVERLAY=deployments/tootie/kache-overlay.Dockerfile
SUPERVISOR=deployments/tootie/kache-supervise.sh

bash -n "$SUPERVISOR"
for dockerfile in "$FULL" "$OVERLAY"; do
  grep -Fq 'ARG KACHE_FLEET_TAG=fleet-v0.12.0-prefetch-controls.1' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_ARCHIVE_SHA256=2c7e86b2fde706387389958ead210b94ca5f1469c730ceaf7f242032957f2eec' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_BINARY_SHA256=86d13a5c8c7a1c38c947deb1d7b36c881c524d111233d2420b957d89112b34b2' "$dockerfile"
  grep -Fq '/opt/hostedtoolcache/kache/0.12.0/x64/kache' "$dockerfile"
  grep -Fq 'ln -sfn /opt/hostedtoolcache/kache/0.12.0/x64/kache /usr/local/bin/kache' "$dockerfile"
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
