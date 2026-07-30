#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
engine="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
pools="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh"

. "$pools"
RUNNER_COUNT=4 RUNNER_LABELS=self-hosted RUNNER_CPUS=1 RUNNER_MEMORY=1g AUTOSCALE=false
POOL_BACKEND=classic
cfg=''
for id in a b c d e f g h; do
  cfg="${cfg}${cfg:+;}v2|$id|route-$id|lang-$id|8|1|8|1|1|1g"
done
for _ in $(seq 1 5); do
  pool_config_validate pools "$cfg" org acme >/dev/null
done
[ "$(printf '%s\n' "$POOL_RECORDS" | tr ';' '\n' | wc -l)" -eq 8 ]

status_body="$(sed -n '/^cmd_status_json()/,/^}/p' "$engine")"
[ "$(printf '%s' "$status_body" | grep -c 'fleet_inventory_refresh')" -eq 1 ]
! printf '%s' "$status_body" | grep -Eq '\bdocker (exec|logs)\b'
usage_body="$(sed -n '/^cmd_usage_refresh()/,/^}/p' "$engine")"
! printf '%s' "$usage_body" | grep -Eq '\bdocker (exec|logs)\b'
grep -Fq 'docker stats --no-stream' <<<"$usage_body"
grep -Fq 'github_phase_refresh' <<<"$usage_body"

bytes="$(wc -c < tests/fixtures/pools-v2.tsv)"
[ "$bytes" -lt 262144 ]
echo 'performance-contracts: OK'
