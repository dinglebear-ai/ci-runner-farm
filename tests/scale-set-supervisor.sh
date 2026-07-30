#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
go125="$(mise where go@1.25.3)/bin/go"
(cd tools/crf-scaleset && "$go125" test ./internal/journal ./internal/protocol ./internal/supervisor)
grep -Fq 'SO_PEERCRED' tools/crf-scaleset/internal/ipc/server.go
grep -Fq 'chmod 0700 "$SCALESET_STATE_DIR"' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
grep -Fq 'compatibility evidence is missing, stale, or incomplete' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
echo 'scale-set-supervisor: OK'
