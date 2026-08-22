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
grep -Fq 'classic-quarantine.json' "$migration"
grep -Fq 'migration_quarantine_move_all' "$migration"
grep -Fq 'migration_classic_names' "$migration"
grep -Fq 'MIGRATION_CLASSIC_ACTIVATION=1 cmd_start' "$migration"
grep -Fq 'classic:quiescing_classic:scaleset_ineligible' "$migration"
grep -Fq 'classic:quiescing_classic:scaleset_ineligible' "$engine"
grep -Fq 'inventory_backend_names "$teardown_backend"' "$engine"
grep -Fq 'scaleset_activation_prove_effective' "$migration"
grep -Fq 'scaleset_publish_zero_capacity' "$migration"
grep -Fq -- '--data-binary "$request_body"' "$engine"
grep -Fq "case 'begin-migration': case 'rollback-backend':" "$endpoint"
! grep -A100 "case 'apply-config':" "$endpoint" | grep -q 'begin-migration'

while IFS='|' read -r direction from to before after barrier; do
  [[ "$direction" == \#* ]] && continue
  grep -Fq "$from" "$migration" || crf_fail "missing migration phase $from"
  grep -Fq "$to" "$migration" || crf_fail "missing migration phase $to"
  [ -n "$before$after$barrier" ]
done < tests/fixtures/migration.tsv

# Migration start compares every caller authority before its first durable
# write. A stale ownership revision must return the stable code and leave the
# transition file byte-for-byte unchanged.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; mkdir -p "$RUNDIR" "$CFGDIR"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  MIGRATION_FILE=$CFGDIR/backend-migration.json
  expected=$(printf config | sha256sum | cut -d" " -f1)
  current_ownership=$(printf ownership-current | sha256sum | cut -d" " -f1)
  stale_ownership=$(printf ownership-stale | sha256sum | cut -d" " -f1)
  compatibility=$(printf compatibility | sha256sum | cut -d" " -f1)
  transition=$(printf transition | sha256sum | cut -d" " -f1)
  printf "%s\n" original-transition-bytes >"$MIGRATION_FILE"
  before=$(sha256sum "$MIGRATION_FILE" | cut -d" " -f1)
  . "$SCRIPT_DIR/runner-migration.sh"
  err(){ :; }
  migration_load(){
    MIGRATION_REVISION=$transition
    MIGRATION_PHASE=classic_active
    MIGRATION_EFFECTIVE_BACKEND=classic
  }
  config_revision(){ printf "%s\n" "$expected"; }
  scaleset_ownership_revision(){ printf "%s\n" "$current_ownership"; }
  migration_record_matches(){ return 0; }
  migration_write(){ printf mutated >"$MIGRATION_FILE"; }
  POOL_BACKEND=scaleset
  set +e
  migration_start "$expected" "$stale_ownership" "$compatibility" "$transition" >"$root/output"
  rc=$?
  set -e
  output=$(cat "$root/output")
  [ "$rc" -eq 3 ] || { printf "unexpected stale-ownership rc=%s output=%s\n" "$rc" "$output" >&2; exit 1; }
  printf "%s" "$output" | php -r '\''$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["code"]??"")==="ownership_changed"?0:1);'\''
  after=$(sha256sum "$MIGRATION_FILE" | cut -d" " -f1)
  [ "$before" = "$after" ]
'

# Interrupted forward migration may restore classic capacity only after the
# locally-created scale sets are remotely proven ineligible.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; mkdir -p "$RUNDIR" "$CFGDIR"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  . "$SCRIPT_DIR/runner-migration.sh"
  migration_load(){
    MIGRATION_EFFECTIVE_BACKEND=classic
    MIGRATION_PHASE=quiescing_classic
    MIGRATION_LAST_BARRIER=scaleset_ineligible
  }
  backend_classic_admission_allowed
  MIGRATION_LAST_BARRIER=classic_only
  migration_load(){ :; }
  ! backend_classic_admission_allowed
'

