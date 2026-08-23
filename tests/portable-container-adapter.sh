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
          case "$2" in
            io.dinglebear.ci-runner-farm.placement-id=*) printf '%s' "${2#*=}" >"$mock/placement" ;;
          esac
          shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$id"
    ;;
  ps) [[ -f "$mock/exists" ]] && printf '%s\n' "$id" ;;
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
      *) exit 2 ;;
    esac
    ;;
  exec)
    args="$*"
    if [[ "$args" == *'cat > /run/crf/secret.in'* ]]; then
      IFS= read -r secret || true
      printf '%s' "$secret" >"$mock/secret"
      : >"$mock/consumed"
    elif [[ "$args" == *'/run/crf/consumed'* ]]; then
      [[ -f "$mock/consumed" ]]
    else
      exit 0
    fi
    ;;
  stop) printf exited >"$mock/status" ;;
  rm) rm -f "$mock/exists" ;;
  *) exit 2 ;;
esac
DOCKER
chmod 0755 "$tmp/bin/docker"

adapter="$root/packaging/distributed/bin/crf-container-adapter"
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

cancel='{"schema_version":1,"payload":{"action":"cancel","placement_id":"placement-1","expected_id":null}}'
reply="$(printf '%s\n' "$cancel" | "$adapter")"
jq -e '.payload.result == "cancelled"' <<<"$reply" >/dev/null
[[ ! -f "$tmp/mock/exists" ]]
if grep -R -Fq "$jit" "$tmp/state" "$tmp/work"; then exit 1; fi

export CRF_RUNNER_IMAGE=example.invalid/runner:latest
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "rejected" and .payload.detail_code == "immutable_image_required"' <<<"$reply" >/dev/null

printf 'portable-container-adapter: PASS\n'
