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
echo 'scale-set-probe: OK'