# The shared managed label includes distributed and JIT containers. Backend
# migration must select only exact fixed classic identities from that inventory.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; mkdir -p "$RUNDIR" "$CFGDIR"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  NAME_PREFIX=ci-runner
  pool_id_valid(){ [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]; }
  managed_names(){ printf "%s\n" \
    ci-runner-1 ci-runner-rust-2 \
    ci-runner-dist-acceptance-container-a71846cd1dc5d0e8f83f65c6 \
    ci-runner-jit-rust-a71846cd1dc5d0e8f83f \
    ci-runner-rust-notanindex unrelated; }
  . "$SCRIPT_DIR/runner-migration.sh"
  [ "$(migration_classic_names | sort | tr "\n" " ")" = "ci-runner-1 ci-runner-rust-2 " ]
  [ "$(migration_classic_count)" = 2 ]
'

# Classic quiesce removes only GitHub-proven idle runners and preserves busy
# work until a later continuation.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; CACHE_ROOT=$root/cache; mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  MIGRATION_CLASSIC_QUIESCE_FILE=$RUNDIR/quiesced
  MIGRATION_TRANSITION_ID=transition
  MIGRATION_TARGET_CONFIG_REVISION=$(printf a%.0s {1..64})
  GH_OWNER=dinglebear-ai; NAME_PREFIX=ci-runner
  err(){ :; }
  . "$SCRIPT_DIR/runner-migration.sh"
  migration_quarantine_ensure(){ return 0; }
  migration_quarantine_move_all(){ return 0; }
  runners="ci-runner-rust-1 ci-runner-python-1"
  fleet_inventory_refresh(){ : >"$RUNDIR/inventory"; }
  github_phase_refresh(){ return 0; }
  managed_names(){ printf "%s\n" $runners; }
  current_count(){ set -- $runners; printf "%s\n" "$#"; }
  runner_state(){ [ "$1" = ci-runner-rust-1 ] && echo busy || echo idle; }
  remove_runner(){ runners="${runners/ $1/}"; runners="${runners/$1 /}"; runners="${runners/$1/}"; }
  ! migration_classic_quiesce
  case " $runners " in *" ci-runner-rust-1 "*) ;; *) exit 1 ;; esac
  case " $runners " in *" ci-runner-python-1 "*) exit 1 ;; esac
  [ -f "$MIGRATION_CLASSIC_QUIESCE_FILE" ]
'

