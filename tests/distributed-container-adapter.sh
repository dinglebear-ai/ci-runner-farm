#!/usr/bin/env bash
# Dynamic globals/sources intentionally model runner-farm's sourced shell runtime.
# Literal grep patterns intentionally contain $SCRIPT_DIR text.
# shellcheck disable=SC1090,SC1091,SC2034,SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

ROOT="$PWD"
INCLUDE="$ROOT/src/usr/local/emhttp/plugins/ci-runner-farm/include"
ADAPTER="$INCLUDE/runner-distributed-adapter.sh"
PARSER="$INCLUDE/runner-container-adapter-parser.php"
ENGINE="$INCLUDE/runner-farm.sh"
WRAPPER="$INCLUDE/runner-container-adapter.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

RUNDIR="$tmp/run"
CACHE_ROOT="$tmp/cache"
SCRIPT_DIR="$INCLUDE"
RESERVATION_DIR="$RUNDIR/reservations"
NAME_PREFIX=ci-runner
LABEL_NS=net.unraid.ci-runner-farm
MANAGED_LABEL=net.unraid.ci-runner-farm.managed=true
GH_OWNER=acme
mkdir -p "$RUNDIR" "$CACHE_ROOT" "$RESERVATION_DIR"

jit_id_valid(){ [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; }
pool_id_valid(){ [[ "${1:-}" =~ ^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$ ]]; }
pool_cpu_milli(){ [ "$1" = default ] && printf '1000\n'; }
pool_memory_bytes(){ [ "$1" = default ] && printf '1073741824\n'; }
pool_runner_spec_hash(){ [ "$1" = default ] && printf 'spec-default\n'; }
pool_config_revision(){ printf 'rev-1\n'; }
. "$INCLUDE/runner-resources.sh"
. "$INCLUDE/runner-runtime.sh"
. "$ADAPTER"

# Use the production protected FIFO helper, with only inventory validation stubbed
# because this fixture intentionally bypasses the fleet-inventory implementation.
snippet="$tmp/secret-helper.sh"
sed -n '/^runner_secret_inject()/,/^}/p' "$ENGINE" >"$snippet"
. "$snippet"
runner_identity_validate(){ return 1; }

FAKE_EXISTS=0
FAKE_STATUS=running
FAKE_EXIT=0
FAKE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FAKE_NAME=""
declare -A FAKE_LABELS=()
run_calls=0
secret_calls_file="$tmp/secret.calls"
run_args="$tmp/docker-run.args"
secret_file="$tmp/secret.seen"
consumed_file="$tmp/consumed"
secret_call_count(){ [ -f "$secret_calls_file" ] && cat "$secret_calls_file" || printf '0\n'; }
inc_secret_call(){ local n; n="$(secret_call_count)"; printf '%s\n' "$((n+1))" >"$secret_calls_file"; }

fake_reset_container(){
  FAKE_EXISTS=0; FAKE_STATUS=running; FAKE_EXIT=0; FAKE_NAME=""; FAKE_LABELS=(); rm -f "$consumed_file"
}
fake_seed_container(){
  local placement="$1" command="$2" runner="$3" managed="${4:-true}"
  FAKE_EXISTS=1; FAKE_STATUS=running; FAKE_EXIT=0; rm -f "$consumed_file"
  FAKE_NAME="$(distributed_adapter_container_name "$placement" default)"
  FAKE_LABELS["${MANAGED_LABEL%=*}"]="$managed"
  FAKE_LABELS["${LABEL_NS}.backend"]=distributed
  FAKE_LABELS["${LABEL_NS}.placement-id"]="$placement"
  FAKE_LABELS["${LABEL_NS}.command-id"]="$command"
  FAKE_LABELS["${LABEL_NS}.pool"]=default
  FAKE_LABELS["${LABEL_NS}.requested-runner-name"]="$runner"
  FAKE_LABELS["${LABEL_NS}.cpu-milli"]=1000
  FAKE_LABELS["${LABEL_NS}.memory-bytes"]=1073741824
  FAKE_LABELS["${LABEL_NS}.runner-spec-hash"]=spec-default
  FAKE_LABELS["${LABEL_NS}.config-revision"]=rev-1
}

build_args(){
  local _idx="$1" name="$2" pool="$3"
  ARGS=(
    -d --restart=no --name "$name"
    --label "${MANAGED_LABEL%=*}=true"
    --label "${LABEL_NS}.backend=classic"
    --label "${LABEL_NS}.pool=$pool"
    --label "${LABEL_NS}.runner-spec-hash=$(pool_runner_spec_hash "$pool")"
    --label "${LABEL_NS}.config-revision=$(pool_config_revision)"
    --label "${LABEL_NS}.cpu-milli=$(pool_cpu_milli "$pool")"
    --label "${LABEL_NS}.memory-bytes=$(pool_memory_bytes "$pool")"
    fake-image /listener-command
  )
  CRF_IMAGE_ARG_INDEX=$((${#ARGS[@]} - 2))
}

docker(){
  local op="${1:-}" fmt ref key value arg
  shift || true
  case "$op" in
    run)
      run_calls=$((run_calls + 1))
      : >"$run_args"; printf '%s\n' "$@" >"$run_args"
      FAKE_LABELS=(); FAKE_NAME=""
      while [ "$#" -gt 0 ]; do
        arg="$1"; shift
        case "$arg" in
          --name) FAKE_NAME="$1"; shift ;;
          --label)
            key="${1%%=*}"; value="${1#*=}"; FAKE_LABELS["$key"]="$value"; shift ;;
        esac
      done
      if [ "${FAKE_RUN_NO_CREATE:-0}" = 1 ]; then return 42; fi
      FAKE_EXISTS=1; FAKE_STATUS=running; FAKE_EXIT=0; rm -f "$consumed_file"
      [ "${FAKE_RUN_RC:-0}" = 0 ] || return "$FAKE_RUN_RC"
      ;;
    ps)
      [ "$FAKE_EXISTS" = 1 ] || return 0
      case "$*" in
        *"label=${LABEL_NS}.placement-id=${FAKE_LABELS[${LABEL_NS}.placement-id]:-}"*) printf '%s\n' "${FAKE_ID:0:12}" ;;
      esac
      ;;
    inspect)
      if [ "${1:-}" = --format ]; then
        fmt="$2"; ref="$3"
        [ "$FAKE_EXISTS" = 1 ] && { [ "$ref" = "$FAKE_ID" ] || [ "$ref" = "${FAKE_ID:0:12}" ] || [ "$ref" = "$FAKE_NAME" ]; } || return 1
        case "$fmt" in
          '{{.Id}}') printf '%s' "$FAKE_ID" ;;
          '{{.Name}}') printf '/%s' "$FAKE_NAME" ;;
          *'.State.Status'*) printf '%s' "$FAKE_STATUS" ;;
          *'.State.ExitCode'*) printf '%s' "$FAKE_EXIT" ;;
          *'.Config.Labels'*)
            key="${fmt#*\"}"; key="${key%%\"*}"; printf '%s' "${FAKE_LABELS[$key]:-<no value>}" ;;
          *) return 1 ;;
        esac
      else
        ref="${1:-}"
        [ "$FAKE_EXISTS" = 1 ] && { [ "$ref" = "$FAKE_ID" ] || [ "$ref" = "$FAKE_NAME" ]; }
      fi
      ;;
    exec)
      if [ "${1:-}" = -i ]; then shift; fi
      ref="$1"; shift
      [ "$FAKE_EXISTS" = 1 ] && { [ "$ref" = "$FAKE_ID" ] || [ "$ref" = "$FAKE_NAME" ]; } || return 1
      case "$*" in
        *'cat > /run/crf/secret.in'*)
          IFS= read -r value || true; printf '%s' "$value" >"$secret_file"; inc_secret_call; : >"$consumed_file" ;;
        *'test -f /run/crf/consumed'*) [ -f "$consumed_file" ] ;;
        *'/run/crf/ready'*) return 0 ;;
        *'/run/crf/consumed'*) [ -f "$consumed_file" ] ;;
        *) return 1 ;;
      esac
      ;;
    logs) printf 'fake runner log\n' ;;
    stop) FAKE_STATUS=exited ;;
    rm)
      [ "${1:-}" = -f ] && shift
      ref="${1:-}"; [ "$ref" = "$FAKE_ID" ] || [ "$ref" = "$FAKE_NAME" ] || return 1
      [ "${FAKE_REMOVE_FAIL:-0}" != 1 ] || return 23
      FAKE_EXISTS=0
      ;;
    *) crf_fail "unexpected docker call: $op $*" ;;
  esac
}

