#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo"
cp -a build-plg.sh src tools VERSION CHANGELOG.md "$tmp/repo/"
go125="$(crf_go125)"
(
  cd "$tmp/repo"
  CRF_GO="$go125" DATE=2026.07.30.1200 BUILD_NUMBER=1 INTERNAL_VERSION=9.9.9 REPO=dinglebear-ai/ci-runner-farm ./build-plg.sh >/dev/null
  sha256sum ci-runner-farm.tgz | cut -d' ' -f1 > "$tmp/sha1"
  tar -tzf ci-runner-farm.tgz | sort > "$tmp/list1"
  tar -tvzf ci-runner-farm.tgz > "$tmp/modes1"
  CRF_GO="$go125" ./build-plg.sh --tgz-only >/dev/null
  sha256sum ci-runner-farm.tgz | cut -d' ' -f1 > "$tmp/sha2"
  tar -tzf ci-runner-farm.tgz | sort > "$tmp/list2"
  tar -tvzf ci-runner-farm.tgz > "$tmp/modes2"
)
cmp "$tmp/sha1" "$tmp/sha2"
cmp "$tmp/list1" "$tmp/list2"
cmp "$tmp/modes1" "$tmp/modes2"
# Extract to a file rather than piping into grep -q. Under `set -o pipefail`,
# grep exiting on its first match closes the pipe while tar is still streaming
# the compressed archive, so tar takes SIGPIPE and fails the pipeline (exit 141,
# "tar: Cannot write: Broken pipe"). That race is scheduling-dependent, so it
# shows up as an intermittent CI failure unrelated to whatever is being tested.
tar -xOf "$tmp/repo/ci-runner-farm.tgz" ./include/runner-entrypoint.sh > "$tmp/entrypoint-packaged.sh"
grep -Fq 'secret.in' "$tmp/entrypoint-packaged.sh"
grep -Fq 'chmod 0755 "$PLGDIR/include/runner-entrypoint.sh"' "$tmp/repo/ci-runner-farm.plg"
grep -Fq 'chmod 0755 "$PLGDIR/bin/crf-scaleset"' "$tmp/repo/ci-runner-farm.plg"
grep -Fxq './bin/crf-scaleset' "$tmp/list2"
mkdir "$tmp/package"
tar -xzf "$tmp/repo/ci-runner-farm.tgz" -C "$tmp/package"
for executable in \
  bin/crf-scaleset \
  include/runner-farm.sh \
  include/runner-entrypoint.sh \
  event/docker_started \
  event/stopping_docker \
  nchan/ci_runner_farm; do
  [ -x "$tmp/package/$executable" ] ||
    { echo "package-reproducible: $executable is not executable" >&2; exit 1; }
done
echo 'package-reproducible: OK'
