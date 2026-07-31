#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

root="$(mktemp -d)"
socket_pid=
trap '[ -z "$socket_pid" ] || kill "$socket_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
RUNDIR="$root/run"
CFGDIR="$root/cfg"
CACHE_ROOT="$root/cache"
SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT"
printf 'token\n' >"$CFGDIR/token"
chmod 0600 "$CFGDIR/token"

RUNNER_MODE=pools
RUNNER_POOLS='v2|python|python|node|1|0|auto|1|1|2g'
POOL_BACKEND=scaleset
GH_SCOPE=org
GH_OWNER=dinglebear-ai
AUTH_MODE=pat
RUNNER_GROUP='CI Runner Farm Trusted'
GITHUB_APP_ID=
GITHUB_APP_INSTALLATION_ID=
TOKEN_FILE="$CFGDIR/token"
GITHUB_APP_KEY_FILE="$CFGDIR/app.pem"
SCALESET_COMPAT="$CFGDIR/scaleset-compatibility.json"
SCALESET_RUNTIME_CONFIG="$RUNDIR/scalesets/runtime-config.json"
SCALESET_OWNERSHIP="$CFGDIR/scale-set-ownership.json"
cat >"$SCALESET_COMPAT" <<'EOF'
{"runner_group_id":7,"quarantine_runner_group_id":8,"runner_group_policy":"selected_repositories","compatibility_record_id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
EOF
chmod 0600 "$SCALESET_COMPAT"

. "$SCRIPT_DIR/runner-pools.sh"
. "$SCRIPT_DIR/runner-scalesets.sh"
pool_snapshot_load
config_revision(){ printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
scaleset_bound_identity(){
  printf '%064d|%064d|%064d|%064d|dinglebear-ai|installation-test|%064d\n' 1 2 3 4 5
}
scaleset_installation_id(){ printf 'installation-test\n'; }
sha256sum(){
  if [ "${1:-}" = /etc/machine-id ]; then printf '%064d  /etc/machine-id\n' 5
  else command sha256sum "$@"; fi
}
scaleset_runtime_config_write

php -r '
  $j=json_decode(file_get_contents($argv[1]),true);
  if(!is_array($j)||($j["schema_version"]??0)!==1||
    ($j["config_revision"]??"")!==str_repeat("a",64)||
    ($j["owner"]??"")!=="dinglebear-ai"||($j["runner_group_id"]??0)!==7||
    ($j["quarantine_runner_group_id"]??0)!==8||
    ($j["plugin_digest"]??"")!==str_pad("1",64,"0",STR_PAD_LEFT)||
    ($j["auth"]["mode"]??"")!=="pat"||($j["auth"]["token_file"]??"")!==$argv[2]||
    count($j["pools"]??[])!==1||($j["pools"][0]["id"]??"")!=="python"||
    ($j["pools"][0]["labels"]??[])!==["python","node"])exit(1);
' "$SCALESET_RUNTIME_CONFIG" "$TOKEN_FILE"
[ "$(stat -c %a "$SCALESET_RUNTIME_CONFIG")" = 600 ]
! grep -q 'token$' "$SCALESET_RUNTIME_CONFIG"

# Exercise the real request encoder. The fake helper returns its stdin while a
# bound Unix socket satisfies the production preflight without accepting data.
fake_helper="$root/crf-scaleset"
cat >"$fake_helper" <<'EOF'
#!/bin/bash
[ "$1" = request ] || exit 2
cat
EOF
chmod 0755 "$fake_helper"
SCALESET_HELPER="$fake_helper"
SCALESET_SOCKET="$RUNDIR/scalesets/test.sock"
python3 - "$SCALESET_SOCKET" <<'PY' &
import socket
import sys
import time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
time.sleep(30)
PY
socket_pid=$!
for _ in $(seq 1 100); do
  [ -S "$SCALESET_SOCKET" ] && break
  sleep 0.01
done
encoded="$(scaleset_request apply_sessions '{"eligible":false}')"
php -r '
  $j=json_decode(stream_get_contents(STDIN),true);
  exit(is_array($j)&&($j["operation"]??"")==="apply_sessions"&&
    ($j["payload"]["eligible"]??null)===false?0:1);
' <<<"$encoded"

calls="$root/calls"
scaleset_request() {
  local payload="${2-}"
  [ -n "$payload" ] || payload='{}'
  printf '%s|%s\n' "$1" "$payload" >>"$calls"
  printf '{"ok":true}\n'
}
scaleset_prepare_ineligible "$(scaleset_ownership_revision)"
scaleset_activate_eligible "$(scaleset_ownership_revision)"
scaleset_make_ineligible "$(scaleset_ownership_revision)"
scaleset_delete_owned "$(scaleset_ownership_revision)"
grep -q '^apply_sessions|' "$calls"
grep -q '^reconcile_owned|{"eligible":true}' "$calls"
grep -q '^reconcile_owned|{"eligible":false}' "$calls"
grep -q '^delete_owned|' "$calls"
grep -Fq '8>&- 7>&- 9>&-' "$SCRIPT_DIR/runner-scalesets.sh" ||
  { echo "scale-set supervisor inherits fleet mutation locks" >&2; exit 1; }

echo "scale-set-control: OK"
