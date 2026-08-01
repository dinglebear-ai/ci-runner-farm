#!/usr/bin/env bash

: "${CRF_FAKE_GITHUB_DIR:?set CRF_FAKE_GITHUB_DIR}"
mkdir -p "$CRF_FAKE_GITHUB_DIR"

crf_fake_github() {
  local operation="$1" file="$CRF_FAKE_GITHUB_DIR/$operation.calls" count=0
  shift
  [ -f "$file" ] && count="$(cat "$file")"
  printf '%s\n' "$((count + 1))" > "$file"
  [ ! -f "$CRF_FAKE_GITHUB_DIR/$operation.out" ] || cat "$CRF_FAKE_GITHUB_DIR/$operation.out"
  [ ! -f "$CRF_FAKE_GITHUB_DIR/$operation.rc" ] || return "$(cat "$CRF_FAKE_GITHUB_DIR/$operation.rc")"
}
