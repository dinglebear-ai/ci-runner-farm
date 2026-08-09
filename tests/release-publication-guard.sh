#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

. tests/lib/assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

guard="$PWD/scripts/verify-release-publication.sh"
[ -x "$guard" ] || crf_fail "release publication guard is not executable"

mkdir -p "$tmp/bin" "$tmp/repo"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2 $3" in
  'release view v1.9.1')
    [[ "${FAKE_RELEASE_EXISTS:-0}" == 1 ]] || exit 1
    case "${FAKE_RELEASE_ASSETS:-complete}" in
      complete|corrupt-plg|corrupt-package)
        assets='[{"name":"ci-runner-farm.plg"},{"name":"ci-runner-farm-test-1.9.1.tgz"}]'
        ;;
      missing-plg)
        assets='[{"name":"ci-runner-farm-test-1.9.1.tgz"}]'
        ;;
      missing-package)
        assets='[{"name":"ci-runner-farm.plg"}]'
        ;;
      *) exit 65 ;;
    esac
    printf '{"assets":%s,"isDraft":false,"isPrerelease":false,"tagName":"v1.9.1"}\n' "$assets"
    ;;
  'release download v1.9.1')
    out=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --dir ]; then out="$2"; shift 2; else shift; fi
    done
    [ -n "$out" ] || exit 66
    mkdir -p "$out"
    cp "$FAKE_RELEASE_PLG" "$out/ci-runner-farm.plg"
    cp "$FAKE_RELEASE_PACKAGE" "$out/ci-runner-farm-test-1.9.1.tgz"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$tmp/bin/gh"
printf '{".":"1.9.1"}\n' >"$tmp/repo/.release-please-manifest.json"
printf 'trusted package bytes\n' >"$tmp/repo/ci-runner-farm-test-1.9.1.tgz"
package_md5="$(md5sum "$tmp/repo/ci-runner-farm-test-1.9.1.tgz" | awk '{print $1}')"
cat >"$tmp/repo/ci-runner-farm.plg" <<'PLG'
<!DOCTYPE PLUGIN [
<!ENTITY packageName   "ci-runner-farm-test-1.9.1.tgz">
<!ENTITY packageMD5    "PACKAGE_MD5">
]>
PLG
sed -i "s/PACKAGE_MD5/$package_md5/" "$tmp/repo/ci-runner-farm.plg"
run_guard() {
  local release_plg="$tmp/repo/ci-runner-farm.plg"
  local release_package="$tmp/repo/ci-runner-farm-test-1.9.1.tgz"
  case "${2:-complete}" in
    corrupt-plg)
      release_plg="$tmp/corrupt.plg"
      printf 'substituted plugin manifest\n' >"$release_plg"
      ;;
    corrupt-package)
      release_package="$tmp/corrupt.tgz"
      printf 'substituted package bytes\n' >"$release_package"
      ;;
  esac
  (
    cd "$tmp/repo"
    PATH="$tmp/bin:$PATH" \
      REPO=dinglebear-ai/ci-runner-farm \
      FAKE_RELEASE_EXISTS="$1" \
      FAKE_RELEASE_ASSETS="${2:-complete}" \
      FAKE_RELEASE_PLG="$release_plg" \
      FAKE_RELEASE_PACKAGE="$release_package" \
      "$guard"
  )
}

# A merged release PR has already advanced the manifest. If release-please then
# creates neither a tag nor a release, the workflow must fail instead of hiding
# the unpublished version behind skipped downstream jobs.
if run_guard 0 >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  crf_fail "unpublished manifest version passed the release publication guard"
fi
grep -Fq 'v1.9.1' "$tmp/missing.err" ||
  crf_fail "publication failure does not identify the missing release tag"

# A GitHub Release object is not an installable publication until both the
# stable plugin manifest and the exact package named by that manifest exist.
new_failures=0
if run_guard 1 missing-plg >"$tmp/missing-plg.out" 2>"$tmp/missing-plg.err"; then
  echo "FAIL: release missing ci-runner-farm.plg passed the publication guard" >&2
  new_failures=$((new_failures + 1))
else
  grep -Fq 'ci-runner-farm.plg' "$tmp/missing-plg.err" ||
    crf_fail "missing-plugin failure does not identify ci-runner-farm.plg"
fi

if run_guard 1 missing-package >"$tmp/missing-package.out" 2>"$tmp/missing-package.err"; then
  echo "FAIL: release missing its packageName asset passed the publication guard" >&2
  new_failures=$((new_failures + 1))
else
  grep -Fq 'ci-runner-farm-test-1.9.1.tgz' "$tmp/missing-package.err" ||
    crf_fail "missing-package failure does not identify the packageName asset"
fi

if run_guard 1 corrupt-plg >"$tmp/corrupt-plg.out" 2>"$tmp/corrupt-plg.err"; then
  echo "FAIL: substituted ci-runner-farm.plg passed the publication guard" >&2
  new_failures=$((new_failures + 1))
fi

if run_guard 1 corrupt-package >"$tmp/corrupt-package.out" 2>"$tmp/corrupt-package.err"; then
  echo "FAIL: package bytes that disagree with packageMD5 passed the publication guard" >&2
  new_failures=$((new_failures + 1))
fi

# On an ordinary main push while a release PR remains open, the manifest still
# names the last published version, so the post-action assertion remains green.
run_guard 1 >"$tmp/published.out" 2>"$tmp/published.err" ||
  crf_fail "published manifest version failed the release publication guard"

# The same observable state follows a successful release_created result: the
# newly advertised manifest version has a non-draft GitHub Release.
grep -Fq 'v1.9.1' "$tmp/published.out" ||
  crf_fail "publication success does not identify the verified release tag"

# Manual dispatch can target a feature ref. The release action still operates on
# the repository default branch, so the terminal audit must explicitly inspect
# that branch instead of actions/checkout's event-ref default.
verify_job="$tmp/verify-job.yml"
awk '
  /^  verify-release-publication:/ { capture = 1 }
  capture && /^  [a-zA-Z0-9_-]+:/ && $1 != "verify-release-publication:" { exit }
  capture { print }
' .github/workflows/release-please.yml >"$verify_job"
if [ ! -s "$verify_job" ]; then
  echo "FAIL: release publication verification is not a terminal job" >&2
  new_failures=$((new_failures + 1))
else
  grep -Fq 'publish-plugin-release' "$verify_job" ||
    crf_fail "release publication verification does not wait for artifact publication"
  grep -Fq 'ref: ${{ github.event.repository.default_branch }}' "$verify_job" ||
    crf_fail "workflow_dispatch publication verification can inspect a non-default ref"
  grep -Fq 'permissions:' "$verify_job" ||
    crf_fail "publication audit does not declare least-privilege permissions"
  grep -Fq 'contents: read' "$verify_job" ||
    crf_fail "publication audit has more than read-only release access"
  grep -Fq 'GH_TOKEN: ${{ github.token }}' "$verify_job" ||
    crf_fail "publication audit exposes a broader token than github.token"
  if grep -Fq 'UNRAID_BOT_GITHUB_ADMIN_TOKEN' "$verify_job"; then
    crf_fail "publication audit exposes the organization admin token"
  fi
fi

[ "$new_failures" -eq 0 ] || exit 1

echo "release-publication-guard: OK"
