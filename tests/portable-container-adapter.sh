#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/mock" "$tmp/state" "$tmp/work"

cat >"$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
mock="${CRF_TEST_DOCKER_ROOT:?}"
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
init_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cmd="${1:-}"; shift || true
if [[ -f "$mock/replace-docker-once" ]]; then
  cp "$0" "$0.replacement"
  printf '\n' >>"$0.replacement"
  chmod 0755 "$0.replacement"
  mv "$0.replacement" "$0"
  rm -f "$mock/replace-docker-once"
fi
case "$cmd" in
  info) [[ -f "$mock/docker-ready" ]] ;;
  create)
    if [[ " $* " == *'.purpose=bootstrap-init'* ]]; then
      cp "$mock/image" "$mock/init-image"
      printf '["bootstrap-init"]\n' >"$mock/init-cmd"
      printf created >"$mock/init-status"; : >"$mock/init-exists"
      while (($#)); do
        case "$1" in
          --name) printf '%s' "$2" >"$mock/init-name"; shift 2 ;;
          --label) key="${2%%=*}"; printf '%s' "${2#*=}" >"$mock/init-label.${key##*.}"; shift 2 ;;
          --mount)
            mount_name="${2#*src=}"; mount_name="${mount_name%%,*}"
            printf '[{"Type":"volume","Name":"%s","Destination":"/opt/crf-bootstrap","RW":true}]\n' "$mount_name" >"$mock/init-mounts"
            shift 2 ;;
          *) shift ;;
        esac
      done
      printf '%s\n' "$init_id"
      exit 0
    fi
    printf '%s\n' "$*" >"$mock/run.args"
    printf '["/opt/crf-bootstrap/crf-container-adapter"]\n' >"$mock/runner-entrypoint"
    printf '["runner-entrypoint"]\n' >"$mock/runner-cmd"
    : >"$mock/exists"; printf created >"$mock/status"; printf 0 >"$mock/exit"
    mounts=()
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
        --mount) mounts+=("$2"); shift 2 ;;
        *) shift ;;
      esac
    done
    work_mount="${mounts[0]}"; bootstrap_mount="${mounts[1]}"
    work_name="${work_mount#*src=}"; work_name="${work_name%%,*}"
    bootstrap_name="${bootstrap_mount#*src=}"; bootstrap_name="${bootstrap_name%%,*}"
    printf '[{"Type":"volume","Name":"%s","Destination":"/_work","RW":true},{"Type":"volume","Name":"%s","Destination":"/opt/crf-bootstrap","RW":false}]\n' "$work_name" "$bootstrap_name" >"$mock/mounts"
    printf '%s\n' "$id"
    ;;
  cp)
    printf '%s\n' "$*" >"$mock/cp.args"
    [[ "$1" == - ]]
    [[ "$2" == "$init_id:/opt/crf-bootstrap" ]]
    cat >"$mock/adapter.tar"
    [[ ! -f "$mock/fail-bootstrap-cp" ]]
    ;;
  start) printf running >"$mock/status" ;;
  volume)
    sub="${1:-}"; shift || true
    case "$sub" in
      create)
        if [[ -f "$mock/fail-volume-once" ]]; then rm -f "$mock/fail-volume-once"; exit 1; fi
        declare -A labels=()
        name=""
        while (($#)); do
          if [[ "$1" == --label ]]; then
            key="${2%%=*}"; value="${2#*=}"
            labels["${key##*.}"]="$value"
            shift 2
          else
            name="$1"; shift
          fi
        done
        mkdir -p "$mock/volumes/$name"
        for key in "${!labels[@]}"; do printf '%s' "${labels[$key]}" >"$mock/volumes/$name/label.$key"; done
        ;;
      inspect)
        format="$2"; name="$3"
        [[ -d "$mock/volumes/$name" ]]
        if [[ "$format" == '{{.Driver}}' ]]; then printf 'local\n'
        elif [[ "$format" == '{{json .Options}}' ]]; then printf '%s\n' "${CRF_TEST_VOLUME_OPTIONS:-null}"
        else
          key="${format#*\"}"; key="${key%%\"*}"; key="${key##*.}"
          cat "$mock/volumes/$name/label.$key"
        fi
        ;;
      ls)
        filter="$3"; name="${filter#name=^}"; name="${name%$}"
        [[ ! -d "$mock/volumes/$name" ]] || printf '%s\n' "$name"
        ;;
      ls)
        name="${3#name=^}"; name="${name%$}"
        if [[ -d "$mock/volumes/$name" ]]; then printf '%s\n' "$name"; fi
        ;;
      rm)
        printf '%s\n' "$1" >>"$mock/volume-rm-attempts"
        [[ ! -f "$mock/fail-volume-$1" ]]
        rm -rf "$mock/volumes/$1"
        ;;
      *) exit 2 ;;
    esac
    ;;
  ps)
    if [[ " $* " == *'id='* ]]; then
      [[ ! -f "$mock/exists" ]] || printf '%s\n' "$id"
    elif [[ " $* " == *'.purpose=bootstrap-init'* ]]; then
      [[ ! -f "$mock/init-exists" ]] || printf '%s\n' "$init_id"
    elif [[ -f "$mock/exists" ]]; then printf '%s\n' "$id"; fi
    ;;
  inspect)
    format=""
    if [[ "${1:-}" == --format ]]; then format="$2"; fi
    target="${3:-${1:-}}"
    if [[ "$target" == "$init_id" ]]; then
      case "$format" in
        '{{.Id}}') printf '%s\n' "$init_id" ;;
        '{{.Name}}') printf '/%s\n' "$(cat "$mock/init-name")" ;;
        '{{.State.Status}}') cat "$mock/init-status" ;;
        '{{.Config.Image}}') cat "$mock/init-image" ;;
        '{{json .Config.Entrypoint}}') printf '["/bin/true"]\n' ;;
        '{{json .Config.Cmd}}') cat "$mock/init-cmd" ;;
        '{{json .Mounts}}') cat "$mock/init-mounts" ;;
        *'.'* ) key="${format#*\"}"; key="${key%%\"*}"; key="${key##*.}"; cat "$mock/init-label.$key" ;;
        *) exit 2 ;;
      esac
      exit 0
    fi
    case "$format" in
      '{{.Id}}') printf '%s\n' "$id" ;;
      '{{.Name}}') printf '/%s\n' "$(cat "$mock/name")" ;;
      '{{.State.Status}}') cat "$mock/status" ;;
      '{{.State.ExitCode}}') cat "$mock/exit" ;;
      '{{.Config.Image}}') cat "$mock/image" ;;
      '{{json .Config.Entrypoint}}') cat "$mock/runner-entrypoint" ;;
      '{{json .Config.Cmd}}') cat "$mock/runner-cmd" ;;
      '{{json .Mounts}}') cat "$mock/mounts" ;;
      *'.managed'*) printf 'true\n' ;;
      *'.placement-id'*) cat "$mock/placement" ;;
      *'.backend'*) printf 'distributed\n' ;;
      *'.command-id'*) cat "$mock/label.command-id" ;;
      *'.pool'*) cat "$mock/label.pool" ;;
      *'.runner-name'*) cat "$mock/label.runner-name" ;;
      *'.cpu-millis'*) cat "$mock/label.cpu-millis" ;;
      *'.memory-bytes'*) cat "$mock/label.memory-bytes" ;;
      *'.ownership-nonce'*) cat "$mock/label.ownership-nonce" ;;
      *'.work-volume-name'*) cat "$mock/label.work-volume-name" ;;
      *'.bootstrap-volume-name'*) cat "$mock/label.bootstrap-volume-name" ;;
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
  stop) printf '%s\n' "$*" >>"$mock/container-stop-attempts"; printf exited >"$mock/status" ;;
  rm)
    if [[ " $* " == *"$init_id"* ]]; then rm -f "$mock/init-exists"; else
      printf '%s\n' "$*" >>"$mock/container-rm-attempts"
      [[ ! -f "$mock/fail-container-rm" ]]
      rm -f "$mock/exists"
    fi
    ;;
  *) exit 2 ;;
