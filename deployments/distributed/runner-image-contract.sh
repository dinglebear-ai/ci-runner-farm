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

php_version="$(php -r 'printf("%d.%d", PHP_MAJOR_VERSION, PHP_MINOR_VERSION);' 2>/dev/null)" || exit 6
[[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || exit 6
php_major="${php_version%%.*}"
(( php_major >= 8 )) || exit 6

# Floor at 3.11, not mere presence: tests/nashost-kache-profile.sh imports
# tomllib, which only entered the stdlib in 3.11 and has no fallback here. A
# bare presence check passes on 3.10 and then fails inside the job instead.
python_version="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || exit 7
[[ "$python_version" =~ ^[0-9]+\.[0-9]+$ ]] || exit 7
python_major="${python_version%%.*}"; python_minor="${python_version#*.}"
(( python_major > 3 || (python_major == 3 && python_minor >= 11) )) || exit 7

# Execute it rather than command -v: a name that resolves but cannot run
# (missing shared library, truncated layer) must fail the contract too.
ssh -V >/dev/null 2>&1 || exit 8

# Archive and transfer tooling the hosted-runner images provide and that stock
# actions assume: actions/cache shells out to zstd, and @actions/tool-cache
# extractZip shells out to unzip, so a runner without them fails inside the job
# with an opaque error rather than at admission. Executed, not command -v'd.
unzip -v >/dev/null 2>&1 || exit 9
zip -v   >/dev/null 2>&1 || exit 9
zstd --version >/dev/null 2>&1 || exit 9
wget --version >/dev/null 2>&1 || exit 9
rsync --version >/dev/null 2>&1 || exit 9
file --version >/dev/null 2>&1 || exit 9
# ripgrep is a hard dependency of this repo's own regression suite: several
# tests (worktree-toolchain.sh, flash-write-paths.sh, security-review-contracts.sh)
# call rg unguarded, so an image without it fails lint with "rg: command not found".
rg --version >/dev/null 2>&1 || exit 9

printf '{"schema_version":1,"compatible":true,"os":{"id":"%s","version_id":"%s"},"image_os":"%s","glibc":"%s","arch":"%s","runtimes":{"php":"%s","python":"%s"},"capabilities":["github-actions","container","otp-28-compatible","php-cli","python3","ssh-client","archive-tools"]}\n' \
  "$os_id" "$version_id" "$expected_image_os" "$glibc" "$arch" "$php_version" "$python_version"
