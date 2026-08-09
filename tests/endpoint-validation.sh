#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/deployments/nashost/endpoint-validation.sh"
VECTORS="$ROOT/tests/fixtures/endpoint-validation-vectors.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -x "$VALIDATOR" ] || fail "canonical endpoint validator is not executable"

# Installer and audit must consume the canonical library, not carry private
# implementations that can drift again.
for consumer in deployments/nashost/fleet-audit.sh deployments/nashost/install-fleet-audit.sh; do
  grep -Fq 'endpoint-validation.sh' "$ROOT/$consumer" || fail "$consumer does not load the shared validator"
  ! grep -Eq '^require_(kache_endpoint|gotify_url)\(\)' "$ROOT/$consumer" ||
    fail "$consumer still defines a private endpoint validator"
done

# Docker builds use the same executable. Exercise an independent physical copy
# for each build recipe and the installed audit runtime copy as well as source.
implementations=("source:$VALIDATOR")
install -m 0755 "$VALIDATOR" "$tmp/installed-endpoint-validation.sh"
implementations+=("installed-runtime:$tmp/installed-endpoint-validation.sh")
for dockerfile in runner.Dockerfile kache-overlay.Dockerfile; do
  grep -Fq 'COPY endpoint-validation.sh /usr/local/libexec/ci-runner-farm/endpoint-validation.sh' \
    "$ROOT/deployments/nashost/$dockerfile" || fail "$dockerfile does not copy the canonical validator"
  # Literal Dockerfile expansion contract.
  # shellcheck disable=SC2016
  grep -Fq '/usr/local/libexec/ci-runner-farm/endpoint-validation.sh kache "$endpoint"' \
    "$ROOT/deployments/nashost/$dockerfile" || fail "$dockerfile does not execute the canonical validator"
  cp "$VALIDATOR" "$tmp/$dockerfile-validator"
  chmod 0755 "$tmp/$dockerfile-validator"
  implementations+=("$dockerfile:$tmp/$dockerfile-validator")
done

for implementation in "${implementations[@]}"; do
  label="${implementation%%:*}"
  executable="${implementation#*:}"
  while IFS=$'\t' read -r kind expectation endpoint || [ -n "${kind:-}" ]; do
    case "${kind:-}" in ''|'#'*) continue ;; esac
    [ "${endpoint:-}" != '<empty>' ] || endpoint=''
    status=0
    "$executable" "$kind" "${endpoint:-}" >/dev/null 2>&1 || status=$?
    case "$expectation:$status" in
      accept:0|reject:[1-9]*) ;;
      *) fail "$label $kind $expectation vector produced status $status: ${endpoint:-<empty>}" ;;
    esac
  done <"$VECTORS"
done

echo 'endpoint-validation: OK'