esac
DOCKER
chmod 0755 "$tmp/bin/docker"
cat >"$tmp/bin/service" <<'SERVICE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "docker start" ]]
: >"${CRF_TEST_DOCKER_ROOT:?}/docker-ready"
SERVICE
chmod 0755 "$tmp/bin/service"

cargo build --manifest-path "$root/Cargo.toml" --locked -p crf-container-adapter >/dev/null
adapter="$root/target/debug/crf-container-adapter"

# Exercise the in-container entrypoint without Docker. Secrets cross only the
# private FIFO and the three runner files appear together with private modes.
mkdir -p "$tmp/entry-secret" "$tmp/entry-config" "$tmp/entry-work"
cat >"$tmp/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
[[ "${RUNNER_ALLOW_RUNASROOT:-}" == 1 ]]
[[ ! -e "${CRF_SECRET_DIR}/secret.in" ]]
for file in .runner .credentials .credentials_rsaparams; do
  [[ -s "$file" && "$(stat -c %a "$file")" == 600 ]]
done
printf passed >"${CRF_TEST_DOCKER_ROOT}/entrypoint-ran"
RUNNER
chmod 0755 "$tmp/runner.sh"
jit_manifest="$(jq -cn '{".runner":"cnVubmVy",".credentials":"Y3JlZGVudGlhbHM=",".credentials_rsaparams":"cnNh"}' | base64 -w0)"
CRF_SECRET_DIR="$tmp/entry-secret" CRF_JIT_CONFIG_DIR="$tmp/entry-config" \
  RUNNER_WORKDIR="$tmp/entry-work" RUN_AS_ROOT=true CRF_JIT_RUNNER="$tmp/runner.sh" \
  CRF_TEST_DOCKER_ROOT="$tmp/mock" PATH="$tmp/bin:$PATH" START_DOCKER_SERVICE=true \
  CRF_DOCKER_SUPERVISE=false CRF_DOCKER_LOG="$tmp/dockerd.log" \
  CRF_DOCKER_PID_FILE="$tmp/docker.pid" \
  "$adapter" runner-entrypoint &
