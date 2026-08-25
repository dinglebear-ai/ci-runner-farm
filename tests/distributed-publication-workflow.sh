#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/publish-distributed-release.yml"
LINT_WORKFLOW="$ROOT/.github/workflows/lint.yml"
SOURCE_GUARD="$ROOT/scripts/verify-distributed-release-source.sh"
IMAGE_RESOLVER="$ROOT/scripts/resolve-distributed-image.sh"
BUNDLE_BUILDER="$ROOT/scripts/build-distributed-bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
[[ -x "$SOURCE_GUARD" ]] || fail "release source guard is missing or not executable"
[[ -x "$IMAGE_RESOLVER" ]] || fail "image resolver is missing or not executable"
[[ -x "$BUNDLE_BUILDER" ]] || fail "bundle builder is missing or not executable"

# Publication is an explicit, immutable release operation. The only operator
# input is a required semantic v-tag; it must not fall back to the workflow ref.
require_fixed 'workflow_dispatch:' 'manual workflow_dispatch trigger is missing'
require_fixed 'release_tag:' 'release_tag workflow input is missing'
require_fixed 'required: true' 'release_tag must be required'
require_regex '\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$' \
  'release_tag must be validated as an exact vMAJOR.MINOR.PATCH tag'
# shellcheck disable=SC2016 # Match literal GitHub expression syntax.
require_fixed 'ref: refs/tags/${{ env.RELEASE_TAG }}' 'checkout must use the requested immutable release tag'
# shellcheck disable=SC2016 # Match literal GitHub expression syntax.
forbid_fixed 'ref: ${{ github.ref }}' 'publication must not checkout the mutable dispatch ref'
# shellcheck disable=SC2016 # Match literal GitHub expression syntax.
forbid_fixed 'ref: ${{ github.event.release.target_commitish }}' 'publication must not checkout mutable target_commitish'

# The checked-out commit must be proven to be the commit named by the exact tag.
# shellcheck disable=SC2016 # Match a literal shell fragment in the workflow.
require_fixed 'git rev-parse "refs/tags/$RELEASE_TAG^{commit}"' 'workflow must resolve the release tag to its commit'
require_fixed 'scripts/verify-distributed-release-source.sh' 'workflow must repeatedly verify tag and checkout identity'

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
# shellcheck disable=SC2016
require_fixed 'scripts/resolve-distributed-image.sh "$IMAGE_NAME" "$RELEASE_TAG"' 'release image tag lookup is not fail closed'
require_fixed 'distributed-runner-image.txt' 'immutable image identity receipt is not published'
require_fixed 'org.opencontainers.image.revision' 'existing images are not bound to the release commit'
# Availability to clean nodes is now *proven* rather than assumed: GitHub has
# no API to set container visibility (PATCH /orgs/{org}/packages/container/{name}
# is unrouted and 404s regardless of scope), so the workflow asserts an
# anonymous pull of the published digest instead of attempting a mutation.
# shellcheck disable=SC2016
require_fixed 'https://ghcr.io/token?scope=repository:' 'published image availability to clean nodes is not proven anonymously'
# shellcheck disable=SC2016
require_fixed 'https://ghcr.io/v2/${IMAGE_REPO}/manifests/${IMAGE_DIGEST}' 'anonymous availability proof does not target the published digest'
require_fixed 'the package is not public' 'anonymous availability proof does not fail closed'
# shellcheck disable=SC2016
require_fixed 'docker pull --platform "$platform"' 'anonymous verification does not pull both runtime images'

# The release must carry the verified distributed Linux install bundle as well
# as a checksum, and the workflow must re-download/inspect what it published.
require_fixed 'scripts/build-distributed-bundle.sh' 'distributed bundle is not built'
require_fixed 'scripts/verify-distributed-bundle.sh' 'distributed bundle is not verified before upload'
require_fixed 'gh release upload' 'distributed bundle is not attached to the GitHub release'
require_fixed '.sha256' 'distributed bundle checksum asset is missing'
# shellcheck disable=SC2016 # Match a literal shell fragment in the workflow.
require_fixed 'sha256sum "$archive_name"' 'bundle checksum must be portable after release download'
require_fixed 'gh release download' 'publication verification must download the release assets'
require_regex 'sha256sum[[:space:]]+(-c|--check)' 'publication verification must verify the downloaded checksum'

# The hosted Linux gate must exercise the exact command-substitution contract,
# require one existing archive, and feed that captured path to the verifier.
# shellcheck disable=SC2016
grep -Fq 'bundle="$(scripts/build-distributed-bundle.sh)"' "$LINT_WORKFLOW" || fail 'hosted bundle build does not exercise command substitution'
# shellcheck disable=SC2016
grep -Fq 'test "$(printf '\''%s\n'\'' "$bundle" | wc -l)" -eq 1' "$LINT_WORKFLOW" || fail 'hosted bundle build does not enforce exactly one stdout line'
# shellcheck disable=SC2016
grep -Fq 'test -f "$bundle"' "$LINT_WORKFLOW" || fail 'hosted bundle build does not require the captured archive to exist'
# shellcheck disable=SC2016
grep -Fq 'scripts/verify-distributed-bundle.sh "$CRF_DISTRIBUTED_BUNDLE"' "$LINT_WORKFLOW" || fail 'hosted verifier does not consume the captured archive path'
if grep -Eq 'exec[[:space:]]+3>&1|>&3([^0-9]|$)' "$BUNDLE_BUILDER"; then
  fail 'bundle builder leaks a preserved result descriptor into child tools'