# The classic admission barrier is a remotely enforced, installation-owned
# runner group. Creation is intent-first and recovers an accepted POST whose
# response was lost; moves are exact by runner ID and cleanup deletes only the
# recorded group.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; mkdir -p "$RUNDIR" "$CFGDIR"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  MIGRATION_CLASSIC_QUARANTINE_STATE=$CFGDIR/classic-quarantine.json
  GH_SCOPE=org; GH_OWNER=dinglebear-ai; NAME_PREFIX=ci-runner
  ACCESS_TOKEN=test-token
  err(){ printf "%s\n" "$*" >&2; }
  log(){ :; }
  host(){ echo nashost; }
  scaleset_installation_id(){ echo 11111111-2222-3333-4444-555555555555; }
  . "$SCRIPT_DIR/runner-migration.sh"
  managed_names(){ printf "%s\n" ci-runner-rust-1 ci-runner-python-1; }
  github_runner_inventory(){
    printf "%s\n" \
      "101|nashost-ci-runner-rust-1|online|1" \
      "102|ci-runner-python-1|online|0"
  }
  gh_api_request(){
    local method=$1 path=$2 body=${3:-}
    GH_RESPONSE=""; GH_STATUS=200
    printf "%s|%s|%s\n" "$method" "$path" "$body" >>"$root/requests"
    case "$method:$path" in
      "GET:/orgs/dinglebear-ai/actions/runner-groups?per_page=100&page=1")
        if [ -f "$root/group-created" ]; then
          GH_RESPONSE='\''{"runner_groups":[{"id":77,"name":"crf-quarantine-9193c4798a343ce0","visibility":"selected","allows_public_repositories":false}]}'\''
        else
          GH_RESPONSE='\''{"runner_groups":[]}'\''
        fi
        ;;
      "POST:/orgs/dinglebear-ai/actions/runner-groups")
        grep -Fq '\''"visibility":"selected"'\'' <<<"$body"
        grep -Fq '\''"allows_public_repositories":false'\'' <<<"$body"
        : >"$root/group-created"
        GH_STATUS=500
        return 1
        ;;
      "PUT:/orgs/dinglebear-ai/actions/runner-groups/77/runners/101")
        echo 101 >>"$root/moved"; GH_STATUS=204 ;;
      "PUT:/orgs/dinglebear-ai/actions/runner-groups/77/runners/102")
        echo 102 >>"$root/moved"; GH_STATUS=204 ;;
      "GET:/orgs/dinglebear-ai/actions/runner-groups/77/runners?per_page=100&page=1")
        GH_RESPONSE='\''{"runners":[{"id":101,"name":"nashost-ci-runner-rust-1","status":"online","busy":true},{"id":102,"name":"ci-runner-python-1","status":"online","busy":false}]}'\''
        ;;
      "DELETE:/orgs/dinglebear-ai/actions/runner-groups/77")
        rm -f "$root/group-created"; GH_STATUS=204 ;;
      *) printf "unexpected request: %s %s\n" "$method" "$path" >&2; return 1 ;;
    esac
  }
  migration_quarantine_ensure
  [ "$MIGRATION_QUARANTINE_GROUP_ID" = 77 ]
  [ "$(stat -c %a "$MIGRATION_CLASSIC_QUARANTINE_STATE")" = 600 ]
  php -r '\''
    $j=json_decode(file_get_contents($argv[1]),true);
    exit(($j["phase"]??"")==="active" && ($j["group_id"]??0)===77 ? 0 : 1);
  '\'' "$MIGRATION_CLASSIC_QUARANTINE_STATE"
  migration_quarantine_move_all
  [ "$(sort -n "$root/moved" | tr "\n" " ")" = "101 102 " ]
  migration_quarantine_delete
  [ ! -e "$MIGRATION_CLASSIC_QUARANTINE_STATE" ]
  [ ! -e "$root/group-created" ]
'

# A failed remote inventory must fail the eligibility barrier; process
# substitution must not hide the producer exit code.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; mkdir -p "$RUNDIR" "$CFGDIR"
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  MIGRATION_CLASSIC_QUIESCE_FILE=$RUNDIR/quiesced
  GH_OWNER=dinglebear-ai; NAME_PREFIX=ci-runner
  err(){ :; }; host(){ echo nashost; }
  fleet_inventory_refresh(){ return 0; }; current_count(){ echo 0; }
  github_runner_inventory(){ return 7; }
  . "$SCRIPT_DIR/runner-migration.sh"
  : >"$MIGRATION_CLASSIC_QUIESCE_FILE"
  ! migration_classic_prove_ineligible
'

