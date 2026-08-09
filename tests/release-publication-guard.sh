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
cat >"$tmp/base.plg" <<'PLG'
<!DOCTYPE PLUGIN [
<!ENTITY pluginVersion "1.9.1">
<!ENTITY releaseTag    "v1.9.1">
<!ENTITY packageName   "ci-runner-farm-test-1.9.1.tgz">
<!ENTITY packageURL    "https://github.com/dinglebear-ai/ci-runner-farm/releases/download/v1.9.1/ci-runner-farm-test-1.9.1.tgz">
<!ENTITY packageMD5    "PACKAGE_MD5">
]>
<PLUGIN/>
PLG
sed -i "s/PACKAGE_MD5/$package_md5/" "$tmp/base.plg"
run_guard() {
  local release_plg="$tmp/repo/ci-runner-farm.plg"
  local release_package="$tmp/repo/ci-runner-farm-test-1.9.1.tgz"
  inject_before_entity() {
    python3 - "$release_plg" "$1" "$2" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
name, declaration = sys.argv[2:]
document = path.read_text()
needle = f"<!ENTITY {name} "
if document.count(needle) != 1:
    raise SystemExit(f"fixture expected one canonical {name} declaration")
path.write_text(document.replace(needle, declaration + needle, 1))
PY
  }
  cp "$tmp/base.plg" "$tmp/repo/ci-runner-farm.plg"
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
  case "${3:-valid}" in
    valid) ;;
    indented-valid)
      sed -i '/^<!ENTITY \(pluginVersion\|releaseTag\|packageURL\) /s/^/  /' "$release_plg"
      ;;
    missing-plugin-version)
      sed -i '/^<!ENTITY pluginVersion /d' "$release_plg"
      ;;
    missing-release-tag)
      sed -i '/^<!ENTITY releaseTag /d' "$release_plg"
      ;;
    missing-package-url)
      sed -i '/^<!ENTITY packageURL /d' "$release_plg"
      ;;
    duplicate-plugin-version)
      sed -i '/^]>$/i <!ENTITY pluginVersion "1.9.1">' "$release_plg"
      ;;
    duplicate-plugin-version-noncanonical)
      sed -i '/^]>$/i <!ENTITY pluginVersion "1.9.1" >' "$release_plg"
      ;;
    duplicate-plugin-version-indented)
      sed -i '/^<!ENTITY pluginVersion /i\  <!ENTITY pluginVersion "1.8.0">' "$release_plg"
      ;;
    duplicate-release-tag)
      sed -i '/^]>$/i <!ENTITY releaseTag "v1.9.1">' "$release_plg"
      ;;
    duplicate-release-tag-indented)
      sed -i '/^<!ENTITY releaseTag /i\  <!ENTITY releaseTag "v1.8.0">' "$release_plg"
      ;;
    duplicate-package-url)
      sed -i '/^]>$/i <!ENTITY packageURL "https://github.com/dinglebear-ai/ci-runner-farm/releases/download/v1.9.1/ci-runner-farm-test-1.9.1.tgz">' "$release_plg"
      ;;
    duplicate-package-url-indented)
      sed -i '/^<!ENTITY packageURL /i\  <!ENTITY packageURL "https://github.com/dinglebear-ai/ci-runner-farm/releases/download/v1.8.0/ci-runner-farm-test-1.9.1.tgz">' "$release_plg"
      ;;
    duplicate-plugin-version-multiline)
      inject_before_entity pluginVersion $'<!ENTITY\n pluginVersion\n "1.8.0">\n'
      ;;
    duplicate-release-tag-multiline)
      inject_before_entity releaseTag $'<!ENTITY\n releaseTag\n "v1.8.0">\n'
      ;;
    duplicate-package-url-multiline)
      inject_before_entity packageURL $'<!ENTITY\n packageURL\n "https://github.com/dinglebear-ai/ci-runner-farm/releases/download/v1.8.0/ci-runner-farm-test-1.9.1.tgz">\n'
      ;;
    xml-whitespace-valid)
      python3 - "$release_plg" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
