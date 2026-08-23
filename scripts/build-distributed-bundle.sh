#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "distributed bundle builder currently supports Linux hosts only" >&2
  exit 1
fi

for command in cargo go mix tar sha256sum git; do
  command -v "$command" >/dev/null 2>&1 || { echo "missing required command: $command" >&2; exit 1; }
done

version="$(tr -d "[:space:]" < "$root/VERSION")"
git_sha="$(git -C "$root" rev-parse HEAD)"
source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}"
git_dirty=false
git_status="$(git -C "$root" status --porcelain --untracked-files=all)"
if [[ -n "$git_status" ]]; then
  git_dirty=true
  if [[ "${CRF_ALLOW_DIRTY_BUNDLE:-0}" != "1" ]]; then
    echo "refusing to build a release bundle from dirty or untracked sources; commit first or set CRF_ALLOW_DIRTY_BUNDLE=1 for local validation" >&2
    exit 1
  fi
fi

tracked_inputs=(
  VERSION
  Cargo.toml
  Cargo.lock
  controller/mix.exs
  packaging/distributed/README.md
  packaging/distributed/install.sh
  packaging/distributed/admin/crf-peer-admin
  packaging/distributed/admin/crf-cert-fingerprint
  packaging/distributed/admin/crf-operator-status
  packaging/distributed/examples/node-env.example
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh
  packaging/distributed/systemd/ci-runner-farm-controller.service
  packaging/distributed/systemd/ci-runner-farm-node.service
  docs/distributed-runner-farm/controller-config.example.json
  docs/distributed-runner-farm/runner-manifest.example.json
)
for relative in "${tracked_inputs[@]}"; do
  if ! git -C "$root" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
    echo "refusing to build: required bundle input is not tracked by git: $relative" >&2
    exit 1
  fi
done

os_id=linux
os_version=unknown
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-linux}"
  os_version="${VERSION_ID:-unknown}"
fi
os_id="$(printf "%s" "$os_id" | tr -cs "A-Za-z0-9._-" "-")"
os_version="$(printf "%s" "$os_version" | tr -cs "A-Za-z0-9._-" "-")"

case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported bundle architecture: $(uname -m)" >&2; exit 1 ;;
esac

platform="linux-${os_id}-${os_version}-${arch}"
name="ci-runner-farm-distributed-${version}-${platform}"
output_root="${CRF_BUNDLE_OUTPUT_DIR:-$root/build/distributed}"
stage="$output_root/$name"
archive="$output_root/$name.tar.gz"

rm -rf "$stage" "$archive"
install -d -m 0755 "$stage/bin" "$stage/libexec" "$stage/systemd" "$stage/examples"

cargo build --manifest-path "$root/Cargo.toml" --locked --release -p crf-container-adapter -p crf-node -p crf-scheduler
install -m 0755 "$root/target/release/crf-node" "$stage/bin/crf-node"
install -m 0755 "$root/target/release/crf-scheduler" "$stage/bin/crf-scheduler"
install -m 0755 "$root/packaging/distributed/admin/crf-peer-admin" "$stage/bin/crf-peer-admin"
install -m 0755 "$root/packaging/distributed/admin/crf-cert-fingerprint" "$stage/bin/crf-cert-fingerprint"
install -m 0755 "$root/packaging/distributed/admin/crf-operator-status" "$stage/bin/crf-operator-status"
install -m 0755 "$root/target/release/crf-container-adapter" "$stage/bin/crf-container-adapter"
install -m 0755 "$root/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh" "$stage/libexec/runner-entrypoint.sh"

go -C "$root/tools/crf-scaleset" build -trimpath -o "$stage/bin/crf-scaleset" ./cmd/crf-scaleset

(
  cd "$root/controller"
  MIX_ENV=prod mix release crf_controller --overwrite --path "$stage/controller" --version "$version"
)

install -m 0755 "$root/packaging/distributed/install.sh" "$stage/install.sh"
install -m 0644 "$root/packaging/distributed/README.md" "$stage/README.md"
install -m 0644 "$root/packaging/distributed/systemd/ci-runner-farm-controller.service" "$stage/systemd/ci-runner-farm-controller.service"
install -m 0644 "$root/packaging/distributed/systemd/ci-runner-farm-node.service" "$stage/systemd/ci-runner-farm-node.service"
install -m 0644 "$root/docs/distributed-runner-farm/controller-config.example.json" "$stage/examples/controller-config.example.json"
install -m 0644 "$root/packaging/distributed/examples/node-env.example" "$stage/examples/node-env.example"
install -m 0644 "$root/docs/distributed-runner-farm/runner-manifest.example.json" "$stage/examples/runner-manifest.example.json"

{
  printf "VERSION=%q\n" "$version"
  printf "PLATFORM=%q\n" "$platform"
  printf "GIT_SHA=%q\n" "$git_sha"
  printf "GIT_DIRTY=%q\n" "$git_dirty"
  printf "SOURCE_DATE_EPOCH=%q\n" "$source_date_epoch"
  printf "RUSTC=%q\n" "$(rustc --version)"
  printf "GO=%q\n" "$(go version)"
  printf "ELIXIR=%q\n" "$(elixir --version | tail -n 1)"
} > "$stage/BUILD-INFO"

(
  cd "$stage"
  find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
)

tar --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner -C "$output_root" -czf "$archive" "$name"

printf "%s\n" "$archive"