# Rollback drain proof fails closed on every remaining authority: nonterminal
# JIT state, resource reservations, assigned/leased GitHub work, stale or
# pre-barrier session evidence, mismatched identities, and managed JIT containers.
bash -c '
  set -euo pipefail
  root=$(mktemp -d); trap "rm -rf \"$root\"" EXIT
  RUNDIR=$root/run; CFGDIR=$root/cfg; JIT_STATE_DIR=$root/jit
  RESERVATION_DIR=$root/reservations; SCALESET_STATE_DIR=$root/scaleset
  SCALESET_SNAPSHOT=$SCALESET_STATE_DIR/snapshot.json
  SCALESET_PID=$SCALESET_STATE_DIR/supervisor.pid
  SCALESET_SOCKET=$SCALESET_STATE_DIR/supervisor.sock
  SCALESET_OWNERSHIP=$CFGDIR/scale-set-ownership.json
  INVENTORY_FILE=$RUNDIR/inventory
  mkdir -p "$RUNDIR" "$CFGDIR" "$JIT_STATE_DIR" "$RESERVATION_DIR" "$SCALESET_STATE_DIR"
  config=$(printf a%.0s {1..64}); ownership=$(printf b%.0s {1..64})
  MIGRATION_TARGET_CONFIG_REVISION=$config
  MIGRATION_OWNERSHIP_REVISION=$ownership
  ownership_updated=$(date -u -d "-30 seconds" +%Y-%m-%dT%H:%M:%SZ)
  write_ownership(){
    local state="${1:-ineligible}" scale_id="${2:-41}" config_rev="${3:-$config}" updated="${4:-$ownership_updated}"
    printf "{\"schema_version\":2,\"config_revision\":\"%s\",\"records\":[{\"pool_id\":\"python\",\"state\":\"%s\",\"scale_set_id\":%s,\"updated_at\":\"%s\"}]}\n" \
      "$config_rev" "$state" "$scale_id" "$updated" >"$SCALESET_OWNERSHIP"
  }
  write_ownership
  SCRIPT_DIR=$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include
  err(){ :; }
  jit_state_field(){ sed -n "s/^$2=//p" "$1" | head -1; }
  reservation_field(){ sed -n "s/^$2=//p" "$1" | head -1; }
  reservation_release(){ rm -f "$RESERVATION_DIR/$1.state"; }
  snapshot_mode=good; inventory_mode=empty
  scaleset_snapshot_refresh(){
    local observed valid assigned=0 capacity=0 handles="[]" healthy=true refresh_rc=0
    local snapshot_config="$config" snapshot_ownership="$ownership" scale_id=41
    observed=$(date -u -d "-5 seconds" +%Y-%m-%dT%H:%M:%SZ)
    valid=$(date -u -d "+20 seconds" +%Y-%m-%dT%H:%M:%SZ)
    case "$snapshot_mode" in
      assigned) assigned=1 ;;
      handles) handles="[501]" ;;
      capacity) capacity=1 ;;
      stale) observed=$(date -u -d "-2 minutes" +%Y-%m-%dT%H:%M:%SZ); valid=$(date -u -d "-1 minute" +%Y-%m-%dT%H:%M:%SZ) ;;
      unhealthy) healthy=false ;;
      zero) healthy=false; observed=0001-01-01T00:00:00Z; valid=0001-01-01T00:00:00Z ;;
      stopped) healthy=false; observed=$(date -u -d "-20 seconds" +%Y-%m-%dT%H:%M:%SZ); valid=$(date -u -d "-10 seconds" +%Y-%m-%dT%H:%M:%SZ); refresh_rc=1 ;;
      prebarrier) observed=$(date -u -d "-40 seconds" +%Y-%m-%dT%H:%M:%SZ) ;;
      null_handles) handles=null ;;
      wrong_scale) scale_id=99 ;;
      wrong_config) snapshot_config=$(printf c%.0s {1..64}) ;;
      wrong_ownership) snapshot_ownership=$(printf d%.0s {1..64}) ;;
    esac
    printf "{\"schema_version\":1,\"controller_instance_id\":\"controller\",\"config_revision\":\"%s\",\"ownership_revision\":\"%s\",\"sequence\":1,\"observed_at\":\"%s\",\"valid_until\":\"%s\",\"pools\":[{\"pool_id\":\"python\",\"scale_set_id\":%s,\"assigned_jobs\":%s,\"advertised_capacity\":%s,\"last_message_id\":1,\"session_healthy\":%s,\"acquired_handles\":%s,\"observed_at\":\"%s\",\"valid_until\":\"%s\"}]}\n" \
      "$snapshot_config" "$snapshot_ownership" "$observed" "$valid" "$scale_id" "$assigned" "$capacity" "$healthy" "$handles" "$observed" "$valid" >"$SCALESET_SNAPSHOT"
    return "$refresh_rc"
  }
  fleet_inventory_refresh(){
    : >"$INVENTORY_FILE"
    [ "$inventory_mode" = jit ] &&
      printf "runner|running|x|x|x|x|python|x|x|x|valid|scaleset\n" >"$INVENTORY_FILE"
    return 0
  }
  . "$SCRIPT_DIR/runner-migration.sh"
  MIGRATION_TARGET_CONFIG_REVISION=$config
  MIGRATION_OWNERSHIP_REVISION=$ownership
  MIGRATION_PHASE=draining_assigned_jit
  MIGRATION_LAST_BARRIER=scaleset_ineligible
  migration_jit_drained
  printf "phase=running\n" >"$JIT_STATE_DIR/runner.state"
  ! migration_jit_drained
  printf "phase=deleted\n" >"$JIT_STATE_DIR/runner.state"
  printf "phase=assigned\n" >"$RESERVATION_DIR/work.state"
  ! migration_jit_drained
  rm -f "$RESERVATION_DIR/work.state"
  snapshot_mode=assigned; ! migration_jit_drained
  snapshot_mode=handles; ! migration_jit_drained
  snapshot_mode=capacity; ! migration_jit_drained
  snapshot_mode=stale; ! migration_jit_drained
  snapshot_mode=unhealthy; migration_jit_drained
  snapshot_mode=zero; ! migration_jit_drained
  snapshot_mode=null_handles; ! migration_jit_drained
  snapshot_mode=wrong_scale; ! migration_jit_drained
  snapshot_mode=wrong_config; ! migration_jit_drained
  snapshot_mode=wrong_ownership; ! migration_jit_drained
  snapshot_mode=prebarrier; ! migration_jit_drained
  snapshot_mode=stopped; migration_jit_drained
  write_ownership eligible
  ! migration_jit_drained
  write_ownership ineligible
  snapshot_mode=good; inventory_mode=jit; ! migration_jit_drained
  inventory_mode=empty
  printf "phase=offered\n" >"$RESERVATION_DIR/offer.state"
  migration_jit_drained
  [ ! -e "$RESERVATION_DIR/offer.state" ]
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
  GH_OWNER=dinglebear-ai
  NAME_PREFIX=ci-runner
  SCALESET_COMPAT=$CFGDIR/scaleset-compatibility.json
  MIGRATION_STATE=$CFGDIR/backend-transition.json
  JIT_STATE_DIR=$RUNDIR/jit
  expected=$(printf a%.0s {1..64}); ownership=$(printf b%.0s {1..64}); compatibility=$(printf c%.0s {1..64})
  config_revision(){ printf "%s\n" "$expected"; }
  err(){ :; }
  . "$SCRIPT_DIR/runner-scalesets.sh"
  . "$SCRIPT_DIR/runner-migration.sh"
  migration_quarantine_ensure(){ return 0; }
  migration_quarantine_move_all(){ return 0; }
  migration_quarantine_delete(){ return 0; }
  scaleset_supervisor_start(){ return 0; }
  scaleset_autoscale_tick(){ return 0; }
  scaleset_activation_prove_effective(){ return 0; }
  scaleset_publish_zero_capacity(){ return 0; }
  scaleset_record_valid(){ return 0; }
  scaleset_request(){ return 0; }
  jit_reconcile(){ return 0; }
  migration_jit_drained(){ return 0; }
  runners=""
  fleet_inventory_refresh(){ : >"$RUNDIR/inventory"; }
  github_phase_refresh(){ return 0; }
  managed_names(){ printf "%s\n" $runners; }
  current_count(){ set -- $runners; printf "%s\n" "$#"; }
  runner_state(){ echo idle; }
  remove_runner(){ runners="${runners/ $1/}"; runners="${runners/$1 /}"; runners="${runners/$1/}"; }
  github_runner_inventory(){ return 0; }
  host(){ echo nashost; }
  cmd_start(){ runners="ci-runner-python-1"; }
  cat >"$SCALESET_COMPAT" <<EOF
{"compatibility_record_id":"$compatibility","runner_group_id":7,"quarantine_runner_group_id":8,"cleanup":{"complete":true},"capabilities":{"eligibility_barrier":true}}
EOF
  chmod 0600 "$SCALESET_COMPAT"
  scaleset_ownership_revision(){ printf "%s\n" "$ownership"; }
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
  backend_classic_admission_allowed
  ! backend_scaleset_admission_allowed
  migration_advance_reverse
  [ "$MIGRATION_PHASE" = classic_active ] && [ "$MIGRATION_EFFECTIVE_BACKEND" = classic ]
  [ "$(stat -c %a "$MIGRATION_STATE")" = 600 ]
'

php -l "$endpoint" >/dev/null
echo "backend-migration: OK"