document = path.read_bytes()
document = document.replace(b'<!ENTITY pluginVersion ', b'\t<!ENTITY pluginVersion ', 1)
document = document.replace(b'<!ENTITY releaseTag ', b'\r<!ENTITY releaseTag ', 1)
path.write_bytes(document)
PY
      ;;
    multiline-valid)
      python3 - "$release_plg" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
document = path.read_text()
for name in ("pluginVersion", "releaseTag", "packageURL"):
    document = document.replace(f"<!ENTITY {name} ", f"<!ENTITY\n {name}\n ", 1)
path.write_text(document)
PY
      ;;
    vertical-tab-prefix)
      python3 - "$release_plg" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'<!ENTITY pluginVersion ', b'\v<!ENTITY pluginVersion ', 1))
PY
      ;;
    form-feed-prefix)
      python3 - "$release_plg" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'<!ENTITY releaseTag ', b'\f<!ENTITY releaseTag ', 1))
PY
      ;;
    external-doctype)
      sed -i 's@<!DOCTYPE PLUGIN \[@<!DOCTYPE PLUGIN SYSTEM "http://network-must-not-run.invalid/release.dtd" [@' "$release_plg"
      ;;
    external-entity)
      sed -i '/^]>$/i <!ENTITY remote SYSTEM "http://network-must-not-run.invalid/entity">' "$release_plg"
      ;;
    stale-plugin-version)
      sed -i 's/pluginVersion "1\.9\.1"/pluginVersion "1.8.0"/' "$release_plg"
      ;;
    stale-release-tag)
      sed -i 's/releaseTag    "v1\.9\.1"/releaseTag    "v1.8.0"/' "$release_plg"
      ;;
    stale-package-url-tag)
      sed -i 's@releases/download/v1\.9\.1/@releases/download/v1.8.0/@' "$release_plg"
      ;;
    wrong-package-url-asset)
      sed -i 's@/ci-runner-farm-test-1\.9\.1\.tgz">@/other-package.tgz">@' "$release_plg"
      ;;
    *) exit 67 ;;
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

# The published plugin metadata must be one exact release identity, not merely
# a byte-for-byte match to a stale default-branch file with a valid package MD5.
for metadata_case in \
  missing-plugin-version \
  missing-release-tag \
  missing-package-url \
  duplicate-plugin-version \
  duplicate-plugin-version-noncanonical \
  duplicate-plugin-version-indented \
  duplicate-release-tag \
  duplicate-release-tag-indented \
  duplicate-package-url \
  duplicate-package-url-indented \
  duplicate-plugin-version-multiline \
  duplicate-release-tag-multiline \
  duplicate-package-url-multiline \
  stale-plugin-version \
  stale-release-tag \
  stale-package-url-tag \
  wrong-package-url-asset \
  vertical-tab-prefix \
  form-feed-prefix \
  external-doctype \
  external-entity; do
  if run_guard 1 complete "$metadata_case" \
      >"$tmp/$metadata_case.out" 2>"$tmp/$metadata_case.err"; then
    echo "FAIL: release metadata case '$metadata_case' passed the publication guard" >&2
    new_failures=$((new_failures + 1))
  fi
done

run_guard 1 complete indented-valid >"$tmp/indented-valid.out" 2>"$tmp/indented-valid.err" ||
  crf_fail "XML-valid leading whitespace was rejected for release identity entities"
run_guard 1 complete xml-whitespace-valid >"$tmp/xml-whitespace-valid.out" 2>"$tmp/xml-whitespace-valid.err" ||
  crf_fail "XML-valid tab or carriage-return whitespace was rejected"
run_guard 1 complete multiline-valid >"$tmp/multiline-valid.out" 2>"$tmp/multiline-valid.err" ||
  crf_fail "XML-valid multiline release identity declarations were rejected"

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
