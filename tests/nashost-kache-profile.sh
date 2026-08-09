#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=deployments/nashost/runner.Dockerfile
OVERLAY=deployments/nashost/kache-overlay.Dockerfile
SUPERVISOR=deployments/nashost/kache-supervise.sh

bash -n "$SUPERVISOR"
for dockerfile in "$FULL" "$OVERLAY"; do
  grep -Fq 'php-cli ripgrep file' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_TAG=v0.13.0' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_ARCHIVE_SHA256=30aeded4dc6e620c400aa3aaf7ab163dc95c703a0f3ddb4d0ba56c51f23f0bd0' "$dockerfile"
  grep -Fq 'ARG KACHE_FLEET_BINARY_SHA256=5490686480adca08df1849d6dfba449e7e898e187135a452cfa6c6c40f9ff972' "$dockerfile"
  grep -Fq '/opt/hostedtoolcache/kache/0.13.0/x64/kache' "$dockerfile"
  grep -Fq 'ln -sfn /opt/hostedtoolcache/kache/0.13.0/x64/kache /usr/local/bin/kache' "$dockerfile"
  grep -Fq 'ENV KACHE_VERIFY_RESTORES=sampled' "$dockerfile"
  grep -Fq '"prefetch_enabled = false"' "$dockerfile"
  grep -Fq '"modified_input_guard = true"' "$dockerfile"
  grep -Eq 'local_max_size.*80GiB' "$dockerfile"
  grep -Fq '"[cc]"' "$dockerfile"
  grep -Fq '"extra_allowlist_flags = [\"-fmerge-all-constants\"]"' "$dockerfile"
  ! grep -Fq 'prefetch_max_bytes' "$dockerfile"
  # Public profiles must fail closed until the operator injects the real
  # private endpoint. Documentation-only addresses must never become a
  # plausible-looking, silently broken production configuration.
  grep -Eq '^ARG KACHE_REMOTE_ENDPOINT$' "$dockerfile"
  # shellcheck disable=SC2016 -- this is a literal Dockerfile contract.
  grep -Fq 'endpoint = \"${endpoint}\"' "$dockerfile"
  grep -Fq '*192.0.2.*' "$dockerfile"
  grep -Fq 'KACHE_REMOTE_ENDPOINT contains unsafe characters' "$dockerfile"
  grep -Fq 'KACHE_REMOTE_ENDPOINT must contain a valid authority' "$dockerfile"
  ! grep -Eq 'endpoint = .*192\.0\.2\.|endpoint = .*198\.51\.100\.|endpoint = .*203\.0\.113\.' "$dockerfile"

  # Parse the exact printf arguments from the Dockerfile, substitute a safe
  # endpoint, and prove the emitted document is valid TOML with one endpoint.
  python3 - "$dockerfile" <<'PY'
import ast
import pathlib
import re
import sys
import tomllib

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next(i for i, line in enumerate(lines) if line.strip() == '"[cache]" \\')
end = next(i for i in range(start, len(lines)) if '> /home/runner/.config/kache/config.toml' in lines[i])
rendered = []
for line in lines[start:end]:
    match = re.fullmatch(r'\s+(".*") \\', line)
    if match:
        rendered.append(ast.literal_eval(match.group(1)).replace('${endpoint}', 'https://cache.internal:9000'))
document = '\n'.join(rendered) + '\n'
parsed = tomllib.loads(document)
assert parsed['cache']['remote']['endpoint'] == 'https://cache.internal:9000'
assert document.count('endpoint = ') == 1
PY
done

grep -Fq 'FROM ci-runner-farm-runner:s3-v8-kache-cc-20260804' "$OVERLAY"
! grep -Fq 'remote key cache populated' "$SUPERVISOR"
! grep -Fq 'daemon status' "$SUPERVISOR"
grep -Fq 'KACHE_VERIFY_RESTORES=sampled' "$SUPERVISOR"
grep -Fq 'daemon ready; speculative prefetch disabled, exact remote cache active' "$SUPERVISOR"
grep -Fq 'pgrep -u' "$SUPERVISOR"

echo 'nashost-kache-profile: OK'