fi
grep -Fq 'build_bundle >&2' "$BUNDLE_BUILDER" || fail 'bundle build diagnostics are not grouped onto stderr'
# shellcheck disable=SC2016 # Match the literal archive variable in the builder.
grep -Fq 'printf "%s\n" "$archive"' "$BUNDLE_BUILDER" || fail 'bundle path is not emitted on stdout'

# The availability proof must need no credential whatsoever. This is stricter
# than the previous contract (which required a dedicated admin token): a job
# that carries no secret cannot leak or misuse one, and a proof that passes
# without credentials is exactly the property clean nodes depend on.
if grep -Eq 'publish-image-visibility:' "$WORKFLOW"; then
  visibility_job="$(awk '/^  publish-image-visibility:/{flag=1} /^  [a-z-]+:$/{if(flag && $0 !~ /publish-image-visibility/) flag=0} flag' "$WORKFLOW")"
  if printf '%s' "$visibility_job" | grep -Eq 'secrets\.'; then
    fail 'anonymous availability proof must not consume any secret'
  fi
fi
require_fixed 'publish-image-visibility:' 'package administration is not isolated in a dedicated job'
require_fixed 'permissions: {}' 'package administration job retains unnecessary GitHub token permissions'
require_fixed 'needs: publish-image' 'package visibility can run before the image is published'
if grep -Fq 'UNRAID_BOT_GITHUB_ADMIN_TOKEN || github.token' "$WORKFLOW"; then
  fail 'package administration silently falls back to an insufficient token'
fi

# Registry lookup distinguishes an absent immutable tag from operational or
# malformed failures. Only a genuine 404 is allowed to select the build path.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'/token?'*) printf '{"token":"fixture-token"}\n' ;;
  *)
    header_file=''
    previous=''
    for argument in "$@"; do
      [[ "$previous" == '--dump-header' ]] && header_file="$argument"
      previous="$argument"
    done
    if [[ "${MOCK_STATUS:-200}" == 200 && -n "$header_file" ]]; then
      printf 'Docker-Content-Digest: %s\r\n' "${MOCK_DIGEST:-sha256:$(printf 'a%.0s' {1..64})}" > "$header_file"
    fi
    printf '%s' "${MOCK_STATUS:-200}"
    ;;
esac
EOF
chmod +x "$TMP/bin/curl"
resolver_env=(PATH="$TMP/bin:$PATH")
digest="$(env "${resolver_env[@]}" "$IMAGE_RESOLVER" ghcr.io/example/image "sha-$(printf 'b%.0s' {1..40})" actor token)"
[[ "$digest" == "sha256:$(printf 'a%.0s' {1..64})" ]] || fail 'valid registry digest was not returned'
[[ "$(env "${resolver_env[@]}" MOCK_STATUS=404 "$IMAGE_RESOLVER" ghcr.io/example/image "sha-$(printf 'b%.0s' {1..40})" actor token)" == absent ]] || fail '404 was not classified as absent'
if env "${resolver_env[@]}" MOCK_STATUS=401 "$IMAGE_RESOLVER" ghcr.io/example/image "sha-$(printf 'b%.0s' {1..40})" actor token >/dev/null 2>&1; then
  fail 'registry authorization failure was treated as image absence'
fi
if env "${resolver_env[@]}" MOCK_DIGEST=invalid "$IMAGE_RESOLVER" ghcr.io/example/image "sha-$(printf 'b%.0s' {1..40})" actor token >/dev/null 2>&1; then
  fail 'malformed registry digest was accepted'
fi
[[ "$(env "${resolver_env[@]}" MOCK_STATUS=404 "$IMAGE_RESOLVER" ghcr.io/example/image v1.2.3 actor token)" == absent ]] || fail 'release-tag 404 was not classified as absent'
if env "${resolver_env[@]}" MOCK_STATUS=503 "$IMAGE_RESOLVER" ghcr.io/example/image v1.2.3 actor token >/dev/null 2>&1; then
  fail 'release-tag registry failure was treated as absence'
fi

# The source guard detects a force-moved remote tag instead of publishing
# assets against a stale validation snapshot.
git init --bare -q "$TMP/origin.git"
git init -q "$TMP/source"
mkdir -p "$TMP/source/scripts"
cp "$SOURCE_GUARD" "$TMP/source/scripts/"
printf '1.2.3\n' > "$TMP/source/VERSION"
git -C "$TMP/source" add VERSION scripts/verify-distributed-release-source.sh
git -C "$TMP/source" -c user.name=test -c user.email=test@example.invalid commit -qm initial
expected_commit="$(git -C "$TMP/source" rev-parse HEAD)"
git -C "$TMP/source" tag v1.2.3
git -C "$TMP/source" remote add origin "$TMP/origin.git"
git -C "$TMP/source" push -q origin HEAD:main refs/tags/v1.2.3
"$TMP/source/scripts/verify-distributed-release-source.sh" v1.2.3 "$expected_commit"
printf 'changed\n' >> "$TMP/source/VERSION"
git -C "$TMP/source" add VERSION
git -C "$TMP/source" -c user.name=test -c user.email=test@example.invalid commit -qm moved
git -C "$TMP/source" tag -f v1.2.3 >/dev/null
git -C "$TMP/source" push -q --force origin refs/tags/v1.2.3
if "$TMP/source/scripts/verify-distributed-release-source.sh" v1.2.3 "$expected_commit" >/dev/null 2>&1; then
  fail 'force-moved release tag was accepted'
fi

printf 'distributed publication workflow contract passed\n'
