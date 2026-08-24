#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/publish-distributed-release.yml"

fail() {
  printf 'distributed publication workflow contract: %s\n' "$*" >&2
  exit 1
}

require_fixed() {
  local needle="$1"
  local description="$2"
  grep -Fq -- "$needle" "$WORKFLOW" || fail "$description"
}

require_regex() {
  local pattern="$1"
  local description="$2"
  grep -Eq -- "$pattern" "$WORKFLOW" || fail "$description"
}

forbid_fixed() {
  local needle="$1"
  local description="$2"
  if grep -Fq -- "$needle" "$WORKFLOW"; then
    fail "$description"
  fi
}

[[ -f "$WORKFLOW" ]] || fail "missing .github/workflows/publish-distributed-release.yml"

# Publication is an explicit, immutable release operation. The only operator
# input is a required semantic v-tag; it must not fall back to the workflow ref.
require_fixed 'workflow_dispatch:' 'manual workflow_dispatch trigger is missing'
require_fixed 'release_tag:' 'release_tag workflow input is missing'
require_fixed 'required: true' 'release_tag must be required'
require_regex '\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$' \
  'release_tag must be validated as an exact vMAJOR.MINOR.PATCH tag'
require_fixed 'ref: refs/tags/${{ env.RELEASE_TAG }}' 'checkout must use the requested immutable release tag'
forbid_fixed 'ref: ${{ github.ref }}' 'publication must not checkout the mutable dispatch ref'
forbid_fixed 'ref: ${{ github.event.release.target_commitish }}' 'publication must not checkout mutable target_commitish'

# The checked-out commit must be proven to be the commit named by the exact tag.
require_fixed 'git rev-parse "refs/tags/$RELEASE_TAG^{commit}"' 'workflow must resolve the release tag to its commit'
require_fixed 'git rev-parse HEAD' 'workflow must resolve and compare the checked-out commit'

# Publishing requires narrowly explicit repository and package permissions.
require_regex '^[[:space:]]+contents:[[:space:]]+write([[:space:]]|$)' 'contents: write permission is missing'
require_regex '^[[:space:]]+packages:[[:space:]]+write([[:space:]]|$)' 'packages: write permission is missing'

# The runner image is one multi-platform manifest, pushed to GHCR, and its
# immutable digest is captured for downstream configuration and verification.
require_fixed 'linux/amd64,linux/arm64' 'image publish must cover amd64 and arm64'
require_fixed 'push: true' 'multi-architecture image must be pushed'
require_fixed 'deployments/distributed/runner.Dockerfile' 'distributed runner Dockerfile is not the publication source'
require_regex '(steps\.[A-Za-z0-9_-]+\.outputs\.digest|metadata-containerimage-digest)' \
  'published manifest digest is not captured'
require_fixed 'docker buildx imagetools inspect' 'published manifest must be inspected from the registry'
require_fixed 'distributed-runner-image.txt' 'immutable image identity receipt is not published'

# The release must carry the verified distributed Linux install bundle as well
# as a checksum, and the workflow must re-download/inspect what it published.
require_fixed 'scripts/build-distributed-bundle.sh' 'distributed bundle is not built'
require_fixed 'scripts/verify-distributed-bundle.sh' 'distributed bundle is not verified before upload'
require_fixed 'gh release upload' 'distributed bundle is not attached to the GitHub release'
require_fixed '.sha256' 'distributed bundle checksum asset is missing'
require_fixed 'sha256sum "$archive_name"' 'bundle checksum must be portable after release download'
require_fixed 'gh release download' 'publication verification must download the release assets'
require_regex 'sha256sum[[:space:]]+(-c|--check)' 'publication verification must verify the downloaded checksum'

printf 'distributed publication workflow contract passed\n'
