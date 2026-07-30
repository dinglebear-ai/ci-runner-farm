#!/usr/bin/env bash
# Syntax-check the inline Fleet/Settings JavaScript after replacing server-side
# PHP interpolation expressions with inert JavaScript literals.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v node >/dev/null 2>&1 || { echo 'SKIP: node unavailable'; exit 0; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for page in \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page; do
  out="$tmpdir/$(basename "$page").js"
  awk '
    /^<script>$/ { inside=1; next }
    /^<\/script>$/ { inside=0; next }
    inside { print }
  ' "$page" | perl -0pe 's/<\?=.*?\?>/null/gs' > "$out"
  node --check "$out"
done

echo 'ui-js: OK'
