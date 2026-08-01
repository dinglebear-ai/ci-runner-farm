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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
sed -n '/^scaleset_snapshot_tsv()/,/^}/p' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh >"$tmpdir/parser.sh"
# shellcheck disable=SC1090
. "$tmpdir/parser.sh"
SCALESET_DEMAND_TTL_MAX_SECONDS=120
SCALESET_SNAPSHOT="$tmpdir/snapshot.json"
php -r '$n=time();$j=["pools"=>[["pool_id"=>"ops","assigned_jobs"=>0,"session_healthy"=>true,"acquired_handles"=>[],"observed_at"=>gmdate("c",$n),"valid_until"=>gmdate("c",$n+90)]]];file_put_contents($argv[1],json_encode($j));' "$SCALESET_SNAPSHOT"
[ "$(scaleset_snapshot_tsv)" = 'ops|0|1||1' ] || crf_fail "90-second demand TTL was rejected"
php -r '$n=time();$j=["pools"=>[["pool_id"=>"ops","assigned_jobs"=>0,"session_healthy"=>true,"acquired_handles"=>[],"observed_at"=>gmdate("c",$n),"valid_until"=>gmdate("c",$n+121)]]];file_put_contents($argv[1],json_encode($j));' "$SCALESET_SNAPSHOT"
[ "$(scaleset_snapshot_tsv)" = 'ops|0|1||0' ] || crf_fail "overlong demand TTL was accepted"

echo 'scale-set-supervisor: OK'
