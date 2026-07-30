#!/usr/bin/env bash

: "${CRF_FAKE_DOCKER_DIR:?set CRF_FAKE_DOCKER_DIR}"
mkdir -p "$CRF_FAKE_DOCKER_DIR"

crf_fake_docker_count() {
  local operation="$1" file="$CRF_FAKE_DOCKER_DIR/$operation.calls" count=0
  [ -f "$file" ] && count="$(cat "$file")"
  printf '%s\n' "$((count + 1))" > "$file"
}

docker() {
  local operation="${1:-}"
  crf_fake_docker_count "$operation"
  if [ -f "$CRF_FAKE_DOCKER_DIR/$operation.rc" ]; then
    return "$(cat "$CRF_FAKE_DOCKER_DIR/$operation.rc")"
  fi
  [ ! -f "$CRF_FAKE_DOCKER_DIR/$operation.out" ] || cat "$CRF_FAKE_DOCKER_DIR/$operation.out"
}
