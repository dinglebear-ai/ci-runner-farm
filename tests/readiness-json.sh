#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
STATUS=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-status.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
snippet="$tmp/readiness-functions.sh"
for spec in "$STATUS:status_state_file_valid" "$ENGINE:cmd_readiness_json"; do
  file="${spec%%:*}"; fn="${spec#*:}"
  sed -n "/^${fn}()/,/^}/p" "$file" >>"$snippet"
done
# shellcheck disable=SC1090
. "$snippet"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
migration_load(){ return 0; }
status_backend_refresh(){
  STATUS_BACKEND_JSON='{"active":"classic"}'
  STATUS_COMPATIBILITY_JSON='{"valid":true}'
  STATUS_OPERATION_JSON='null'
}
fleet_inventory_refresh(){ fail 'readiness refreshed Docker inventory'; }

INVENTORY_FILE="$tmp/fleet-inventory.tsv"
printf 'runner-a|running\nrunner-b|running\n' >"$INVENTORY_FILE"
chmod 0600 "$INVENTORY_FILE"
out="$(cmd_readiness_json)"
printf '%s' "$out" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["count"]??-1)===2?0:1);'

chmod 0644 "$INVENTORY_FILE"
out="$(cmd_readiness_json)"
printf '%s' "$out" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&array_key_exists("count",$j)&&$j["count"]===null?0:1);'

rm -f "$INVENTORY_FILE"
printf 'runner-c|running\n' >"$tmp/target.tsv"
chmod 0600 "$tmp/target.tsv"
ln -s "$tmp/target.tsv" "$INVENTORY_FILE"
out="$(cmd_readiness_json)"
printf '%s' "$out" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&$j["count"]===null?0:1);'

echo 'readiness-json: OK'
