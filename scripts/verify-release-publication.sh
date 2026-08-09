#!/usr/bin/env bash
set -euo pipefail

: "${REPO:?REPO is required}"

version="$(python3 -c 'import json;print(json.load(open(".release-please-manifest.json"))["."])')"
tag="v${version}"
if ! release="$(gh release view "$tag" --repo "$REPO" --json assets,isDraft,isPrerelease,tagName)"; then
  echo "::error::manifest advertises $tag, but that GitHub Release does not exist" >&2
  exit 1
fi
python3 -c '
import json, sys

release = json.load(sys.stdin)
tag = sys.argv[1]
published = (
    release.get("tagName") == tag
    and not release.get("isDraft")
    and not release.get("isPrerelease")
)
if not published:
    sys.exit(f"manifest advertises {tag}, but its GitHub Release is not published")
asset_names = {
    asset.get("name")
    for asset in release.get("assets", [])
    if isinstance(asset, dict)
}
if "ci-runner-farm.plg" not in asset_names:
    sys.exit(f"manifest advertises {tag}, but its GitHub Release is missing required asset: ci-runner-farm.plg")
' "$tag" <<<"$release"

asset_dir="$(mktemp -d)"
trap 'rm -rf "$asset_dir"' EXIT
gh release download "$tag" --repo "$REPO" --pattern ci-runner-farm.plg --dir "$asset_dir"

released_plg="$asset_dir/ci-runner-farm.plg"
if ! cmp -s ci-runner-farm.plg "$released_plg"; then
  echo "::error::published ci-runner-farm.plg does not match the default-branch manifest" >&2
  exit 1
fi

# Parse the package contract from the bytes that are actually published. The
# byte comparison above makes this equivalent to the reviewed default-branch
# manifest while still detecting a substituted release asset.
package_asset="$(sed -n 's/^<!ENTITY packageName[[:space:]]*"\([^"]*\)">$/\1/p' "$released_plg")"
package_md5="$(sed -n 's/^<!ENTITY packageMD5[[:space:]]*"\([0-9a-f]*\)">$/\1/p' "$released_plg")"
if [[ ! "$package_asset" =~ ^ci-runner-farm-[A-Za-z0-9._-]+\.tgz$ ]]; then
  echo "::error::published ci-runner-farm.plg has an invalid packageName entity" >&2
  exit 1
fi
if [[ ! "$package_md5" =~ ^[0-9a-f]{32}$ ]]; then
  echo "::error::published ci-runner-farm.plg has an invalid packageMD5 entity" >&2
  exit 1
fi

python3 -c '
import json, sys

release = json.load(sys.stdin)
package_asset = sys.argv[1]
asset_names = {
    asset.get("name")
    for asset in release.get("assets", [])
    if isinstance(asset, dict)
}
if package_asset not in asset_names:
    sys.exit(f"GitHub Release is missing required asset: {package_asset}")
' "$package_asset" <<<"$release"

gh release download "$tag" --repo "$REPO" --pattern "$package_asset" --dir "$asset_dir" --clobber
actual_md5="$(md5sum "$asset_dir/$package_asset" | awk '{print $1}')"
if [[ "$actual_md5" != "$package_md5" ]]; then
  echo "::error::published $package_asset md5 ($actual_md5) does not match packageMD5 ($package_md5)" >&2
  exit 1
fi

echo "Verified published GitHub Release $tag with ci-runner-farm.plg and $package_asset"