entry_pid=$!
for _ in $(seq 1 100); do [[ -e "$tmp/entry-secret/ready" ]] && break; sleep 0.02; done
[[ -p "$tmp/entry-secret/secret.in" ]]
printf '%s\n' "$jit_manifest" >"$tmp/entry-secret/secret.in"
wait "$entry_pid"
[[ -f "$tmp/mock/entrypoint-ran" && -f "$tmp/entry-secret/consumed" ]]
[[ -f "$tmp/mock/docker-ready" ]]
[[ ! -e "$tmp/entry-secret/secret.in" ]]
if find "$tmp/entry-config" -maxdepth 1 -name '.crf-jit-*' | grep -q .; then exit 1; fi

# A failure after the first rename must roll back every final/temp file and
# must not acknowledge consumption to the controller.
mkdir -p "$tmp/fail-secret" "$tmp/fail-config" "$tmp/fail-work"
CRF_SECRET_DIR="$tmp/fail-secret" CRF_JIT_CONFIG_DIR="$tmp/fail-config" \
  RUNNER_WORKDIR="$tmp/fail-work" RUN_AS_ROOT=true CRF_JIT_RUNNER="$tmp/runner.sh" \
  CRF_TEST_DOCKER_ROOT="$tmp/mock" CRF_TEST_JIT_FAIL_AFTER_RENAME=.runner \
  "$adapter" runner-entrypoint >/dev/null 2>&1 &
fail_pid=$!
for _ in $(seq 1 100); do [[ -e "$tmp/fail-secret/ready" ]] && break; sleep 0.02; done
printf '%s\n' "$jit_manifest" >"$tmp/fail-secret/secret.in"
if wait "$fail_pid"; then exit 1; fi
[[ ! -e "$tmp/fail-secret/consumed" && ! -e "$tmp/fail-secret/secret.in" ]]
for file in .runner .credentials .credentials_rsaparams; do [[ ! -e "$tmp/fail-config/$file" ]]; done
if find "$tmp/fail-config" -maxdepth 1 -name '.crf-jit-*' | grep -q .; then exit 1; fi

if RUN_AS_ROOT=invalid "$adapter" runner-entrypoint >/dev/null 2>&1; then exit 1; fi
ln -s "$tmp/entry-secret" "$tmp/unsafe-secret"
if CRF_SECRET_DIR="$tmp/unsafe-secret" RUN_AS_ROOT=true "$adapter" runner-entrypoint >/dev/null 2>&1; then exit 1; fi

