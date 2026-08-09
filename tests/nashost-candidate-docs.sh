#!/usr/bin/env bash
# Markdown backticks are literal contract text.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."

README=deployments/nashost/README.md
README_TEXT="$(tr '\n' ' ' <"$README" | tr -s '[:space:]' ' ')"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_text() { grep -Fq -- "$1" <<<"$README_TEXT" || fail "Nashost candidate documentation is missing: $1"; }

require_text 'candidate-<context-sha-prefix>-<time>-<pid>'
require_text 'exact Dockerfile bytes'
require_text '`kache-supervise.sh` when the Dockerfile copies it'
require_text '`endpoint-validation.sh` when the Dockerfile copies it'
require_text 'domain-separated digest of the protected Kache endpoint'
require_text 'endpoint itself is passed as a protected build argument and is not stored in candidate metadata'
require_text 'full context SHA'
require_text 'exact image ID'

if grep -Fq 'candidate-<dockerfile-sha>' <<<"$README_TEXT"; then
  fail 'Nashost candidate documentation still identifies tags by Dockerfile SHA alone'
fi

echo 'nashost-candidate-docs: OK'
