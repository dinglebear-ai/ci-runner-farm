#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

script=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh
grep -Fq 'committed scheduler admission' "$script"
grep -Fq 'container_create_started' "$script"
grep -Fq 'jit_container_exists' "$script"
grep -Fq 'reservation_release "$reservation"' "$script"
grep -Fq 'scaleset_request retire_jit' "$script"
grep -Fq 'jit_retire_handle "$pool" "$handle" || return 1' "$script"
grep -Fq 'jit_import_legacy_states' "$script"
grep -Fq 'jit_reconcile_orphan_containers' "$script"
grep -Fq 'jit_container_secret_consumed' "$script"
grep -Fq 'pool_id=%s' "$script"
grep -Fq 'JIT_HANDOFF_GRACE_SECONDS="${JIT_HANDOFF_GRACE_SECONDS:-300}"' "$script"
grep -Fq 'Runner_*' "$script"
grep -Fq 'Worker_*' "$script"
grep -Fq '[REDACTED]' "$script"

# Every lifecycle phase is explicit and an ambiguous create checks exact remote
# state before releasing the resource reservation.
for phase in admitted jit_received container_create_started container_observed \
  secret_consumed running terminal deleting deleted failed; do
  grep -Fq "$phase" "$script" || crf_fail "missing JIT phase $phase"
done

grep -Fq 'if jit_container_exists "$container"' "$script"
echo "scale-set-runtime: OK"
