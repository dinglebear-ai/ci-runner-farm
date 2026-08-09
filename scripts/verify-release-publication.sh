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

# Parse the complete published XML document without resolving any external
# subset or entity. Expat supplies semantic entity values and enforces XML 1.0
# character/whitespace rules. A fail-closed whole-document declaration scan is
# also required because XML processors retain only the first duplicate entity.
if ! release_contract="$(python3 - "$released_plg" "$version" "$tag" "$REPO" <<'PY'
import pathlib
import re
import sys
import xml.parsers.expat as expat

path, version, tag, repo = sys.argv[1:]
raw = pathlib.Path(path).read_bytes()
targets = ("pluginVersion", "releaseTag", "packageURL", "packageName", "packageMD5")
values = {name: [] for name in targets}
doctype_count = 0

class UnsafeReleaseXML(Exception):
    pass

def start_doctype(name, system_id, public_id, has_internal_subset):
    global doctype_count
    doctype_count += 1
    if name != "PLUGIN" or system_id is not None or public_id is not None:
        raise UnsafeReleaseXML("external or unexpected document type is forbidden")

def entity_decl(name, is_parameter, value, base, system_id, public_id, notation):
    if is_parameter or system_id is not None or public_id is not None or notation is not None:
        raise UnsafeReleaseXML("parameter and external entity declarations are forbidden")
    if name in values:
        values[name].append(value)

def external_entity(*_args):
    raise UnsafeReleaseXML("external entity resolution is forbidden")

parser = expat.ParserCreate()
parser.StartDoctypeDeclHandler = start_doctype
parser.EntityDeclHandler = entity_decl
parser.ExternalEntityRefHandler = external_entity
parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_ALWAYS)
try:
    parser.Parse(raw, True)
except (expat.ExpatError, UnsafeReleaseXML) as error:
    raise SystemExit(f"published ci-runner-farm.plg is unsafe or invalid XML: {error}")
if doctype_count != 1:
    raise SystemExit("published ci-runner-farm.plg must contain one internal PLUGIN document type")

# XML 1.0 S is exactly space, tab, carriage return, and line feed. Count each
# target declaration lexically across the entire document so multiline or
# indented duplicates cannot hide behind Expat's first-declaration semantics.
xml_s = rb"[ \t\r\n]"
for name in targets:
    pattern = rb"<!ENTITY" + xml_s + rb"+" + name.encode() + rb"(?=" + xml_s + rb")"
    declarations = len(re.findall(pattern, raw))
    if declarations != 1 or len(values[name]) != 1:
        raise SystemExit(f"published ci-runner-farm.plg must contain exactly one {name} entity")

plugin_version = values["pluginVersion"][0]
release_tag = values["releaseTag"][0]
package_url = values["packageURL"][0]
package_asset = values["packageName"][0]
package_md5 = values["packageMD5"][0]
if plugin_version != version:
    raise SystemExit(f"published ci-runner-farm.plg pluginVersion ({plugin_version}) does not match manifest version ({version})")
if release_tag != tag:
    raise SystemExit(f"published ci-runner-farm.plg releaseTag ({release_tag}) does not match manifest tag ({tag})")
if re.fullmatch(r"ci-runner-farm-[A-Za-z0-9._-]+\.tgz", package_asset) is None:
    raise SystemExit("published ci-runner-farm.plg has an invalid packageName entity")
if re.fullmatch(r"[0-9a-f]{32}", package_md5) is None:
    raise SystemExit("published ci-runner-farm.plg has an invalid packageMD5 entity")
expected_package_url = f"https://github.com/{repo}/releases/download/{tag}/{package_asset}"
if package_url != expected_package_url:
    raise SystemExit(f"published ci-runner-farm.plg packageURL does not reference {tag} asset {package_asset}")
print(package_asset)
print(package_md5)
PY
)"; then
  echo "::error::published ci-runner-farm.plg release contract validation failed" >&2
  exit 1
fi
mapfile -t release_contract_fields <<<"$release_contract"
[ "${#release_contract_fields[@]}" -eq 2 ] || {
  echo "::error::published ci-runner-farm.plg produced an invalid release contract" >&2
  exit 1
}
package_asset="${release_contract_fields[0]}"
package_md5="${release_contract_fields[1]}"

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
