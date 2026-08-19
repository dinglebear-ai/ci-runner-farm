#!/usr/bin/env bash
set -euo pipefail

archive="${1:-}"
if [[ -z "$archive" || ! -f "$archive" ]]; then
  echo "usage: verify-distributed-bundle.sh <bundle.tar.gz>" >&2
  exit 2
fi

for command in tar sha256sum realpath readlink; do
  command -v "$command" >/dev/null 2>&1 || { echo "missing required command: $command" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$archive" -C "$tmp"
mapfile -t roots < <(find "$tmp" -mindepth 1 -maxdepth 1 -type d -print)
[[ "${#roots[@]}" -eq 1 ]] || { echo "bundle must contain exactly one root directory" >&2; exit 1; }
bundle="${roots[0]}"

(
  cd "$bundle"
  sha256sum -c SHA256SUMS
)

while IFS= read -r -d "" link; do
  target="$(readlink "$link")"
  [[ "$target" != /* ]] || { echo "absolute symlink in bundle: $link" >&2; exit 1; }
  resolved="$(realpath -m "$(dirname "$link")/$target")"
  case "$resolved" in
    "$bundle"|"$bundle"/*) ;;
    *) echo "escaping symlink in bundle: $link -> $target" >&2; exit 1 ;;
  esac
done < <(find "$bundle" -type l -print0)

test -x "$bundle/bin/crf-node"
test -x "$bundle/bin/crf-scheduler"
test -x "$bundle/bin/crf-scaleset"
test -x "$bundle/controller/bin/crf_controller"
test -x "$bundle/install.sh"
bash -n "$bundle/install.sh"

"$bundle/bin/crf-node" --version
"$bundle/bin/crf-scheduler" --version
"$bundle/bin/crf-scaleset" version >/dev/null
"$bundle/controller/bin/crf_controller" eval "Application.load(:crf_controller); IO.puts(Application.spec(:crf_controller, :vsn))" >/dev/null

rootfs="$tmp/rootfs"
DESTDIR="$rootfs" "$bundle/install.sh" >/dev/null
DESTDIR="$rootfs" "$bundle/install.sh" >/dev/null

test -L "$rootfs/opt/ci-runner-farm/current"
case "$(readlink "$rootfs/opt/ci-runner-farm/current")" in
  releases/*) ;;
  *) echo "installed current symlink is not release-relative" >&2; exit 1 ;;
esac
test -x "$rootfs/opt/ci-runner-farm/current/bin/crf-node"
test -x "$rootfs/opt/ci-runner-farm/current/bin/crf-scheduler"
test -x "$rootfs/opt/ci-runner-farm/current/bin/crf-scaleset"
test -x "$rootfs/opt/ci-runner-farm/current/controller/bin/crf_controller"
test -f "$rootfs/etc/systemd/system/ci-runner-farm-controller.service"
test -f "$rootfs/etc/systemd/system/ci-runner-farm-node.service"
test -f "$rootfs/usr/share/doc/ci-runner-farm-distributed/examples/controller-config.example.json"
test -f "$rootfs/usr/share/doc/ci-runner-farm-distributed/examples/node-env.example"
test -f "$rootfs/usr/share/doc/ci-runner-farm-distributed/examples/runner-manifest.example.json"
test ! -e "$rootfs/etc/ci-runner-farm/controller.json"
test ! -e "$rootfs/etc/ci-runner-farm/node.env"

grep -q "^KillMode=process$" "$rootfs/etc/systemd/system/ci-runner-farm-node.service"
grep -q "CRF_CONTROLLER_CONFIG=/etc/ci-runner-farm/controller.json" "$rootfs/etc/systemd/system/ci-runner-farm-controller.service"

echo "distributed bundle verification passed: $(basename "$archive")"