grep -Fq 'CRF_CONTAINER_ADAPTER_TIMEOUT_MS=60000' "$root/packaging/distributed/examples/node-env.example"
export PATH="$tmp/bin:$PATH"
export CRF_DOCKER_PATH="$tmp/bin/docker"
export CRF_TEST_DOCKER_TRUST_ROOT="$tmp"
export CRF_TEST_DOCKER_ROOT="$tmp/mock"
export CRF_CONTAINER_STATE_DIR="$tmp/state"
export CRF_CONTAINER_WORK_ROOT="$tmp/work"
export CRF_RUNNER_IMAGE='example.invalid/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
printf '%s' "$CRF_RUNNER_IMAGE" >"$tmp/mock/image"

jit='opaque-jit-descriptor'
start="$(jq -cn --arg jit "$jit" '{schema_version:1,payload:{action:"start",placement_id:"placement-1",command_id:"command-1",pool_id:"ops",runner_name:"runner-1",resources:{cpu_millis:750,memory_bytes:1073741824},jit_config:$jit}}')"
: >"$tmp/mock/fail-bootstrap-cp"
reply="$(printf '%s\n' "$start" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_start_uncertain"' <<<"$reply" >/dev/null
printf '["wrong"]\n' >"$tmp/mock/init-cmd"
reply="$(printf '%s\n' "$start" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
printf '["bootstrap-init"]\n' >"$tmp/mock/init-cmd"
rm "$tmp/mock/fail-bootstrap-cp"
reply="$(printf '%s\n' "$start" | "$adapter")"
jq -e '.payload.result == "started" and (.payload.id | length == 64)' <<<"$reply" >/dev/null
[[ "$(cat "$tmp/mock/secret")" == "$jit" ]]
if grep -Fq "$jit" "$tmp/mock/run.args"; then exit 1; fi
grep -Fq -- '--cpus 0.750' "$tmp/mock/run.args"
grep -Fq -- '--memory 1073741824' "$tmp/mock/run.args"
grep -Fq -- 'type=volume,src=crf-dist-work-' "$tmp/mock/run.args"
grep -Fq -- 'dst=/_work,volume-nocopy' "$tmp/mock/run.args"
grep -Fq -- 'dst=/opt/crf-bootstrap,readonly,volume-nocopy' "$tmp/mock/run.args"
if grep -Eq 'type=bind|src=.*/tmp|entrypoint\.sh' "$tmp/mock/run.args"; then exit 1; fi
grep -Eq '^- b{64}:/opt/crf-bootstrap$' "$tmp/mock/cp.args"
[[ "$(tar -tf "$tmp/mock/adapter.tar")" == crf-container-adapter ]]

state_file="$(find "$tmp/state" -maxdepth 1 -name '*.json' -print -quit)"
nonce="$(jq -r '.ownership_nonce' "$state_file")"
[[ "$nonce" =~ ^[0-9a-f]{32}$ ]]
work_volume="$(jq -r '.work_volume_name' "$state_file")"
bootstrap_volume="$(jq -r '.bootstrap_volume_name' "$state_file")"
[[ "$work_volume" != "$bootstrap_volume" ]]
printf '[{"Type":"volume","Name":"%s","Destination":"/_work","RW":true},{"Type":"volume","Name":"%s","Destination":"/opt/crf-bootstrap","RW":false}]\n' "$work_volume" "$bootstrap_volume" >"$tmp/mock/mounts"

inspect='{"schema_version":1,"payload":{"action":"inspect","placement_id":"placement-1","expected_id":null}}'
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "running"' <<<"$reply" >/dev/null

: >"$tmp/mock/replace-docker-once"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "rejected" and .payload.detail_code == "missing_runtime_dependency"' <<<"$reply" >/dev/null

printf '%s' 'example.invalid/other@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' >"$tmp/mock/image"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
printf '%s' "$CRF_RUNNER_IMAGE" >"$tmp/mock/image"

export CRF_TEST_VOLUME_OPTIONS='{"type":"tmpfs"}'
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
unset CRF_TEST_VOLUME_OPTIONS

