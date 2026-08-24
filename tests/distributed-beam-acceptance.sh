#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/distributed-farm-acceptance.yaml"
CONFIG="$ROOT/docs/distributed-runner-farm/controller-config.example.json"
PROBE="$ROOT/scripts/distributed-beam-memory-check.sh"

grep -Fq -- '- beam-runtime' "$WORKFLOW"
grep -Fq 'default: ci-pool-acceptance-beam' "$WORKFLOW"
grep -Fq 'scripts/distributed-beam-memory-check.sh snapshot' "$WORKFLOW"
grep -Fq 'scripts/distributed-beam-memory-check.sh assert' "$WORKFLOW"
grep -Fq 'repository: dinglebear-ai/phoenix' "$WORKFLOW"
grep -Fq 'mix test --cover' "$WORKFLOW"

jq -e '
  .demand.pools[] |
  select(.id == "beam") |
  .resources.memory_bytes >= 10737418240 and
  .required_capabilities == ["github-actions", "otp-28-compatible"]
' "$CONFIG" >/dev/null

test -x "$PROBE"
bash -n "$PROBE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cgroup"
printf '10737418240\n' >"$tmp/cgroup/memory.max"
printf '0\n' >"$tmp/cgroup/memory.swap.max"
printf 'low 0\nhigh 0\nmax 1\noom 0\noom_kill 0\n' >"$tmp/cgroup/memory.events"

CRF_CGROUP_DIR="$tmp/cgroup" "$PROBE" snapshot "$tmp/baseline"
CRF_CGROUP_DIR="$tmp/cgroup" "$PROBE" assert "$tmp/baseline"

printf '8589934592\n' >"$tmp/cgroup/memory.max"
if CRF_CGROUP_DIR="$tmp/cgroup" "$PROBE" snapshot "$tmp/undersized" >/dev/null 2>&1; then
  echo 'undersized BEAM cgroup was accepted' >&2
  exit 1
fi
printf '10737418240\n' >"$tmp/cgroup/memory.max"

printf 'low 0\nhigh 0\nmax 2\noom 1\noom_kill 1\n' >"$tmp/cgroup/memory.events"
if CRF_CGROUP_DIR="$tmp/cgroup" "$PROBE" assert "$tmp/baseline" >/dev/null 2>&1; then
  echo 'OOM counter growth was accepted' >&2
  exit 1
fi

printf 'distributed BEAM acceptance contract passed\n'