start_json(){
  local placement="$1" command="$2" runner="$3" secret="${4:-jit-secret-abc==}"
  printf '{"schema_version":1,"payload":{"action":"start","placement_id":"%s","command_id":"%s","pool_id":"default","runner_name":"%s","resources":{"cpu_millis":1000,"memory_bytes":1073741824},"jit_config":"%s"}}' "$placement" "$command" "$runner" "$secret"
}
inspect_json(){ local p="$1" id="${2:-}"; [ -n "$id" ] && id="\"$id\"" || id=null; printf '{"schema_version":1,"payload":{"action":"inspect","placement_id":"%s","expected_id":%s}}' "$p" "$id"; }
cancel_json(){ local p="$1" id="${2:-}"; [ -n "$id" ] && id="\"$id\"" || id=null; printf '{"schema_version":1,"payload":{"action":"cancel","placement_id":"%s","expected_id":%s}}' "$p" "$id"; }
call_adapter(){
  local input="$1"
  cmd_distributed_adapter <<<"$input" >"$tmp/reply"
  reply="$(cat "$tmp/reply")"
}

# A missing state record and missing container is a clean absence, not an
# ambiguous inventory failure. This also protects the real exit status from
# being lost through shell `!` negation.
call_adapter "$(inspect_json placement-absent)"
crf_assert_contains "$reply" '"result":"absent"' 'clean absence was misclassified as ambiguous'

