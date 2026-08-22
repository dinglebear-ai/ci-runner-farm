#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-provisioning-operations.XXXXXX)"
worker_pid=
trap '[ -z "$worker_pid" ] || kill "$worker_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
mkdir -p "$root/include" "$root/config" "$root/run"
for file in runner-operations.sh operation-record.php runner-operation-workers.sh; do
  cp "src/usr/local/emhttp/plugins/ci-runner-farm/include/$file" "$root/include/"
done
SCRIPT_DIR="$root/include"
CFGDIR="$root/config"
RUNDIR="$root/run"
OPERATION_DIR="$CFGDIR/operations"
OPERATION_RUNTIME_DIR="$RUNDIR/operations"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operations.sh"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-operation-workers.sh"

sha="$(printf config | sha256sum | cut -d' ' -f1)"
old_sha="$(printf old-config | sha256sum | cut -d' ' -f1)"
printf '%s\n' "$sha" >"$root/current.sha"
config_revision(){ cat "$root/current.sha"; }
public_code(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["code"]??"";'; }
public_state(){ operation_read_public "$1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);echo $j["state"]??"";'; }

validate_calls="$root/validate.calls"
cat >"$root/command" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = validate ] || exit 64
  printf 'called\n' >>"$validate_calls"
  printf 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz\n'
  printf 'github_pat_abcdefghijklmnopqrstuvwxyz\n'
  [ "${CRF_TEST_VALIDATE_RC:-0}" -eq 0 ] || exit "$CRF_TEST_VALIDATE_RC"
  if [ -n "${CRF_TEST_MUTATE_CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CRF_TEST_MUTATE_CONFIG_SHA" >"$CRF_TEST_MUTATE_CONFIG_FILE"
  fi
EOF
chmod 0755 "$root/command"
export CRF_OPERATION_COMMAND_LAUNCHER="$root/command" validate_calls
OPERATION_COMMAND_LAUNCHER="$CRF_OPERATION_COMMAND_LAUNCHER"

success_id='20000001-0000-0000-0000-000000000001'
CRF_OPERATION_ID="$success_id" operation_create provisioning_validation "$sha" provisioning_log >/dev/null
operation_provisioning_worker "$success_id"
crf_assert_eq succeeded "$(public_state "$success_id")" 'provisioning success state'
crf_assert_eq provisioning_valid "$(public_code "$success_id")" 'provisioning success code'
success_public="$(operation_read_public "$success_id")"
printf '%s' "$success_public" | php -r '
$j=json_decode(stream_get_contents(STDIN),true);$text=implode("\n",$j["output"]??[]);
exit(strpos($text,"abcdefghijklmnopqrstuvwxyz")===false&&strpos($text,"[REDACTED]")!==false?0:1);
' || crf_fail 'provisioning summary leaked credentials'

failure_id='20000002-0000-0000-0000-000000000002'
CRF_OPERATION_ID="$failure_id" operation_create provisioning_validation "$sha" provisioning_log >/dev/null
export CRF_TEST_VALIDATE_RC=9
operation_provisioning_worker "$failure_id"
unset CRF_TEST_VALIDATE_RC
crf_assert_eq failed "$(public_state "$failure_id")" 'provisioning failure state'
crf_assert_eq provisioning_failed "$(public_code "$failure_id")" 'provisioning failure code'

stale_id='20000003-0000-0000-0000-000000000003'
CRF_OPERATION_ID="$stale_id" operation_create provisioning_validation "$old_sha" provisioning_log >/dev/null
before_calls="$(wc -l <"$validate_calls")"
operation_provisioning_worker "$stale_id"
after_calls="$(wc -l <"$validate_calls")"
crf_assert_eq "$before_calls" "$after_calls" 'stale provisioning reached validator'
crf_assert_eq stale_config "$(public_code "$stale_id")" 'pre-validation stale code'

mutated_id='20000004-0000-0000-0000-000000000004'
CRF_OPERATION_ID="$mutated_id" operation_create provisioning_validation "$sha" provisioning_log >/dev/null
export CRF_TEST_MUTATE_CONFIG_FILE="$root/current.sha" CRF_TEST_MUTATE_CONFIG_SHA="$old_sha"
operation_provisioning_worker "$mutated_id"
unset CRF_TEST_MUTATE_CONFIG_FILE CRF_TEST_MUTATE_CONFIG_SHA
crf_assert_eq stale_config "$(public_code "$mutated_id")" 'post-validation stale code'
printf '%s\n' "$sha" >"$root/current.sha"

active_id='20000005-0000-0000-0000-000000000005'
CRF_OPERATION_ID="$active_id" operation_create provisioning_validation "$sha" provisioning_log >/dev/null
set +e
active_reply="$(cmd_provisioning_operation_start "$sha")"
active_rc=$?
set -e
crf_assert_eq 4 "$active_rc" 'duplicate provisioning start exit code'
crf_assert_contains "$active_reply" '"code":"operation_running"' 'duplicate provisioning start code'
crf_assert_contains "$active_reply" "$active_id" 'duplicate provisioning operation ID'
operation_finish "$active_id" failed test_cleanup 'Test cleanup.' >/dev/null

launch_id='20000006-0000-0000-0000-000000000006'
export CRF_OPERATION_ID="$launch_id" CRF_OPERATION_WORKER_LAUNCHER="$root/missing-launcher"
set +e
launch_reply="$(cmd_provisioning_operation_start "$sha")"
launch_rc=$?
set -e
unset CRF_OPERATION_ID CRF_OPERATION_WORKER_LAUNCHER
crf_assert_eq 5 "$launch_rc" 'provisioning launch failure exit code'
crf_assert_contains "$launch_reply" '"code":"backend_unavailable"' 'provisioning launch failure code'
crf_assert_eq launch_failed "$(public_code "$launch_id")" 'durable provisioning launch failure'

cat >"$root/launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$CRF_TEST_LAUNCH_PID"
printf '%s\n' "$*" >"$CRF_TEST_LAUNCH_ARGS"
exec sleep 30
EOF
chmod 0755 "$root/launcher"
start_id='20000007-0000-0000-0000-000000000007'
export CRF_OPERATION_ID="$start_id" CRF_OPERATION_WORKER_LAUNCHER="$root/launcher"
export CRF_TEST_LAUNCH_PID="$root/launch.pid" CRF_TEST_LAUNCH_ARGS="$root/launch.args"
start_reply="$(cmd_provisioning_operation_start "$sha")"
unset CRF_OPERATION_ID CRF_OPERATION_WORKER_LAUNCHER
crf_assert_contains "$start_reply" '"ok":true' 'provisioning start success'
crf_assert_contains "$start_reply" "$start_id" 'provisioning start operation ID'
for _ in $(seq 1 100); do [ -s "$root/launch.pid" ] && break; sleep 0.02; done
[ -s "$root/launch.pid" ] || crf_fail 'provisioning launcher did not start'
worker_pid="$(cat "$root/launch.pid")"
crf_assert_eq "provisioning-operation-worker $start_id" "$(cat "$root/launch.args")" 'provisioning launcher arguments'
kill "$worker_pid" 2>/dev/null || true
worker_pid=
operation_finish "$start_id" failed test_cleanup 'Test cleanup.' >/dev/null

set +e
invalid_reply="$(cmd_provisioning_operation_start bad)"
invalid_rc=$?
set -e
crf_assert_eq 2 "$invalid_rc" 'invalid provisioning revision exit code'
crf_assert_contains "$invalid_reply" '"code":"invalid_revision"' 'invalid provisioning revision code'
printf '%s\n' "$old_sha" >"$root/current.sha"
set +e
stale_reply="$(cmd_provisioning_operation_start "$sha")"
stale_rc=$?
set -e
crf_assert_eq 3 "$stale_rc" 'stale provisioning start exit code'
crf_assert_contains "$stale_reply" '"code":"stale_config"' 'stale provisioning start code'

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
snippet="$root/cmd-validate.sh"
sed -n '/^cmd_validate()/,/^}/p' "$engine" >"$snippet"
(
  # shellcheck disable=SC1090
  . "$snippet"
  NAME_PREFIX=ci-runner
  RUNDIR="$root/validate-run"
  CACHE_ROOT="$root/cache"
  mkdir -p "$RUNDIR" "$CACHE_ROOT/docker/ci-runner-validate"
  check_cache_root(){ return 0; }
  ensure_dirs(){ return 0; }
  registry_login(){ return 0; }
  effective_image(){ printf '%s\n' test-image; }
  build_args(){ ARGS=(run --name "$2" test-image); }
  log(){ printf 'LOG:%s\n' "$*"; }
  err(){ printf 'ERR:%s\n' "$*" >&2; }
  docker_calls="$root/docker.calls"
  docker(){
    printf '%s\n' "$*" >>"$docker_calls"
    case "$1" in
      rm) return 0 ;;
      run) [ "${CRF_TEST_DOCKER_RUN_FAIL:-0}" = 0 ] ;;
      inspect)
        [ "${CRF_TEST_DOCKER_INSPECT_FAIL:-0}" = 0 ] || return 1
        printf '%s\n' inspect-ok
        ;;
      exec) return 0 ;;
      *) return 1 ;;
    esac
  }

  : >"$docker_calls"
  cmd_validate >/dev/null
  crf_assert_eq 2 "$(grep -c '^rm -f ci-runner-validate$' "$docker_calls")" 'successful validation cleanup count'
  [ ! -d "$CACHE_ROOT/docker/ci-runner-validate" ] || crf_fail 'successful validation left Docker cache root'

  mkdir -p "$CACHE_ROOT/docker/ci-runner-validate"
  : >"$docker_calls"
  if CRF_TEST_DOCKER_INSPECT_FAIL=1 cmd_validate >/dev/null 2>&1; then crf_fail 'inspect failure reported success'; fi
  crf_assert_eq 2 "$(grep -c '^rm -f ci-runner-validate$' "$docker_calls")" 'inspect failure cleanup count'
  [ ! -d "$CACHE_ROOT/docker/ci-runner-validate" ] || crf_fail 'inspect failure left Docker cache root'

  mkdir -p "$CACHE_ROOT/docker/ci-runner-validate"
  : >"$docker_calls"
  if CRF_TEST_DOCKER_RUN_FAIL=1 cmd_validate >/dev/null 2>&1; then crf_fail 'docker run failure reported success'; fi
  crf_assert_eq 2 "$(grep -c '^rm -f ci-runner-validate$' "$docker_calls")" 'run failure cleanup count'
  [ ! -d "$CACHE_ROOT/docker/ci-runner-validate" ] || crf_fail 'run failure left Docker cache root'
  shopt -s nullglob
  errors=("$RUNDIR"/crf-validate.*)
  [ "${#errors[@]}" -eq 0 ] || crf_fail 'validation left private error files'
)

echo 'provisioning-operations: OK'