printf '[{"Type":"volume","Name":"wrong-volume","Destination":"/_work","RW":true},{"Type":"volume","Name":"%s","Destination":"/opt/crf-bootstrap","RW":false}]\n' "$bootstrap_volume" >"$tmp/mock/mounts"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
printf '[{"Type":"volume","Name":"%s","Destination":"/_work","RW":true},{"Type":"volume","Name":"%s","Destination":"/opt/crf-bootstrap","RW":false}]\n' "$work_volume" "$bootstrap_volume" >"$tmp/mock/mounts"

printf 'wrong-command' >"$tmp/mock/label.command-id"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
printf 'command-1' >"$tmp/mock/label.command-id"

jq '.handoff_phase = "pending_consumed"' "$state_file" >"$state_file.tmp"
chmod 0600 "$state_file.tmp"
mv "$state_file.tmp" "$state_file"
rm -f "$tmp/mock/consumed"
printf 'wrong-command' >"$tmp/mock/label.command-id"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
printf 'command-1' >"$tmp/mock/label.command-id"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_secret_pending"' <<<"$reply" >/dev/null
( sleep 0.2; : >"$tmp/mock/consumed" ) &
reply="$(printf '%s\n' "$start" | "$adapter")"
jq -e '.payload.result == "started"' <<<"$reply" >/dev/null
[[ "$(cat "$tmp/mock/delivery-count")" == 1 ]]

printf exited >"$tmp/mock/status"
printf 1 >"$tmp/mock/exit"
: >"$tmp/mock/fail-container-rm"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_remove_failed"' <<<"$reply" >/dev/null
jq -e '.terminal == "failed" and .cleanup.requested and (.cleanup.container_removed | not)' "$state_file" >/dev/null

# Terminal replay revalidates the complete recorded container immediately
# before destructive commands. Any substituted contract field fails closed.
stop_count="$(wc -l <"$tmp/mock/container-stop-attempts")"
rm_count="$(wc -l <"$tmp/mock/container-rm-attempts")"
assert_terminal_substitution_refused() {
  reply="$(printf '%s\n' "$inspect" | "$adapter")"
  jq -e '.payload.result == "deferred" and .payload.detail_code == "container_identity_ambiguous"' <<<"$reply" >/dev/null
  [[ "$(wc -l <"$tmp/mock/container-stop-attempts")" == "$stop_count" ]]
  [[ "$(wc -l <"$tmp/mock/container-rm-attempts")" == "$rm_count" ]]
}
printf wrong-command >"$tmp/mock/label.command-id"
assert_terminal_substitution_refused
printf command-1 >"$tmp/mock/label.command-id"
printf '%s' 'example.invalid/other@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' >"$tmp/mock/image"
assert_terminal_substitution_refused
printf '%s' "$CRF_RUNNER_IMAGE" >"$tmp/mock/image"
printf '["/bin/false"]\n' >"$tmp/mock/runner-entrypoint"
assert_terminal_substitution_refused
printf '["/opt/crf-bootstrap/crf-container-adapter"]\n' >"$tmp/mock/runner-entrypoint"
printf '["wrong"]\n' >"$tmp/mock/runner-cmd"
assert_terminal_substitution_refused
printf '["runner-entrypoint"]\n' >"$tmp/mock/runner-cmd"
cp "$tmp/mock/mounts" "$tmp/mock/mounts.good"
printf '[]\n' >"$tmp/mock/mounts"
assert_terminal_substitution_refused
mv "$tmp/mock/mounts.good" "$tmp/mock/mounts"

# Replay after the container-removal crash boundary. Both independent volume
# removals are attempted even when each fails, and their completion is durable.
rm "$tmp/mock/fail-container-rm"
: >"$tmp/mock/fail-volume-$bootstrap_volume"
: >"$tmp/mock/fail-volume-$work_volume"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_remove_failed"' <<<"$reply" >/dev/null
jq -e '.cleanup.container_removed and (.cleanup.bootstrap_removed | not) and (.cleanup.work_removed | not)' "$state_file" >/dev/null
grep -Fxq "$bootstrap_volume" "$tmp/mock/volume-rm-attempts"
grep -Fxq "$work_volume" "$tmp/mock/volume-rm-attempts"