# Parser rejects unknown fields and produces no accepted request.
if printf '%s' '{"schema_version":1,"payload":{"action":"inspect","placement_id":"p1","expected_id":null,"extra":true}}' | php "$PARSER" >/dev/null 2>&1; then
  crf_fail 'parser accepted an unknown field'
fi

# Fresh Start: one Docker create, secret only through FIFO helper, durable non-secret state.
secret='jit-secret-abc=='
call_adapter "$(start_json placement-1 command-1 runner-1 "$secret")"
crf_assert_contains "$reply" '"result":"started"' 'fresh distributed start was not accepted'
crf_assert_contains "$reply" "\"id\":\"$FAKE_ID\"" 'fresh start lost immutable container id'
[ "$run_calls" = 1 ] || crf_fail 'fresh start did not create exactly one container'
[ "$(cat "$secret_file")" = "$secret" ] || crf_fail 'JIT secret was not delivered through protected handoff'
! grep -Fq "$secret" "$run_args" || crf_fail 'JIT secret leaked into docker run arguments'
[ "${FAKE_LABELS[${LABEL_NS}.backend]}" = distributed ] || crf_fail 'distributed backend label did not override classic build args'
[ "${FAKE_LABELS[${MANAGED_LABEL%=*}]}" = true ] || crf_fail 'managed label was lost'
state="$(distributed_adapter_state_path placement-1)"
[ "$(stat -c %a "$state")" = 600 ] || crf_fail 'distributed state is not mode 0600'
[ "$(distributed_adapter_state_field "$state" phase)" = running ] || crf_fail 'fresh start did not become running'
! grep -Fq "$secret" "$state" || crf_fail 'JIT secret leaked into durable adapter state'

# Inspect and exact-ID cancel fencing.
call_adapter "$(inspect_json placement-1 "$FAKE_ID")"
crf_assert_contains "$reply" '"result":"running"' 'running container was not observed'
wrong=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
call_adapter "$(cancel_json placement-1 "$wrong")"
crf_assert_contains "$reply" 'runtime_identity_mismatch' 'wrong-id cancel was not fenced'
[ "$FAKE_EXISTS" = 1 ] || crf_fail 'wrong-id cancel removed the container'

# State loss must reconstruct the exact container identity but still reject a conflicting Start.
rm -f "$state"
before_secret_calls="$(secret_call_count)"
call_adapter "$(start_json placement-1 command-2 runner-1 "$secret")"
crf_assert_contains "$reply" 'placement_conflict' 'state-loss recovery accepted a conflicting Start'
[ "$run_calls" = 1 ] || crf_fail 'state-loss conflict created another container'
[ "$(secret_call_count)" = "$before_secret_calls" ] || crf_fail 'state-loss conflict replayed the secret'

