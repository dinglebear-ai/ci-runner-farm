#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="$root/deployments/distributed/runner-image-contract.sh"
dockerfile="$root/deployments/distributed/runner.Dockerfile"
example="$root/packaging/distributed/examples/node-env.example"
manifest="$root/docs/distributed-runner-farm/runner-manifest.example.json"
windows_context="$root/packaging/distributed/windows/Prepare-WindowsRunnerContext.ps1"
workflow="$root/.github/workflows/lint.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

replace_text() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
if old not in text:
    raise SystemExit(f"missing replacement text in {path}: {old}")
path.write_text(text.replace(old, new))
PY
}

mkdir -p "$tmp/bin"
cat >"$tmp/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF
cat >"$tmp/bin/getconf" <<'EOF'
#!/usr/bin/env bash
printf 'glibc 2.39\n'
EOF
cat >"$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'x86_64\n'
EOF
cat >"$tmp/bin/php" <<'EOF'
#!/usr/bin/env bash
printf '8.3'
EOF
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '3.12\n'
EOF
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
for tool in unzip zip zstd wget rsync file rg docker dockerd gh node; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$tool"
done
chmod +x "$tmp/bin/getconf" "$tmp/bin/uname" "$tmp/bin/php" "$tmp/bin/python3" "$tmp/bin/ssh" \
  "$tmp/bin/unzip" "$tmp/bin/zip" "$tmp/bin/zstd" "$tmp/bin/wget" "$tmp/bin/rsync" "$tmp/bin/file" "$tmp/bin/rg" "$tmp/bin/docker" "$tmp/bin/dockerd" "$tmp/bin/gh" "$tmp/bin/node"

result="$(PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe")"
jq -e '
  .schema_version == 1 and
  .compatible == true and
  .os.id == "ubuntu" and .os.version_id == "24.04" and
  .image_os == "ubuntu24" and .glibc == "2.39" and .arch == "x64" and
  .runtimes.php == "8.3" and .runtimes.python == "3.12" and
  .capabilities == ["github-actions", "container", "otp-28-compatible", "php-cli", "python3", "ssh-client", "archive-tools", "docker-cli", "github-cli", "node"]
' <<<"$result" >/dev/null

if PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu26 "$probe" >/dev/null 2>&1; then
  echo 'probe accepted a false ImageOS declaration' >&2
  exit 1
fi
replace_text "$tmp/bin/getconf" 'glibc 2.39' 'glibc 2.31'
if PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1; then
  echo 'probe accepted glibc older than 2.34' >&2
  exit 1
fi
replace_text "$tmp/bin/getconf" 'glibc 2.31' 'glibc 2.39'
cat >"$tmp/bin/php" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$tmp/bin/php"
set +e
PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1
missing_php_status=$?
set -e
if (( missing_php_status == 0 )); then
  echo 'probe accepted a missing PHP CLI runtime' >&2
  exit 1
fi
[[ "$missing_php_status" == 6 ]] || {
  echo "probe used unexpected missing-PHP exit code: $missing_php_status" >&2
  exit 1
}
cat >"$tmp/bin/php" <<'EOF'
#!/usr/bin/env bash
printf '7.4'
EOF
chmod +x "$tmp/bin/php"
if PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1; then
  echo 'probe accepted PHP older than 8' >&2
  exit 1
fi
cat >"$tmp/bin/php" <<'EOF'
#!/usr/bin/env bash
printf '8.3'
EOF
chmod +x "$tmp/bin/php"

# Python must be gated on version, not presence: tomllib lands in 3.11.
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$tmp/bin/python3"
set +e
PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1
missing_python_status=$?
set -e
if (( missing_python_status == 0 )); then
  echo 'probe accepted a missing python3 runtime' >&2
  exit 1
fi
[[ "$missing_python_status" == 7 ]] || {
  echo "probe used unexpected missing-python exit code: $missing_python_status" >&2
  exit 1
}
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '3.10\n'
EOF
chmod +x "$tmp/bin/python3"
if PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1; then
  echo 'probe accepted python older than 3.11 (tomllib would be absent)' >&2
  exit 1
fi
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '3.12\n'
EOF
chmod +x "$tmp/bin/python3"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$tmp/bin/ssh"
set +e
PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1
missing_ssh_status=$?
set -e
[[ "$missing_ssh_status" == 8 ]] || {
  echo "probe used unexpected missing-ssh exit code: $missing_ssh_status" >&2
  exit 1
}

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/ssh"

