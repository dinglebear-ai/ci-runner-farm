#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mod=tools/crf-scaleset
grep -Fq 'go 1.25.3' "$mod/go.mod"
grep -Fq 'github.com/actions/scaleset v0.4.0' "$mod/go.mod"
grep -Fq '6ce025902cd964747a078c2aabe7340ebc667eca' "$mod/cmd/crf-scaleset/main.go"
! grep -R -Eq 'listener\.New|listener\.Run' "$mod"
go test -C "$mod" ./...
go vet -C "$mod" ./...

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/run" "$tmpdir/cfg"
printf '{}\n' >"$tmpdir/cfg/compatibility.json"
chmod 0600 "$tmpdir/cfg/compatibility.json"
printf '%s\n' '#!/bin/sh' \
  'printf '\''{"ok":false,"code":"invalid_compatibility_record","error":"helper_digest_mismatch"}\n'\''' \
  'exit 2' >"$tmpdir/helper"
chmod 0755 "$tmpdir/helper"
SCRIPT_DIR="$tmpdir" RUNDIR="$tmpdir/run" CFGDIR="$tmpdir/cfg" \
  SCALESET_HELPER="$tmpdir/helper" SCALESET_COMPAT="$tmpdir/cfg/compatibility.json" \
  bash -c '. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh; [ "$(scaleset_record_reason)" = helper_digest_mismatch ]'

cat >"$tmpdir/cfg/evidence.json" <<EOF
{"schema_version":1,"owner":"dinglebear-ai","runner_group_name":"CI Runner Farm Trusted","runner_group_policy":"selected_repositories","observed_at":$(date +%s),"workload":{"total_assigned_jobs":true,"zero_to_one":true,"cancel_reassign":true,"ack_replay":true,"nested_cgroup_charging":true,"classic_quarantine_barrier":true}}
EOF
chmod 0600 "$tmpdir/cfg/evidence.json"
printf 'token\n' >"$tmpdir/cfg/token"
chmod 0600 "$tmpdir/cfg/token"
SCRIPT_DIR="$tmpdir" RUNDIR="$tmpdir/run" CFGDIR="$tmpdir/cfg" \
  SCALESET_STATE_DIR="$tmpdir/run/scalesets" \
  SCALESET_WORKLOAD_EVIDENCE="$tmpdir/cfg/evidence.json" \
  SCALESET_PROBE_CONFIG="$tmpdir/run/scalesets/probe.json" \
  TOKEN_FILE="$tmpdir/cfg/token" GH_SCOPE=org GH_OWNER=dinglebear-ai \
  RUNNER_GROUP='CI Runner Farm Trusted' AUTH_MODE=pat \
  GITHUB_APP_KEY_FILE="$tmpdir/cfg/app.pem" \
  bash -c '
    err(){ printf "%s\n" "$*" >&2; }
    . src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
    scaleset_bound_identity(){ printf "%064d|%064d|%064d|%064d|dinglebear-ai|installation-1|%064d\n" 1 2 3 4 5; }
    scaleset_installation_id(){ printf "installation-1\n"; }
    created=0
    gh_api_request(){
      GH_STATUS=200
      case "$1:$2" in
        POST:*/actions/runner-groups) created=1; GH_STATUS=201; GH_RESPONSE='\''{"id":8}'\'' ;;
        GET:*/actions/runner-groups/*/repositories*) GH_RESPONSE='\''{"total_count":0,"repositories":[]}'\'' ;;
        GET:*/actions/runner-groups*) if [ "$created" = 1 ]; then
          GH_RESPONSE='\''{"runner_groups":[
            {"id":7,"name":"CI Runner Farm Trusted","visibility":"selected","allows_public_repositories":false},
            {"id":8,"name":"crf-scaleset-quarantine-490447eedbf12df1","visibility":"selected","allows_public_repositories":false}
          ]}'\''
        else GH_RESPONSE='\''{"runner_groups":[
          {"id":7,"name":"CI Runner Farm Trusted","visibility":"selected","allows_public_repositories":false}
        ]}'\''; fi ;;
        *) return 1 ;;
      esac
    }
    scaleset_probe_config_write
    [ "$(stat -c %a "$SCALESET_PROBE_CONFIG")" = 600 ]
    php -r '\''
      $j=json_decode(file_get_contents($argv[1]),true);
      exit(($j["runtime"]["owner"]??"") === "dinglebear-ai" &&
        ($j["runtime"]["auth"]["token_file"]??"") === $argv[2] &&
        ($j["live"]["runner_group_id"]??0) === 7 &&
        ($j["live"]["runner_group_policy"]??"") === "selected_repositories" &&
        ($j["live"]["quarantine_runner_group_name"]??"") !== "" &&
        ($j["live"]["workload"]["zero_to_one"]??false) === true ? 0 : 1);
    '\'' "$SCALESET_PROBE_CONFIG" "$TOKEN_FILE"
  '
echo 'scale-set-probe: OK'
