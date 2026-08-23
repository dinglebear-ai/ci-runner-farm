#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/mock" "$tmp/state" "$tmp/work"
cp "$root/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh" "$tmp/entrypoint.sh"
chmod 0755 "$tmp/entrypoint.sh"

cat >"$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
mock="${CRF_TEST_DOCKER_ROOT:?}"
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cmd="${1:-}"; shift || true
case "$cmd" in
  run)
    printf '%s\n' "$*" >"$mock/run.args"
    : >"$mock/exists"; printf running >"$mock/status"; printf 0 >"$mock/exit"
    while (($#)); do
      case "$1" in
        --name) printf '%s' "$2" >"$mock/name"; shift 2 ;;
        --label)
          key="${2%%=*}"; value="${2#*=}"
          printf '%s' "$value" >"$mock/label.${key##*.}"
          case "$2" in
            io.dinglebear.ci-runner-farm.placement-id=*) printf '%s' "${2#*=}" >"$mock/placement" ;;
          esac
          shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$id"
    ;;
  ps) if [[ -f "$mock/exists" ]]; then printf '%s\n' "$id"; fi ;;
  inspect)
    format=""
    if [[ "${1:-}" == --format ]]; then format="$2"; fi
    case "$format" in
      '{{.Id}}') printf '%s\n' "$id" ;;
      '{{.Name}}') printf '/%s\n' "$(cat "$mock/name")" ;;
      '{{.State.Status}}') cat "$mock/status" ;;
      '{{.State.ExitCode}}') cat "$mock/exit" ;;
      *'.managed'*) printf 'true\n' ;;
      *'.placement-id'*) cat "$mock/placement" ;;
      *'.backend'*) printf 'distributed\n' ;;
      *'.command-id'*) cat "$mock/label.command-id" ;;
      *'.pool'*) cat "$mock/label.pool" ;;
      *'.runner-name'*) cat "$mock/label.runner-name" ;;
      *'.cpu-millis'*) cat "$mock/label.cpu-millis" ;;
      *'.memory-bytes'*) cat "$mock/label.memory-bytes" ;;
      *) exit 2 ;;
    esac
    ;;
  exec)
    if [[ "${1:-}" == "-i" && "${3:-}" == "tee" && "${4:-}" == "/run/crf/secret.in" ]]; then
      IFS= read -r secret || true
      printf '%s' "$secret" >"$mock/secret"
      count="$(cat "$mock/delivery-count" 2>/dev/null || printf 0)"
      printf '%s' "$((count + 1))" >"$mock/delivery-count"
      : >"$mock/consumed"
    elif [[ "${2:-}" == "test" && "${3:-}" == "-f" && "${4:-}" == "/run/crf/consumed" ]]; then
      [[ -f "$mock/consumed" ]]
    else
      exit 0
    fi
    ;;
  stop) printf exited >"$mock/status" ;;
  rm)
    rm -f "$mock/exists"
    ;;
  *) exit 2 ;;
esac
DOCKER
chmod 0755 "$tmp/bin/docker"

cargo build --manifest-path "$root/Cargo.toml" --locked -p crf-container-adapter >/dev/null
adapter="$root/target/debug/crf-container-adapter"
grep -Fq 'CRF_CONTAINER_ADAPTER_TIMEOUT_MS=60000' "$root/packaging/distributed/examples/node-env.example"
export PATH="$tmp/bin:$PATH"
export CRF_TEST_DOCKER_ROOT="$tmp/mock"
export CRF_CONTAINER_STATE_DIR="$tmp/state"
export CRF_CONTAINER_WORK_ROOT="$tmp/work"
export CRF_RUNNER_ENTRYPOINT="$tmp/entrypoint.sh"
export CRF_RUNNER_IMAGE='example.invalid/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

jit='opaque-jit-descriptor'
start="$(jq -cn --arg jit "$jit" '{schema_version:1,payload:{action:"start",placement_id:"placement-1",command_id:"command-1",pool_id:"ops",runner_name:"runner-1",resources:{cpu_millis:750,memory_bytes:1073741824},jit_config:$jit}}')"
reply="$(printf '%s\n' "$start" | "$adapter")"
jq -e '.payload.result == "started" and (.payload.id | length == 64)' <<<"$reply" >/dev/null
[[ "$(cat "$tmp/mock/secret")" == "$jit" ]]
if grep -Fq "$jit" "$tmp/mock/run.args"; then exit 1; fi
grep -Fq -- '--cpus 0.750' "$tmp/mock/run.args"
grep -Fq -- '--memory 1073741824' "$tmp/mock/run.args"

inspect='{"schema_version":1,"payload":{"action":"inspect","placement_id":"placement-1","expected_id":null}}'
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "running"' <<<"$reply" >/dev/null

printf 'wrong-command' >"$tmp/mock/label.command-id"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
printf 'command-1' >"$tmp/mock/label.command-id"

state_file="$(find "$tmp/state" -maxdepth 1 -name '*.json' -print -quit)"
jq '.handoff_phase = "pending_consumed"' "$state_file" >"$state_file.tmp"
chmod 0600 "$state_file.tmp"
mv "$state_file.tmp" "$state_file"
rm -f "$tmp/mock/consumed"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_secret_pending"' <<<"$reply" >/dev/null
( sleep 0.2; : >"$tmp/mock/consumed" ) &
reply="$(printf '%s\n' "$start" | "$adapter")"
jq -e '.payload.result == "started"' <<<"$reply" >/dev/null
[[ "$(cat "$tmp/mock/delivery-count")" == 1 ]]

printf exited >"$tmp/mock/status"
printf 1 >"$tmp/mock/exit"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "terminal" and .payload.outcome.failed.detail_code == "container_exit_nonzero"' <<<"$reply" >/dev/null

cancel='{"schema_version":1,"payload":{"action":"cancel","placement_id":"placement-1","expected_id":null}}'
reply="$(printf '%s\n' "$cancel" | "$adapter")"
jq -e '.payload.result == "terminal" and .payload.outcome.failed.detail_code == "container_exit_nonzero"' <<<"$reply" >/dev/null
[[ ! -f "$tmp/mock/exists" ]]
if grep -R -Fq "$jit" "$tmp/state" "$tmp/work"; then exit 1; fi

export CRF_RUNNER_IMAGE=example.invalid/runner:latest
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "rejected" and .payload.detail_code == "immutable_image_required"' <<<"$reply" >/dev/null

printf 'portable-container-adapter: PASS\n'