# Every archive/transfer tool is individually required: a runner missing any one
# of them fails inside the job, so the contract must reject the image up front.
for tool in unzip:9 zip:9 zstd:9 wget:9 rsync:9 file:9 rg:9 docker:10 dockerd:10 gh:10 node:10; do
  expected="${tool##*:}"
  tool="${tool%%:*}"
  cat >"$tmp/bin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$tmp/bin/$tool"
  set +e
  PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1
  missing_tool_status=$?
  set -e
  [[ "$missing_tool_status" == "$expected" ]] || {
    echo "probe accepted a missing $tool (exit $missing_tool_status, want $expected)" >&2
    exit 1
  }
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done

grep -Fq 'FROM ubuntu:24.04@sha256:' "$dockerfile"
grep -Eq '^[[:space:]]*ImageOS=ubuntu24([[:space:]\\]|$)' "$dockerfile"
grep -Fq 'HEALTHCHECK' "$dockerfile"
grep -Fq 'build-essential' "$dockerfile"
grep -Fq 'clang' "$dockerfile"
grep -Fq 'lld' "$dockerfile"
grep -Fq 'inotify-tools' "$dockerfile"
grep -Fq 'sudo' "$dockerfile"
grep -Fq 'xz-utils' "$dockerfile"
grep -Fq 'php-cli' "$dockerfile"
grep -Fq 'python3' "$dockerfile"
for pkg in unzip zip zstd wget rsync file cmake pkg-config locales gnupg lsb-release apt-transport-https ripgrep ruby libssl-dev mold containerd.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin gh nodejs npm python3-pip python3-venv gettext-base iptables uidmap; do
  grep -Fq "$pkg" "$dockerfile" || { echo "runner image does not install $pkg" >&2; exit 1; }
done
grep -Fq 'usermod -aG docker runner' "$dockerfile"
grep -Fq 'ARG ACTIONS_RUNNER_VERSION=2.337.0' "$dockerfile"
grep -Fq 'ARG ACTIONS_RUNNER_X64_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613' "$dockerfile"
grep -Fq 'ARG ACTIONS_RUNNER_ARM64_SHA256=9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393' "$dockerfile"
grep -Fq 'ARG DOCKER_APT_KEY_SHA256=1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570' "$dockerfile"
grep -Fq 'ARG GHCLI_APT_KEY_SHA256=6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b' "$dockerfile"
grep -Fq 'echo "$DOCKER_APT_KEY_SHA256  /etc/apt/keyrings/docker.asc" | sha256sum -c -' "$dockerfile"
grep -Fq 'echo "$GHCLI_APT_KEY_SHA256  /etc/apt/keyrings/githubcli.gpg" | sha256sum -c -' "$dockerfile"
grep -Fq "'{\"storage-driver\":\"vfs\"}'" "$dockerfile"
grep -Fq 'openssh-client' "$dockerfile"
grep -Fq '"python3"' "$probe"
grep -Fq '"ssh-client"' "$probe"
if grep -Eq '^USER[[:space:]]+runner' "$dockerfile"; then
  echo 'runner image must start as root so the injected entrypoint can prepare /actions-runner/_work' >&2
  exit 1
fi
jq -e '
  .version == "2.337.0" and
  (.artifacts | length == 4) and
  (.artifacts[] | select(.os == "linux" and .arch == "x86_64") | .sha256 == "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613" and .size_bytes == 226430031) and
  (.artifacts[] | select(.os == "linux" and .arch == "arm64") | .sha256 == "9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393" and .size_bytes == 139124737) and
  (.artifacts[] | select(.os == "windows" and .arch == "x86_64") | .sha256 == "1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc" and .size_bytes == 103528051) and
  (.artifacts[] | select(.os == "windows" and .arch == "arm64") | .sha256 == "7ee1a72a0e0ad384ac7871ffc2356063a116e20d1db3ea41000eb49272cf0030" and .size_bytes == 94728895)
' "$manifest" >/dev/null
grep -Fq 'actions-runner-win-x64-2.337.0.zip' "$windows_context"
grep -Fq "RunnerSha256 = '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc'" "$windows_context"
grep -Fq 'CRF_RUNNER_IMAGE=ghcr.io/dinglebear-ai/ci-runner-farm-distributed@sha256:<published-image-digest>' "$example"
grep -Fq -- '-f deployments/distributed/runner.Dockerfile' "$workflow"
grep -Fq -- '--entrypoint /usr/local/bin/crf-runner-image-contract' "$workflow"
grep -Fq -- '--entrypoint php' "$workflow"
grep -Fq -- '--entrypoint python3' "$workflow"
grep -Fq -- '--platform linux/arm64 --load' "$workflow"
grep -Fq '.arch == "arm64"' "$workflow"

echo 'distributed-runner-image-contract: PASS'
