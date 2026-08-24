#!/usr/bin/env bash
set -euo pipefail

os_release="${CRF_OS_RELEASE_FILE:-/etc/os-release}"
[[ -r "$os_release" ]] || exit 2

os_id="$(sed -n 's/^ID=//p' "$os_release" | head -1 | tr -d '"')"
version_id="$(sed -n 's/^VERSION_ID=//p' "$os_release" | head -1 | tr -d '"')"
[[ "$os_id" =~ ^[a-z0-9._-]+$ && "$version_id" =~ ^[0-9]+\.[0-9]+$ ]] || exit 2

case "$os_id:$version_id" in
  ubuntu:24.04) expected_image_os=ubuntu24 ;;
  ubuntu:26.04) expected_image_os=ubuntu26 ;;
  *) exit 3 ;;
esac
[[ "${ImageOS:-}" == "$expected_image_os" ]] || exit 3

glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk 'NR == 1 {print $2}')"
[[ "$glibc" =~ ^[0-9]+\.[0-9]+$ ]] || exit 4
major="${glibc%%.*}"; minor="${glibc#*.}"
(( major > 2 || (major == 2 && minor >= 34) )) || exit 4

case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) exit 5 ;;
esac

printf '{"schema_version":1,"compatible":true,"os":{"id":"%s","version_id":"%s"},"image_os":"%s","glibc":"%s","arch":"%s","capabilities":["github-actions","container","otp-28-compatible"]}\n' \
  "$os_id" "$version_id" "$expected_image_os" "$glibc" "$arch"
