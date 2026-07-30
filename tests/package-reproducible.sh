#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo"
cp -a build-plg.sh src VERSION CHANGELOG.md "$tmp/repo/"
(
  cd "$tmp/repo"
  DATE=2026.07.30.1200 BUILD_NUMBER=1 INTERNAL_VERSION=9.9.9 REPO=jmagar/ci-runner-farm ./build-plg.sh >/dev/null
  sha256sum ci-runner-farm.tgz | cut -d' ' -f1 > "$tmp/sha1"
  tar -tzf ci-runner-farm.tgz | sort > "$tmp/list1"
  tar -tvzf ci-runner-farm.tgz > "$tmp/modes1"
  ./build-plg.sh --tgz-only >/dev/null
  sha256sum ci-runner-farm.tgz | cut -d' ' -f1 > "$tmp/sha2"
  tar -tzf ci-runner-farm.tgz | sort > "$tmp/list2"
  tar -tvzf ci-runner-farm.tgz > "$tmp/modes2"
)
cmp "$tmp/sha1" "$tmp/sha2"
cmp "$tmp/list1" "$tmp/list2"
cmp "$tmp/modes1" "$tmp/modes2"
tar -xOf "$tmp/repo/ci-runner-farm.tgz" ./include/runner-entrypoint.sh | grep -Fq 'secret.in'
grep -Fq 'chmod 0755 "$PLGDIR/include/runner-entrypoint.sh"' "$tmp/repo/ci-runner-farm.plg"
echo 'package-reproducible: OK'