FAKE_REMOVE_FAIL=1
call_adapter "$(cancel_json placement-1 "$FAKE_ID")"
crf_assert_contains "$reply" 'container_cancel_uncertain' 'failed exact-id removal was not deferred'
[ "$FAKE_EXISTS" = 1 ] || crf_fail 'failed cancellation unexpectedly removed the container'
[ "$(distributed_adapter_state_field "$state" phase)" = cancelling ] || crf_fail 'cancel-in-progress was not durably fenced before removal'
call_adapter "$(inspect_json placement-1 "$FAKE_ID")"
crf_assert_contains "$reply" 'container_cancel_pending' 'inspect did not preserve cancel-in-progress fence'
FAKE_REMOVE_FAIL=0
call_adapter "$(cancel_json placement-1 "$FAKE_ID")"
crf_assert_contains "$reply" '"result":"cancelled"' 'exact-id cancellation replay failed'
[ "$FAKE_EXISTS" = 0 ] || crf_fail 'exact-id cancellation left the container alive'
[ "$(distributed_adapter_state_field "$state" terminal_kind)" = cancelled ] || crf_fail 'cancel was not durably terminal after removal'

# Prepared is safe to replay: Inspect asks Rust to resend Start and Start performs one create.
fake_reset_container
distributed_adapter_policy_prepare placement-prepared command-prepared default runner-prepared 1000 1073741824
distributed_adapter_state_store "" prepared
call_adapter "$(inspect_json placement-prepared)"
crf_assert_contains "$reply" 'container_start_prepared' 'prepared crash state did not advertise safe replay'
before_runs=$run_calls
call_adapter "$(start_json placement-prepared command-prepared runner-prepared)"
crf_assert_contains "$reply" '"result":"started"' 'prepared Start replay did not resume launch'
[ "$run_calls" = $((before_runs + 1)) ] || crf_fail 'prepared replay did not create exactly once'

# A real Docker client/daemon ambiguity is fenced before launch and never retried.
fake_reset_container
FAKE_RUN_NO_CREATE=1
before_runs=$run_calls
before_secret_calls="$(secret_call_count)"
call_adapter "$(start_json placement-uncertain command-uncertain runner-uncertain)"
crf_assert_contains "$reply" 'container_start_uncertain' 'failed Docker create was not durably fenced'
[ "$run_calls" = $((before_runs + 1)) ] || crf_fail 'ambiguous create did not attempt Docker exactly once'
uncertain_state="$(distributed_adapter_state_path placement-uncertain)"
[ "$(distributed_adapter_state_field "$uncertain_state" phase)" = starting ] || crf_fail 'ambiguous create did not preserve starting fence'
uncertain_reservation="$(distributed_adapter_state_field "$uncertain_state" reservation_id)"
[ -f "$RESERVATION_DIR/$uncertain_reservation.state" ] || crf_fail 'ambiguous create released its reservation'
[ "$(secret_call_count)" = "$before_secret_calls" ] || crf_fail 'ambiguous create attempted secret handoff'
unset FAKE_RUN_NO_CREATE
call_adapter "$(start_json placement-uncertain command-uncertain runner-uncertain)"
crf_assert_contains "$reply" 'container_start_uncertain' 'ambiguous create replay was not deferred'
[ "$run_calls" = $((before_runs + 1)) ] || crf_fail 'ambiguous create replay launched a duplicate'

# A nonzero Docker client result can still be adopted when the daemon created the exact container.
fake_reset_container
FAKE_RUN_RC=42
before_runs=$run_calls
before_secret_calls="$(secret_call_count)"
call_adapter "$(start_json placement-adopt command-adopt runner-adopt)"
crf_assert_contains "$reply" '"result":"started"' 'created container was not adopted after Docker client failure'
[ "$run_calls" = $((before_runs + 1)) ] || crf_fail 'adopted create did not invoke Docker exactly once'
[ "$(secret_call_count)" = $((before_secret_calls + 1)) ] || crf_fail 'adopted create did not perform one secret handoff'
unset FAKE_RUN_RC

