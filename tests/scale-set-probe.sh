#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mod=tools/crf-scaleset
grep -Fq 'go 1.25.3' "$mod/go.mod"
grep -Fq 'github.com/actions/scaleset v0.4.0' "$mod/go.mod"
grep -Fq '6ce025902cd964747a078c2aabe7340ebc667eca' "$mod/cmd/crf-scaleset/main.go"
! rg -q 'listener\\.New|listener\\.Run' "$mod"
go test -C "$mod" ./...
go vet -C "$mod" ./...

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/run" "$tmpdir/cfg"
printf '{}\n' >"$tmpdir/cfg/compatibility.json"
chmod 0600 "$tmpdir/cfg/compatibility.json"
printf '%s\n' '#!/bin/sh' \
  'printf '\''{"ok":false,"code":"invalid_compatibility_record","error":"helper_digest_mismatch"}\n'\''' \
  'exit 2' >"$tmpdir/helper"
chmod 0755 "$tmpdir/helper"
SCRIPT_DIR="$tmpdir" RUNDIR="$tmpdir/run" CFGDIR="$tmpdir/cfg" \
  SCALESET_HELPER="$tmpdir/helper" SCALESET_COMPAT="$tmpdir/cfg/compatibility.json" \
  bash -c '. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh; [ "$(scaleset_record_reason)" = helper_digest_mismatch ]'
echo 'scale-set-probe: OK'
