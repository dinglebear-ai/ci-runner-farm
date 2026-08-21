#!/usr/bin/env bash
# Lock the local-only Unraid distributed-node status contract. This endpoint
# must remain secret-free, cache-resident, and explicit about the controller
# RPC boundary for global inventory.
set -euo pipefail
cd "$(dirname "$0")/.."

. tests/lib/assert.sh

script=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
page=src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
endpoint=src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

bash "$script" distributed-status-json >"$tmp"
php -r '
  $j=json_decode(file_get_contents($argv[1]), true, 16, JSON_THROW_ON_ERROR);
  $required=["schema_version","installed","running","pid","node_id","controller","backend","cpu_millis","memory_bytes","generation","storage_root","filesystem","storage_cache_backed","remote_inventory"];
  foreach ($required as $key) if (!array_key_exists($key, $j)) exit(2);
  if ($j["schema_version"] !== 1 || $j["storage_root"] !== "/mnt/cache/appdata/ci-runner-farm/distributed-node") exit(3);
  if ($j["remote_inventory"] !== "controller_operator_rpc") exit(4);
  if (!is_bool($j["installed"]) || !is_bool($j["running"]) || !is_bool($j["storage_cache_backed"])) exit(5);
' "$tmp" || crf_fail "distributed status JSON contract drifted"

grep -Fq 'local root=/mnt/cache/appdata/ci-runner-farm/distributed-node' "$script" ||
  crf_fail "distributed node storage is no longer fixed to the cache pool"
! grep -Eq 'storage_root[^\n]*/boot|local root=/boot' "$script" ||
  crf_fail "distributed node status points at flash storage"
grep -Fq '"remote_inventory":"controller_operator_rpc"' "$script" ||
  crf_fail "global inventory authority is no longer explicit"
grep -Fq "case 'distributed-status-json':" "$endpoint" ||
  crf_fail "authenticated WebUI endpoint is not wired"
grep -Fq 'Global inventory stays on authenticated controller RPC' "$page" ||
  crf_fail "WebUI obscures the local-versus-global authority boundary"

for secret in ACCESS_TOKEN GITHUB_APP_KEY REGISTRY_TOKEN CRF_CLIENT_KEY; do
  ! grep -Fq "\"$secret\"" "$tmp" || crf_fail "distributed status leaked $secret"
done

echo 'distributed-status: OK'