rm "$tmp/mock/fail-volume-$bootstrap_volume"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_remove_failed"' <<<"$reply" >/dev/null
jq -e '.cleanup.bootstrap_removed and (.cleanup.work_removed | not)' "$state_file" >/dev/null
rm "$tmp/mock/fail-volume-$work_volume"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "terminal" and .payload.outcome.failed.detail_code == "container_exit_nonzero"' <<<"$reply" >/dev/null
jq -e '.cleanup.container_removed and .cleanup.bootstrap_removed and .cleanup.work_removed and .handoff_phase == "complete"' "$state_file" >/dev/null

cancel='{"schema_version":1,"payload":{"action":"cancel","placement_id":"placement-1","expected_id":null}}'
reply="$(printf '%s\n' "$cancel" | "$adapter")"
jq -e '.payload.result == "terminal" and .payload.outcome.failed.detail_code == "container_exit_nonzero"' <<<"$reply" >/dev/null
[[ ! -f "$tmp/mock/exists" ]]
[[ ! -d "$tmp/mock/volumes/$work_volume" ]]
[[ ! -d "$tmp/mock/volumes/$bootstrap_volume" ]]
if grep -R -Fq "$jit" "$tmp/state" "$tmp/work"; then exit 1; fi

# Cancellation persists its terminal intent before removal and replays from the
# exact recorded container ID after an interrupted destructive command.
start2="$(jq -cn --arg jit "$jit" '{schema_version:1,payload:{action:"start",placement_id:"placement-2",command_id:"command-2",pool_id:"ops",runner_name:"runner-2",resources:{cpu_millis:750,memory_bytes:1073741824},jit_config:$jit}}')"
reply="$(printf '%s\n' "$start2" | "$adapter")"
jq -e '.payload.result == "started"' <<<"$reply" >/dev/null
state_file2="$(find "$tmp/state" -maxdepth 1 -name '*.json' ! -name "$(basename "$state_file")" -print -quit)"
work_volume2="$(jq -r '.work_volume_name' "$state_file2")"
bootstrap_volume2="$(jq -r '.bootstrap_volume_name' "$state_file2")"
cancel2='{"schema_version":1,"payload":{"action":"cancel","placement_id":"placement-2","expected_id":null}}'
: >"$tmp/mock/fail-container-rm"
reply="$(printf '%s\n' "$cancel2" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_remove_failed"' <<<"$reply" >/dev/null
jq -e '.terminal == "cancelled" and .cleanup.requested and (.cleanup.container_removed | not)' "$state_file2" >/dev/null
rm "$tmp/mock/fail-container-rm"
reply="$(printf '%s\n' "$cancel2" | "$adapter")"
jq -e '.payload.result == "terminal" and .payload.outcome == "cancelled"' <<<"$reply" >/dev/null
jq -e '.cleanup.container_removed and .cleanup.bootstrap_removed and .cleanup.work_removed' "$state_file2" >/dev/null
[[ ! -d "$tmp/mock/volumes/$work_volume2" && ! -d "$tmp/mock/volumes/$bootstrap_volume2" ]]

# A durable state written before the first volume exists resumes the fixed
# volume/bootstrap/container sequence instead of wedging the placement.
: >"$tmp/mock/fail-volume-once"
retry_start="$(jq -cn --arg jit "$jit" '{schema_version:1,payload:{action:"start",placement_id:"placement-retry",command_id:"command-retry",pool_id:"ops",runner_name:"runner-retry",resources:{cpu_millis:750,memory_bytes:1073741824},jit_config:$jit}}')"
reply="$(printf '%s\n' "$retry_start" | "$adapter")"
jq -e '.payload.result == "deferred" and .payload.detail_code == "container_start_uncertain"' <<<"$reply" >/dev/null
reply="$(printf '%s\n' "$retry_start" | "$adapter")"
jq -e '.payload.result == "started"' <<<"$reply" >/dev/null

export CRF_RUNNER_IMAGE=example.invalid/runner:latest
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "rejected" and .payload.detail_code == "immutable_image_required"' <<<"$reply" >/dev/null

export CRF_RUNNER_IMAGE='example.invalid/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
chmod 0777 "$tmp/bin"
reply="$(printf '%s\n' "$inspect" | "$adapter")"
jq -e '.payload.result == "rejected" and .payload.detail_code == "missing_runtime_dependency"' <<<"$reply" >/dev/null
chmod 0755 "$tmp/bin"

printf 'portable-container-adapter: PASS\n'
