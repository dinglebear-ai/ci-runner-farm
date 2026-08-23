#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: build-native-plugin-payload.sh --output-dir DIR [--platform linux-x86_64|linux-aarch64]..." >&2
  exit 2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir=""
platforms=()
while (($#)); do
  case "$1" in
    --output-dir)
      (($# >= 2)) || usage
      output_dir="$2"
      shift 2
      ;;
    --platform)
      (($# >= 2)) || usage
      platforms+=("$2")
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -n "$output_dir" ]] || usage
((${#platforms[@]} > 0)) || platforms=(linux-x86_64 linux-aarch64)
((${#platforms[@]} <= 2)) || { echo "at most two platforms may be requested" >&2; exit 2; }

for command in cargo go git python3 readelf sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "missing required command: $command" >&2; exit 1; }
done
[[ "$(uname -s)" == Linux ]] || { echo "native plugin payloads can only be built on Linux" >&2; exit 1; }

declare -A seen=()
for platform in "${platforms[@]}"; do
  case "$platform" in
    linux-x86_64|linux-aarch64) ;;
    *) echo "unsupported native plugin platform: $platform" >&2; exit 2 ;;
  esac
  [[ -z "${seen[$platform]:-}" ]] || { echo "duplicate platform: $platform" >&2; exit 2; }
  seen[$platform]=1
done

output_dir="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$output_dir")"
case "$output_dir" in /|"$root") echo "refusing unsafe output directory: $output_dir" >&2; exit 2 ;; esac
[[ ! -L "$output_dir" ]] || { echo "output directory may not be a symbolic link: $output_dir" >&2; exit 2; }
if [[ -e "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "output directory must be absent or empty: $output_dir" >&2
  exit 1
fi

version="$(tr -d '[:space:]' < "$root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "invalid VERSION: $version" >&2; exit 1; }
git_sha="$(git -C "$root" rev-parse --verify HEAD)"
source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}"
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || { echo "SOURCE_DATE_EPOCH must be a non-negative integer" >&2; exit 2; }

parent="$(dirname "$output_dir")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.crf-native-payload.XXXXXX")"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT
target_dir="${CRF_NATIVE_PAYLOAD_TARGET_DIR:-$stage/.cargo-target}"
mkdir -p "$target_dir"

for platform in "${platforms[@]}"; do
  case "$platform" in
    linux-x86_64) rust_target=x86_64-unknown-linux-gnu; adapter_target=x86_64-unknown-linux-musl; goarch=amd64 ;;
    linux-aarch64) rust_target=aarch64-unknown-linux-gnu; adapter_target=aarch64-unknown-linux-musl; goarch=arm64 ;;
  esac

  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -Fxq "$rust_target"; then
    echo "missing Rust target $rust_target (install it with: rustup target add $rust_target)" >&2
    exit 1
  fi
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -Fxq "$adapter_target"; then
    echo "missing static adapter Rust target $adapter_target (install it with: rustup target add $adapter_target)" >&2
    exit 1
  fi
  if [[ "$rust_target" == aarch64-unknown-linux-gnu ]] && [[ "$(rustc -vV | sed -n 's/^host: //p')" != "$rust_target" ]]; then
    linker="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER:-aarch64-linux-gnu-gcc}"
    command -v "$linker" >/dev/null 2>&1 || {
      echo "missing aarch64 Rust linker: $linker (set CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER or install aarch64-linux-gnu-gcc)" >&2
      exit 1
    }
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$linker"
    musl_linker="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER:-aarch64-linux-musl-gcc}"
    command -v "$musl_linker" >/dev/null 2>&1 || {
      echo "missing aarch64 musl linker: $musl_linker (set CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER or install aarch64-linux-musl-gcc)" >&2
      exit 1
    }
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$musl_linker"
  fi

  destination="$stage/priv/bin/$platform"
  install -d -m 0755 "$destination"
  SOURCE_DATE_EPOCH="$source_date_epoch" CARGO_TARGET_DIR="$target_dir" \
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-Wl,--build-id=none" \
    cargo build --manifest-path "$root/Cargo.toml" --locked --release -p crf-node --target "$rust_target"
  SOURCE_DATE_EPOCH="$source_date_epoch" CARGO_TARGET_DIR="$target_dir" \
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-Wl,--build-id=none" \
    cargo build --manifest-path "$root/Cargo.toml" --locked --release -p crf-container-adapter --target "$adapter_target"
  install -m 0755 "$target_dir/$rust_target/release/crf-node" "$destination/crf-node"
  install -m 0755 "$target_dir/$adapter_target/release/crf-container-adapter" "$destination/crf-container-adapter"
  ! readelf -l "$destination/crf-container-adapter" | grep -q 'INTERP' || {
    echo "adapter is dynamically linked: $destination/crf-container-adapter" >&2
    exit 1
  }
  ! readelf -d "$destination/crf-container-adapter" 2>/dev/null | grep -q '(NEEDED)' || {
    echo "adapter has dynamic dependencies: $destination/crf-container-adapter" >&2
    exit 1
  }

  SOURCE_DATE_EPOCH="$source_date_epoch" CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
    go -C "$root/tools/crf-scaleset" build -mod=vendor -trimpath -buildvcs=false \
      -ldflags=-buildid= -o "$destination/crf-scaleset" ./cmd/crf-scaleset
done

python3 - "$stage" "$version" "$git_sha" "$source_date_epoch" "${platforms[@]}" <<'PY'
import hashlib, json, pathlib, struct, sys

stage = pathlib.Path(sys.argv[1])
version, git_sha, epoch = sys.argv[2:5]
platforms = sys.argv[5:]
machines = {"linux-x86_64": 62, "linux-aarch64": 183}
files = []
for platform in platforms:
    for name in ("crf-container-adapter", "crf-node", "crf-scaleset"):
        path = stage / "priv" / "bin" / platform / name
        data = path.read_bytes()
        if len(data) < 20 or data[:4] != b"\x7fELF":
            raise SystemExit(f"not an ELF executable: {path}")
        endian = "<" if data[5] == 1 else ">" if data[5] == 2 else None
        if endian is None or struct.unpack(endian + "H", data[18:20])[0] != machines[platform]:
            raise SystemExit(f"ELF architecture does not match {platform}: {path}")
        relative = path.relative_to(stage).as_posix()
        files.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})

files.sort(key=lambda item: item["path"])
(stage / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {item['path']}\n" for item in files))
provenance = {
    "schema_version": 1,
    "source": {"git_sha": git_sha, "source_date_epoch": int(epoch), "version": version},
    "platforms": platforms,
    "files": files,
}
(stage / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
PY

if [[ -z "${CRF_NATIVE_PAYLOAD_TARGET_DIR:-}" ]]; then
  rm -rf -- "$target_dir"
fi
if [[ -d "$output_dir" ]]; then
  rmdir "$output_dir"
fi
mv "$stage" "$output_dir"
trap - EXIT
printf '%s\n' "$output_dir"
