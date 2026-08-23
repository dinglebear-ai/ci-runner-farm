#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$root/scripts/build-native-plugin-payload.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  if "$@" >"$tmp/stdout" 2>"$tmp/stderr"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

bash -n "$builder"
fail "$builder" --output-dir "$tmp/unsupported" --platform linux-riscv64
grep -q "unsupported native plugin platform" "$tmp/stderr"

mkdir "$tmp/nonempty"
printf 'keep\n' > "$tmp/nonempty/user-data"
fail "$builder" --output-dir "$tmp/nonempty" --platform linux-x86_64
grep -q "must be absent or empty" "$tmp/stderr"
test "$(cat "$tmp/nonempty/user-data")" = keep

mkdir "$tmp/symlink-target"
ln -s "$tmp/symlink-target" "$tmp/symlink-output"
fail "$builder" --output-dir "$tmp/symlink-output" --platform linux-x86_64
grep -q "symbolic link" "$tmp/stderr"

SOURCE_DATE_EPOCH=1700000000 "$builder" --output-dir "$tmp/payload" --platform linux-x86_64
test -x "$tmp/payload/priv/bin/linux-x86_64/crf-node"
test -x "$tmp/payload/priv/bin/linux-x86_64/crf-scaleset"
(cd "$tmp/payload" && sha256sum -c SHA256SUMS)
python3 - "$tmp/payload/provenance.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["schema_version"] == 1
assert data["source"]["source_date_epoch"] == 1700000000
assert data["platforms"] == ["linux-x86_64"]
assert [item["path"] for item in data["files"]] == [
    "priv/bin/linux-x86_64/crf-node",
    "priv/bin/linux-x86_64/crf-scaleset",
]
assert all(len(item["sha256"]) == 64 and item["size"] > 0 for item in data["files"])
PY

SOURCE_DATE_EPOCH=1700000000 "$builder" --output-dir "$tmp/payload-repeat" --platform linux-x86_64
cmp "$tmp/payload/SHA256SUMS" "$tmp/payload-repeat/SHA256SUMS"
cmp "$tmp/payload/provenance.json" "$tmp/payload-repeat/provenance.json"
cmp "$tmp/payload/priv/bin/linux-x86_64/crf-node" \
  "$tmp/payload-repeat/priv/bin/linux-x86_64/crf-node"
cmp "$tmp/payload/priv/bin/linux-x86_64/crf-scaleset" \
  "$tmp/payload-repeat/priv/bin/linux-x86_64/crf-scaleset"

fail "$builder" --output-dir "$tmp/duplicate" --platform linux-x86_64 --platform linux-x86_64
grep -q "duplicate platform" "$tmp/stderr"

echo "native plugin payload tests passed"
