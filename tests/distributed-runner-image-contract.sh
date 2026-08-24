#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="$root/deployments/distributed/runner-image-contract.sh"
dockerfile="$root/deployments/distributed/runner.Dockerfile"
example="$root/packaging/distributed/examples/node-env.example"
workflow="$root/.github/workflows/lint.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
chmod +x "$tmp/bin/getconf" "$tmp/bin/uname" "$tmp/bin/php"

result="$(PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe")"
jq -e '
  .schema_version == 1 and
  .compatible == true and
  .os.id == "ubuntu" and .os.version_id == "24.04" and
  .image_os == "ubuntu24" and .glibc == "2.39" and .arch == "x64" and
  .runtimes.php == "8.3" and
  .capabilities == ["github-actions", "container", "otp-28-compatible", "php-cli"]
' <<<"$result" >/dev/null

if PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu26 "$probe" >/dev/null 2>&1; then
  echo 'probe accepted a false ImageOS declaration' >&2
  exit 1
fi
sed -i 's/glibc 2.39/glibc 2.31/' "$tmp/bin/getconf"
if PATH="$tmp/bin:$PATH" CRF_OS_RELEASE_FILE="$tmp/os-release" ImageOS=ubuntu24 "$probe" >/dev/null 2>&1; then
  echo 'probe accepted glibc older than 2.34' >&2
  exit 1
fi
sed -i 's/glibc 2.31/glibc 2.39/' "$tmp/bin/getconf"
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

grep -Fq 'FROM ubuntu:24.04@sha256:' "$dockerfile"
grep -Eq '^[[:space:]]*ImageOS=ubuntu24([[:space:]\\]|$)' "$dockerfile"
grep -Fq 'HEALTHCHECK' "$dockerfile"
grep -Fq 'build-essential' "$dockerfile"
grep -Fq 'inotify-tools' "$dockerfile"
grep -Fq 'xz-utils' "$dockerfile"
grep -Fq 'php-cli' "$dockerfile"
if grep -Eq '^USER[[:space:]]+runner' "$dockerfile"; then
  echo 'runner image must start as root so the injected entrypoint can prepare /_work' >&2
  exit 1
fi
grep -Fq 'CRF_RUNNER_IMAGE=ghcr.io/dinglebear-ai/ci-runner-farm-distributed@sha256:<published-image-digest>' "$example"
grep -Fq -- '-f deployments/distributed/runner.Dockerfile' "$workflow"
grep -Fq -- '--entrypoint /usr/local/bin/crf-runner-image-contract' "$workflow"
grep -Fq -- '--platform linux/arm64 --load' "$workflow"
grep -Fq '.arch == "arm64"' "$workflow"

echo 'distributed-runner-image-contract: PASS'
