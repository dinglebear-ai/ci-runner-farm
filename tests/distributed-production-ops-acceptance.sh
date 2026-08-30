#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/distributed-farm-acceptance.yaml"

production_ops="$({
  sed -n '/^  production-ops:/,/^  distributed-linux:/p' "$WORKFLOW"
})"

grep -Fq 'test -r /.dockerenv' <<<"$production_ops"
grep -Fq 'test ! -e /var/run/docker.sock' <<<"$production_ops"
grep -Fq '/sys/fs/cgroup/cgroup.controllers' <<<"$production_ops"

if grep -Eq 'docker (info|version)|/var/run/docker\.sock[^'"'"'!]' <<<"$production_ops"; then
  echo 'production ops acceptance requires access to the host Docker daemon' >&2
  exit 1
fi

printf 'distributed production ops acceptance contract passed\n'
