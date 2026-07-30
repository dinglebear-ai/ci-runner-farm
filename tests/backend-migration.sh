#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

migration=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-migration.sh
engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
endpoint=src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php

grep -Fq 'POOL_BACKEND is requested intent only' "$migration"
grep -Fq 'backend_classic_admission_allowed' "$engine"
grep -Fq 'backend_scaleset_admission_allowed' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh
grep -Fq "case 'begin-migration': case 'rollback-backend':" "$endpoint"
! grep -A100 "case 'apply-config':" "$endpoint" | grep -q 'begin-migration'

while IFS='|' read -r direction from to before after barrier; do
  [[ "$direction" == \#* ]] && continue
  grep -Fq "$from" "$migration" || crf_fail "missing migration phase $from"
  grep -Fq "$to" "$migration" || crf_fail "missing migration phase $to"
  [ -n "$before$after$barrier" ]
done < tests/fixtures/migration.tsv

# Production defaults fail closed: only the test gate can emulate remote
# eligibility proof.
bash -c '
  set -u
  RUNDIR=$(mktemp -d); CFGDIR=$RUNDIR; CACHE_ROOT=$RUNDIR; SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  err(){ :; }
  . "$SCRIPT_DIR/runner-scalesets.sh"
  ! scaleset_prepare_ineligible x
'

# Exercise every persisted phase with exact revisions. Test gates stand in for
# the remote eligibility operations; production defaults above remain closed.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; CACHE_ROOT=$root/cache
  mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  POOL_BACKEND=scaleset
  SCALESET_COMPAT=$CFGDIR/scaleset-compatibility.json
  MIGRATION_STATE=$CFGDIR/backend-transition.json
  JIT_STATE_DIR=$RUNDIR/jit
  expected=$(printf a%.0s {1..64}); ownership=$(printf b%.0s {1..64}); compatibility=$(printf c%.0s {1..64})
  config_revision(){ printf "%s\n" "$expected"; }
  err(){ :; }
  . "$SCRIPT_DIR/runner-scalesets.sh"
  . "$SCRIPT_DIR/runner-migration.sh"
  scaleset_supervisor_start(){ return 0; }
  scaleset_record_valid(){ return 0; }
  jit_reconcile(){ return 0; }
  cat >"$SCALESET_COMPAT" <<EOF
{"compatibility_record_id":"$compatibility","cleanup":{"complete":true},"capabilities":{"eligibility_barrier":true}}
EOF
  chmod 0600 "$SCALESET_COMPAT"
  CRF_MIGRATION_TEST_GATES=1
  migration_load
  migration_start "$expected" "$ownership" "$compatibility" "$MIGRATION_REVISION"
  [ "$MIGRATION_PHASE" = quiescing_classic ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ]
  migration_advance_forward
  [ "$MIGRATION_PHASE" = classic_ineligible ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ]
  migration_advance_forward
  [ "$MIGRATION_PHASE" = activating_scaleset ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ]
  migration_advance_forward
  [ "$MIGRATION_PHASE" = scaleset_active ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = scaleset ]
  migration_rollback "$expected" "$ownership" "$compatibility" "$MIGRATION_REVISION"
  [ "$MIGRATION_PHASE" = scaleset_ineligible ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = scaleset ]
  migration_advance_reverse
  [ "$MIGRATION_PHASE" = draining_assigned_jit ]
  migration_advance_reverse
  [ "$MIGRATION_PHASE" = activating_classic ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = scaleset ]
  migration_advance_reverse
  [ "$MIGRATION_PHASE" = classic_active ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ]
  [ "$(stat -c %a "$MIGRATION_STATE")" = 600 ]
'

php -l "$endpoint" >/dev/null
echo "backend-migration: OK"