# Starting without an observed container is ambiguous forever: never issue a second docker run.
fake_reset_container
distributed_adapter_policy_prepare placement-synthetic command-synthetic default runner-synthetic 1000 1073741824
distributed_adapter_state_store "" starting
before_runs=$run_calls
call_adapter "$(start_json placement-synthetic command-synthetic runner-synthetic)"
crf_assert_contains "$reply" 'container_start_uncertain' 'ambiguous starting state was not deferred'
[ "$run_calls" = "$before_runs" ] || crf_fail 'ambiguous starting state launched a duplicate'

# Observed-but-unconsumed container asks Rust for Start replay into that same container.
fake_seed_container placement-secret command-secret runner-secret
distributed_adapter_policy_prepare placement-secret command-secret default runner-secret 1000 1073741824
DA_CONTAINER_ID="$FAKE_ID"
distributed_adapter_state_store "$FAKE_ID" observed
call_adapter "$(inspect_json placement-secret "$FAKE_ID")"
crf_assert_contains "$reply" 'container_secret_pending' 'unconsumed container was not recoverable'
before_runs=$run_calls
call_adapter "$(start_json placement-secret command-secret runner-secret)"
crf_assert_contains "$reply" '"result":"started"' 'secret replay did not adopt existing container'
[ "$run_calls" = "$before_runs" ] || crf_fail 'secret replay created a second container'
[ -f "$consumed_file" ] || crf_fail 'secret replay did not complete protected handoff'

# Nonzero exit becomes durable failure before cleanup.
FAKE_STATUS=exited; FAKE_EXIT=7
call_adapter "$(inspect_json placement-secret "$FAKE_ID")"
crf_assert_contains "$reply" 'container_exit_nonzero' 'nonzero container exit was not terminalized'
[ "$FAKE_EXISTS" = 0 ] || crf_fail 'terminal container was not cleaned after durable state'

# A lookalike container lacking the managed identity must never be adopted.
fake_seed_container placement-lookalike command-lookalike runner-lookalike false
call_adapter "$(inspect_json placement-lookalike)"
crf_assert_contains "$reply" 'container_identity_ambiguous' 'unmanaged lookalike was adopted'

# Derived state identity is authoritative; tampering the deterministic container name fails closed.
fake_reset_container
distributed_adapter_policy_prepare placement-tamper command-tamper default runner-tamper 1000 1073741824
distributed_adapter_state_store "" prepared
tamper_state="$(distributed_adapter_state_path placement-tamper)"
sed -i 's/^container_name=.*/container_name=ci-runner-dist-default-forged/' "$tamper_state"
call_adapter "$(inspect_json placement-tamper)"
crf_assert_contains "$reply" 'state_corrupt' 'tampered derived state identity did not fail closed'

# Architectural fences: this bridge executes controller-approved work only.
! grep -Fq 'resource_admit_one' "$ADAPTER" || crf_fail 'distributed adapter reintroduced local admission scheduling'
! grep -Fq 'jit_retire_handle' "$ADAPTER" || crf_fail 'distributed adapter took over central JIT retirement'
grep -Fq '. "$SCRIPT_DIR/runner-distributed-adapter.sh"' "$ENGINE" || crf_fail 'runner farm does not source distributed adapter'
grep -Fq 'distributed-adapter) distributed_adapter_locked' "$ENGINE" || crf_fail 'runner farm dispatch is missing distributed adapter'
grep -Fq 'exec bash "$SCRIPT_DIR/runner-farm.sh" distributed-adapter' "$WRAPPER" || crf_fail 'adapter wrapper does not use internal dispatch'
if grep -Eq '^DISTRIBUTED_|^CRF_(CONTROLLER|EXECUTION_BACKEND|CONTAINER_ADAPTER)' src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg; then
  crf_fail 'distributed mode was added to the legacy default configuration'
fi
grep -Fq 'there is no unsafe override' docs/distributed-runner-farm/runner-packages.md ||
  crf_fail 'fail-closed native execution policy is undocumented'
grep -Fq 'If the variable is absent or empty, the controller preserves the legacy/minimal startup path.' docs/distributed-runner-farm/controller-config.md ||
  crf_fail 'backward-compatible controller startup default is undocumented'
[ -x "$WRAPPER" ] || crf_fail 'source adapter wrapper is not executable'
php -l "$PARSER" >/dev/null
bash -n "$ADAPTER" "$WRAPPER" "$ENGINE"

echo 'distributed-container-adapter: OK'
