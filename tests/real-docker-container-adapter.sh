#!/usr/bin/env bash
set -euo pipefail

[[ "${CRF_RUN_REAL_DOCKER_ACCEPTANCE:-}" == 1 ]] || {
  echo 'set CRF_RUN_REAL_DOCKER_ACCEPTANCE=1 to run the destructive local-Docker acceptance' >&2
  exit 2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${CRF_REAL_DOCKER_RUNNER_IMAGE:-$(sed -n 's/^FROM \([^[:space:]]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$root/src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile")}"
[[ "$image" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || { echo 'authoritative runner image pin missing' >&2; exit 1; }

run_id="accept-$(date +%s)-$$"
tmp="$(mktemp -d "/tmp/crf-real-docker-${run_id}.XXXXXX")"
placements=("${run_id}-cancel" "${run_id}-terminal")
cleanup() {
  local placement
  local -a ids volumes
  for placement in "${placements[@]}"; do
    mapfile -t ids < <(docker ps -aq --filter "label=io.dinglebear.ci-runner-farm.placement-id=$placement" 2>/dev/null || true)
    ((${#ids[@]} == 0)) || docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
    mapfile -t volumes < <(docker volume ls -q --filter "label=io.dinglebear.ci-runner-farm.placement-id=$placement" 2>/dev/null || true)
    ((${#volumes[@]} == 0)) || docker volume rm "${volumes[@]}" >/dev/null 2>&1 || true
  done
  rm -rf -- "$tmp"
}
trap cleanup EXIT

docker pull "$image" >/dev/null
docker image inspect "$image" --format '{{json .RepoDigests}}' |
  jq -e --arg image "$image" 'index($image) != null' >/dev/null
cargo build --manifest-path "$root/Cargo.toml" --locked --release -p crf-container-adapter --target x86_64-unknown-linux-musl >/dev/null
adapter="$root/target/x86_64-unknown-linux-musl/release/crf-container-adapter"
if readelf -l "$adapter" | grep -q INTERP; then exit 1; fi
if readelf -d "$adapter" 2>/dev/null | grep -q '(NEEDED)'; then exit 1; fi

file_value="$(printf '{}' | base64 -w0)"
jit="$(jq -cn --arg v "$file_value" '{".runner":$v,".credentials":$v,".credentials_rsaparams":$v}' | base64 -w0)"

run_case() {
  local placement="$1" mode="$2" state_dir start reply state_file id work bootstrap request result
  state_dir="$tmp/$mode"
  mkdir -m 0700 "$state_dir"
  start="$(jq -cn --arg p "$placement" --arg jit "$jit" '{schema_version:1,payload:{action:"start",placement_id:$p,command_id:"accept-command",pool_id:"accept-pool",runner_name:"accept-runner",resources:{cpu_millis:500,memory_bytes:536870912},jit_config:$jit}}')"
  reply="$(printf '%s\n' "$start" | env CRF_CONTAINER_STATE_DIR="$state_dir" CRF_RUNNER_IMAGE="$image" CRF_DOCKER_PATH=/usr/bin/docker "$adapter")"
  jq -e '.payload.result == "started"' <<<"$reply" >/dev/null
  state_file="$(find "$state_dir" -maxdepth 1 -type f -name '*.json' -print -quit)"
  id="$(jq -r .container_id "$state_file")"; work="$(jq -r .work_volume_name "$state_file")"; bootstrap="$(jq -r .bootstrap_volume_name "$state_file")"
  [[ "$(docker inspect "$id" --format '{{.Config.Image}}')" == "$image" ]]
  if docker inspect "$id" | grep -Fq "$jit"; then exit 1; fi
  if grep -R -Fq "$jit" "$state_dir"; then exit 1; fi
  if [[ "$mode" == cancel ]]; then
    request="$(jq -cn --arg p "$placement" --arg id "$id" '{schema_version:1,payload:{action:"cancel",placement_id:$p,expected_id:$id}}')"
    result="$(printf '%s\n' "$request" | env CRF_CONTAINER_STATE_DIR="$state_dir" CRF_RUNNER_IMAGE="$image" CRF_DOCKER_PATH=/usr/bin/docker "$adapter")"
    jq -e '.payload.result == "terminal" and .payload.outcome == "cancelled"' <<<"$result" >/dev/null
  else
    docker kill "$id" >/dev/null; docker wait "$id" >/dev/null
    request="$(jq -cn --arg p "$placement" '{schema_version:1,payload:{action:"inspect",placement_id:$p,expected_id:null}}')"
    result="$(printf '%s\n' "$request" | env CRF_CONTAINER_STATE_DIR="$state_dir" CRF_RUNNER_IMAGE="$image" CRF_DOCKER_PATH=/usr/bin/docker "$adapter")"
    jq -e '.payload.result == "terminal" and .payload.outcome.failed.detail_code == "container_exit_nonzero"' <<<"$result" >/dev/null
  fi
  [[ -z "$(docker ps -aq --no-trunc --filter "id=$id")" ]]
  [[ -z "$(docker volume ls -q --filter "name=^${work}$")" && -z "$(docker volume ls -q --filter "name=^${bootstrap}$")" ]]
  jq -e '.handoff_phase == "complete" and .cleanup.container_removed and .cleanup.bootstrap_removed and .cleanup.work_removed' "$state_file" >/dev/null
}

run_case "${placements[0]}" cancel
run_case "${placements[1]}" terminal
echo "real-docker-container-adapter: PASS daemon=$(docker info --format '{{.Name}}') image=$image"
