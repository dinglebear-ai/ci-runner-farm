#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh
go125="$(crf_go125)"
(cd tools/crf-scaleset && "$go125" test ./internal/journal ./internal/protocol ./internal/supervisor)
grep -Fq 'SO_PEERCRED' tools/crf-scaleset/internal/ipc/server.go
grep -Fq 'chmod 0700 "$SCALESET_STATE_DIR"' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
grep -Fq 'SCALESET_DURABLE_BOOTSTRAP_STATE_DIR="${SCALESET_DURABLE_BOOTSTRAP_STATE_DIR:-$CACHE_ROOT/state/scalesets}"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
grep -Fq 'scaleset_paths_refresh' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
grep -Fq 'JIT_BOOTSTRAP_STATE_DIR="${JIT_BOOTSTRAP_STATE_DIR:-$CACHE_ROOT/state/jit}"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh
grep -Fq 'jit_paths_refresh' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh
grep -Fq 'compatibility evidence is missing, stale, incomplete, or mismatched' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
echo 'scale-set-supervisor: OK'
