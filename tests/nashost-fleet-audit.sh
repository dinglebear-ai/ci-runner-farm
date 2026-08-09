#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. tests/lib/assert.sh

AUDIT=deployments/nashost/fleet-audit.sh
INSTALLER=deployments/nashost/install-fleet-audit.sh
VALIDATOR=deployments/nashost/endpoint-validation.sh
bash -n "$AUDIT" "$INSTALLER" "$VALIDATOR"
# shellcheck source=deployments/nashost/endpoint-validation.sh
. "$VALIDATOR"

valid_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
audit_rejects_endpoint() {
  local endpoint="$1" expected="$2" output status
  set +e
  output="$(env \
    CRF_EXPECTED_KACHE_ENDPOINT="$endpoint" \
    CRF_EXPECTED_PLUGIN_VERSION=9.9.9 \
    CRF_EXPECTED_PLUGIN_PACKAGE_SHA256="$valid_hash" \
    CRF_AUDIT_LOG_ROOT="${TMPDIR:-/tmp}/crf-audit-endpoint-test" \
    bash "$AUDIT" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || crf_fail "unsafe Kache endpoint exited $status instead of 2"
  grep -Fq "$expected" <<<"$output" ||
    crf_fail "unsafe Kache endpoint was not rejected: $endpoint ($output)"
}

audit_rejects_endpoint '' 'CRF_EXPECTED_KACHE_ENDPOINT is required'
audit_rejects_endpoint 'http://192.0.2.2:9000' 'documentation-only address'
audit_rejects_endpoint 'http://builder@192.0.2.2:9000' 'documentation-only address'
audit_rejects_endpoint 'http://198.51.100.9:9000' 'documentation-only address'
audit_rejects_endpoint 'https://203.0.113.4' 'documentation-only address'
audit_rejects_endpoint 'http://cache.internal:9000"'$'\n''profile = "attacker' 'unsafe characters'
audit_rejects_endpoint 'http://cache.internal:9000\escaped' 'unsafe characters'
audit_rejects_endpoint "http://cache.internal:9000'quoted" 'unsafe characters'
audit_rejects_endpoint 'http://cache.internal:9000 path' 'unsafe characters'
audit_rejects_endpoint 'http://user@' 'valid authority'

# These are literal source-contract strings, not expressions for this test shell.
# shellcheck disable=SC2016
for needle in \
  'CRF_EXPECTED_COUNT="${CRF_EXPECTED_COUNT:-16}"' \
  'CRF_EXPECTED_CPU_CONFIGURED_MILLI="${CRF_EXPECTED_CPU_CONFIGURED_MILLI:-74000}"' \
  'CRF_EXPECTED_CPU_HEADROOM_MILLI="${CRF_EXPECTED_CPU_HEADROOM_MILLI:-2000}"' \
  'CRF_EXPECTED_MEMORY_CONFIGURED_BYTES="${CRF_EXPECTED_MEMORY_CONFIGURED_BYTES:-122406567936}"' \
  'CRF_EXPECTED_MEMORY_HEADROOM_BYTES="${CRF_EXPECTED_MEMORY_HEADROOM_BYTES:-2147483648}"' \
  'github_online_exact=' \
  'reconcile-status' \
  'mutation-owner-status' \
  'kache-watchdog-daemon' \
  'GOTIFY_ENV=' \
  'X-Gotify-Key:' \
  'notify_success'; do
  grep -Fq "$needle" "$AUDIT" || crf_fail "audit contract missing: $needle"
done
if grep -Fq "pgrep -f '[r]unner-farm.sh reconcile-drain'" "$AUDIT"; then
  crf_fail 'audit still uses broad process-name matching for reconciliation ownership'
fi

tmp="$(mktemp -d)"
gotify_server_pid=""
hostile_server_pid=""
cleanup() {
  [ -z "$gotify_server_pid" ] || kill "$gotify_server_pid" 2>/dev/null || true
  [ -z "$hostile_server_pid" ] || kill "$hostile_server_pid" 2>/dev/null || true
  [ -z "$gotify_server_pid" ] || wait "$gotify_server_pid" 2>/dev/null || true
  [ -z "$hostile_server_pid" ] || wait "$hostile_server_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Neither runtime configuration file is executable shell input. The scheduled
# audit runs as root, so every malformed or untrusted fixture must be rejected
# before it can execute a payload or create the audit log/lock state.
runtime_config_rejects_without_side_effects() {
  local label="$1" audit_fixture="$2" gotify_fixture="$3"
  local fake_path="${4:-$PATH}" audit_mode="${5:-0600}" gotify_mode="${6:-0600}"
  local audit_env="$tmp/runtime-audit.env" gotify_runtime_env="$tmp/runtime-gotify.env"
  local runtime_logs="$tmp/runtime-reject-logs" status
  if [ "$audit_mode" != preserve ]; then
    printf '%s' "$audit_fixture" >"$audit_env"
    chmod "$audit_mode" "$audit_env"
  fi
  if [ "$gotify_mode" != preserve ]; then
    printf '%s' "$gotify_fixture" >"$gotify_runtime_env"
    chmod "$gotify_mode" "$gotify_runtime_env"
  fi
  rm -rf "$runtime_logs" "$tmp/runtime-payload-executed"
  set +e
  env \
    PATH="$fake_path" \
    CRF_ENGINE="$tmp/unavailable-engine" \
    CRF_AUDIT_CONFIG="$audit_env" \
    CRF_GOTIFY_ENV="$gotify_runtime_env" \
    CRF_AUDIT_LOG_ROOT="$runtime_logs" \
    CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000' \
    CRF_EXPECTED_PLUGIN_VERSION=9.9.9 \
    CRF_EXPECTED_PLUGIN_PACKAGE_SHA256="$valid_hash" \
    bash "$AUDIT" >"$tmp/runtime-parser-reject.out" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || crf_fail "runtime audit accepted $label config"
  [ ! -e "$tmp/runtime-payload-executed" ] || crf_fail "runtime audit executed $label config"
  [ ! -e "$runtime_logs" ] || crf_fail "runtime audit created log state for rejected $label config"
}

runtime_payload="touch '$tmp/runtime-payload-executed'"
runtime_config_rejects_without_side_effects 'audit command-line' \
  "$runtime_payload"$'\n' ''
runtime_config_rejects_without_side_effects 'audit command-substitution' \
  "CRF_EXPECTED_COUNT=\"\$(touch '$tmp/runtime-payload-executed')\""$'\n' ''
runtime_config_rejects_without_side_effects 'audit duplicate-key' \
  "CRF_EXPECTED_COUNT='16'"$'\n'"CRF_EXPECTED_COUNT='17'"$'\n' ''
runtime_config_rejects_without_side_effects 'audit unknown-key' \
  "CRF_EXPECTED_COUNT='16'"$'\n'"CRF_UNSUPPORTED_EXPECTATION='1'"$'\n' ''
runtime_config_rejects_without_side_effects 'Gotify command-line' '' \
  "$runtime_payload"$'\n'
runtime_config_rejects_without_side_effects 'Gotify command-substitution' '' \
  "GOTIFY_TOKEN=\"\$(touch '$tmp/runtime-payload-executed')\""$'\n'
runtime_config_rejects_without_side_effects 'Gotify duplicate-key' '' \
  "GOTIFY_URL='https://gotify.internal'"$'\n'"GOTIFY_URL='https://gotify.other.internal'"$'\n'
runtime_config_rejects_without_side_effects 'Gotify unknown-key' '' \
  "GOTIFY_PRIORITY='8'"$'\n'
runtime_config_rejects_without_side_effects 'audit world-readable' \
  "CRF_EXPECTED_COUNT='16'"$'\n' '' "$PATH" 0644 0600
runtime_config_rejects_without_side_effects 'Gotify world-readable' '' \
  "GOTIFY_URL='https://gotify.internal'"$'\n' "$PATH" 0600 0644

mkdir -p "$tmp/runtime-foreign-bin"
runtime_real_stat="$(command -v stat)"
cat >"$tmp/runtime-foreign-bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %u ] && [ "${3:-}" = "$CRF_RUNTIME_FOREIGN_FILE" ]; then
  echo 65534
  exit 0
fi
exec "$CRF_RUNTIME_REAL_STAT" "$@"
SH
chmod +x "$tmp/runtime-foreign-bin/stat"
export CRF_RUNTIME_REAL_STAT="$runtime_real_stat"
export CRF_RUNTIME_FOREIGN_FILE="$tmp/runtime-audit.env"
runtime_config_rejects_without_side_effects 'foreign-owned audit' \
  "CRF_EXPECTED_COUNT='16'"$'\n' '' "$tmp/runtime-foreign-bin:$PATH"
export CRF_RUNTIME_FOREIGN_FILE="$tmp/runtime-gotify.env"
runtime_config_rejects_without_side_effects 'foreign-owned Gotify' '' \
  "GOTIFY_URL='https://gotify.internal'"$'\n' "$tmp/runtime-foreign-bin:$PATH"
unset CRF_RUNTIME_FOREIGN_FILE CRF_RUNTIME_REAL_STAT

runtime_audit_real="$tmp/runtime-audit-real.env"
printf "CRF_EXPECTED_COUNT='16'\n" >"$runtime_audit_real"; chmod 0600 "$runtime_audit_real"
rm -f "$tmp/runtime-audit.env"; ln -s "$runtime_audit_real" "$tmp/runtime-audit.env"
printf '' >"$tmp/runtime-gotify.env"; chmod 0600 "$tmp/runtime-gotify.env"
runtime_config_rejects_without_side_effects 'symlinked audit' '' '' "$PATH" preserve preserve
rm -f "$tmp/runtime-audit.env" "$runtime_audit_real"
runtime_gotify_real="$tmp/runtime-gotify-real.env"
printf "GOTIFY_URL='https://gotify.internal'\n" >"$runtime_gotify_real"; chmod 0600 "$runtime_gotify_real"
printf '' >"$tmp/runtime-audit.env"; chmod 0600 "$tmp/runtime-audit.env"
rm -f "$tmp/runtime-gotify.env"; ln -s "$runtime_gotify_real" "$tmp/runtime-gotify.env"
runtime_config_rejects_without_side_effects 'symlinked Gotify' '' '' "$PATH" preserve preserve
rm -f "$tmp/runtime-audit.env" "$tmp/runtime-gotify.env" "$runtime_gotify_real"

# Every documented audit override remains accepted as literal data. Reaching the
# unavailable-engine boundary (and creating its normal failure log) proves the
# parser accepted the entire contract without executing it.
cat >"$tmp/runtime-audit.env" <<EOF
WATCHDOG_SAMPLE_SECONDS='1'
CRF_NOTIFY_SUCCESS='false'
CRF_EXPECTED_COUNT='16'
CRF_EXPECTED_IMAGE_ID='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
CRF_EXPECTED_KACHE_VERSION='0.13.0'
CRF_EXPECTED_KACHE_SHA256='$valid_hash'
CRF_EXPECTED_KACHE_SOCKET='/_work/.kache/daemon.sock'
CRF_EXPECTED_KACHE_LOCAL_MAX='80GiB'
CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000'
CRF_EXPECTED_KACHE_BUCKET='kache'
CRF_EXPECTED_KACHE_PREFIX='rust'
CRF_EXPECTED_KACHE_REGION='us-east-1'
CRF_EXPECTED_KACHE_PROFILE='kache'
CRF_EXPECTED_AWS_MOUNT='/mnt/cache/runner/kache-aws|false'
CRF_EXPECTED_CPU_BUDGET_MILLI='76000'
CRF_EXPECTED_CPU_RESERVE_MILLI='1000'
CRF_EXPECTED_CPU_CONFIGURED_MILLI='74000'
CRF_EXPECTED_CPU_HEADROOM_MILLI='2000'
CRF_EXPECTED_MEMORY_BUDGET_BYTES='124554051584'
CRF_EXPECTED_MEMORY_RESERVE_BYTES='8589934592'
CRF_EXPECTED_MEMORY_CONFIGURED_BYTES='122406567936'
CRF_EXPECTED_MEMORY_HEADROOM_BYTES='2147483648'
CRF_RUNNER_NAME_PREFIX='nashost-'
CRF_EXPECTED_PLUGIN_VERSION='9.9.9'
CRF_EXPECTED_PLUGIN_PACKAGE_SHA256='$valid_hash'
EOF
printf 'GOTIFY_URL="https://gotify.internal"\nGOTIFY_TOKEN='"'"''"'"'\n' >"$tmp/runtime-gotify.env"
chmod 0600 "$tmp/runtime-audit.env" "$tmp/runtime-gotify.env"
rm -rf "$tmp/runtime-valid-logs"
set +e
env CRF_ENGINE="$tmp/unavailable-engine" \
  CRF_AUDIT_CONFIG="$tmp/runtime-audit.env" CRF_GOTIFY_ENV="$tmp/runtime-gotify.env" \
  CRF_AUDIT_LOG_ROOT="$tmp/runtime-valid-logs" bash "$AUDIT" >/dev/null 2>&1
runtime_valid_status=$?
set -e
[ "$runtime_valid_status" -eq 1 ] && [ -d "$tmp/runtime-valid-logs" ] ||
  crf_fail 'runtime parser rejected a supported quoted audit/Gotify literal'

# A configured token without an explicitly approved URL is a configuration
# failure, not permission to fall back to a plausible hostname. It must fail
# before curl can transmit anything and leave the reason in the audit log.
mkdir -p "$tmp/bin" "$tmp/notify-logs"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
: >"$CRF_FAKE_CURL_CALLED"
exit 0
SH
chmod +x "$tmp/bin/curl"
notify_secret='gotify-token-must-not-leak'
set +e
notify_output="$(env \
  PATH="$tmp/bin:$PATH" \
  CRF_FAKE_CURL_CALLED="$tmp/curl-called" \
  CRF_ENGINE="$tmp/unavailable-engine" \
  CRF_AUDIT_CONFIG="$tmp/no-audit-config" \
  CRF_GOTIFY_ENV="$tmp/no-gotify-env" \
  CRF_AUDIT_LOG_ROOT="$tmp/notify-logs" \
  CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000' \
  CRF_EXPECTED_PLUGIN_VERSION=9.9.9 \
  CRF_EXPECTED_PLUGIN_PACKAGE_SHA256="$valid_hash" \
  GOTIFY_URL='' GOTIFY_TOKEN="$notify_secret" \
  bash "$AUDIT" 2>&1)"
notify_status=$?
set -e
[ "$notify_status" -ne 0 ] || crf_fail 'token without GOTIFY_URL passed the fleet audit'
[ ! -e "$tmp/curl-called" ] || crf_fail 'token without GOTIFY_URL attempted a network transmission'
notify_log="$(find "$tmp/notify-logs" -maxdepth 1 -type f -name '*.log' -print -quit)"
[ -n "$notify_log" ] || crf_fail 'Gotify configuration failure produced no audit log'
grep -Fq 'GOTIFY_URL is required when GOTIFY_TOKEN is configured' "$notify_log" ||
  crf_fail 'Gotify configuration failure was absent from the audit log'
if grep -Fq "$notify_secret" "$notify_log" || grep -Fq "$notify_secret" <<<"$notify_output"; then
  crf_fail 'Gotify token leaked into audit output or log'
fi

# Exercise delivery against a real local HTTP endpoint. A 2xx response passes;
# an HTTP failure is observable and nonzero, and neither path prints the token.
notify_functions="$tmp/notify-functions.sh"
sed -n '/^notify_gotify()/,/^)/p' "$AUDIT" >"$notify_functions"
# shellcheck disable=SC1090
. "$notify_functions"
for allowed_gotify_url in \
  'http://localhost' \
  'http://localhost:1' \
  'http://localhost:65535' \
  'http://127.0.0.1' \
  'http://127.0.0.1:8080' \
  'https://gotify.internal' \
  'https://gotify.internal:8443/base'; do
  require_gotify_url "$allowed_gotify_url" ||
    crf_fail "Gotify URL validation rejected approved target: $allowed_gotify_url"
done
for rejected_gotify_url in \
  'http://gotify.internal:8080' \
  'http://10.23.45.67:8080' \
  'http://user@localhost:8080' \
  'http://localhost@gotify.internal:8080' \
  'http://LOCALHOST:8080' \
  'http://localhost.:8080' \
  'http://127.0.0.2:8080' \
  'http://127.1:8080' \
  'http://2130706433:8080' \
  'http://0x7f000001:8080' \
  'http://[::1]:8080' \
  'http://localhost:' \
  'http://localhost:65536'; do
  if require_gotify_url "$rejected_gotify_url"; then
    crf_fail "Gotify URL validation accepted ambiguous or plaintext target: $rejected_gotify_url"
  fi
done
cat >"$tmp/gotify-server.py" <<'PY'
import http.server, json, pathlib, sys, urllib.parse

status_file, capture_file, port_file, count_file = map(pathlib.Path, sys.argv[1:])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', '0')))
        form = urllib.parse.parse_qs(body.decode(), strict_parsing=True)
        capture_file.write_text(json.dumps({
            'path': self.path,
            'headers': dict(self.headers.items()),
            'form': form,
        }))
        count = int(count_file.read_text()) if count_file.exists() else 0
        count_file.write_text(str(count + 1))
        status = int(status_file.read_text()) if self.path == '/message' else 404
        if self.path == '/message' and (
            form.get('title') != ['audit title'] or
            form.get('message') != ['audit message'] or
            form.get('priority') not in (['1'], ['8'])
        ):
            status = 422
        self.send_response(status)
        self.end_headers()
        self.wfile.write(b'{}')
    def log_message(self, *_):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
PY
printf '204\n' >"$tmp/gotify-status"
python3 "$tmp/gotify-server.py" "$tmp/gotify-status" "$tmp/gotify-capture" "$tmp/gotify-port" "$tmp/gotify-count" &
gotify_server_pid=$!
for _ in $(seq 1 100); do [ -s "$tmp/gotify-port" ] && break; sleep 0.02; done
[ -s "$tmp/gotify-port" ] || crf_fail 'local Gotify test endpoint did not start'
printf '204\n' >"$tmp/hostile-status"
python3 "$tmp/gotify-server.py" "$tmp/hostile-status" "$tmp/hostile-capture" "$tmp/hostile-port" "$tmp/hostile-count" &
hostile_server_pid=$!
for _ in $(seq 1 100); do [ -s "$tmp/hostile-port" ] && break; sleep 0.02; done
[ -s "$tmp/hostile-port" ] || crf_fail 'hostile curl endpoint did not start'
mkdir -p "$tmp/hostile-home"
printf 'url = "http://127.0.0.1:%s/from-curlrc"\n' "$(cat "$tmp/hostile-port")" >"$tmp/hostile-home/.curlrc"
# shellcheck disable=SC2034 # consumed by the sourced notify_gotify function
GOTIFY_URL="http://127.0.0.1:$(cat "$tmp/gotify-port")"
# shellcheck disable=SC2034 # consumed by the sourced notify_gotify function
GOTIFY_TOKEN="$notify_secret"
notify_ok="$(HOME="$tmp/hostile-home" \
  http_proxy="http://127.0.0.1:$(cat "$tmp/hostile-port")" \
  https_proxy="http://127.0.0.1:$(cat "$tmp/hostile-port")" \
  HTTP_PROXY="http://127.0.0.1:$(cat "$tmp/hostile-port")" \
  HTTPS_PROXY="http://127.0.0.1:$(cat "$tmp/hostile-port")" \
  NO_PROXY='' no_proxy='' \
  notify_gotify 'audit title' 'audit message' 1 2>&1)" ||
  crf_fail "configured local Gotify endpoint failed: $notify_ok"
for _ in $(seq 1 50); do [ -s "$tmp/gotify-count" ] && break; sleep 0.02; done
crf_assert_eq 1 "$(cat "$tmp/gotify-count" 2>/dev/null || echo 0)" 'approved Gotify request count'
crf_assert_eq 0 "$(cat "$tmp/hostile-count" 2>/dev/null || echo 0)" 'hostile curl request count'
python3 - "$tmp/gotify-capture" 1 "$notify_secret" <<'PY' || crf_fail 'approved Gotify request path, header, or success form fields were incorrect'
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected_priority = sys.argv[2]
expected_token = sys.argv[3]
assert request['path'] == '/message'
assert request['headers']['X-Gotify-Key'] == expected_token
assert request['form'] == {
    'title': ['audit title'],
    'message': ['audit message'],
    'priority': [expected_priority],
}
PY
[ -z "$notify_ok" ] || crf_fail 'successful Gotify delivery emitted unexpected output'
printf '503\n' >"$tmp/gotify-status"
if notify_failed="$(notify_gotify 'audit title' 'audit message' 8 2>&1)"; then
  crf_fail 'Gotify HTTP failure was hidden as success'
fi
crf_assert_eq 2 "$(cat "$tmp/gotify-count" 2>/dev/null || echo 0)" 'approved Gotify request count after failure'
python3 - "$tmp/gotify-capture" 8 <<'PY' || crf_fail 'failed Gotify request path or form fields were incorrect'
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected_priority = sys.argv[2]
assert request['path'] == '/message'
assert request['form'] == {
    'title': ['audit title'],
    'message': ['audit message'],
    'priority': [expected_priority],
}
PY
grep -Fq 'Gotify notification delivery failed' <<<"$notify_failed" ||
  crf_fail 'Gotify HTTP failure was not observable'
if grep -Fq "$notify_secret" <<<"$notify_failed"; then
  crf_fail 'Gotify delivery failure leaked the token'
fi
kill "$gotify_server_pid" 2>/dev/null || true
wait "$gotify_server_pid" 2>/dev/null || true
gotify_server_pid=""
kill "$hostile_server_pid" 2>/dev/null || true
wait "$hostile_server_pid" 2>/dev/null || true
hostile_server_pid=""

boot="$tmp/boot"
plugin_dir="$boot/plugins/ci-runner-farm"
user_root="$boot/plugins/user.scripts"
mkdir -p "$plugin_dir" "$user_root/scripts/existing" "$tmp/logs"
package=ci-runner-farm-test.tgz
printf 'package payload\n' > "$plugin_dir/$package"
cat > "$plugin_dir.plg" <<EOF
<!ENTITY pluginVersion "9.9.9">
<!ENTITY packageName "$package">
EOF
cat > "$user_root/schedule.json" <<'EOF'
{
  "/existing/script": {
    "script": "/existing/script",
    "frequency": "custom",
    "id": "scheduleexisting",
    "custom": "0 1 * * *"
  }
}
EOF
cat > "$user_root/customSchedule.cron" <<'EOF'
# Generated cron schedule for user.scripts
0 1 * * * /usr/local/emhttp/plugins/user.scripts/startCustom.php /existing/script > /dev/null 2>&1
EOF

for unsafe_endpoint in '' 'http://192.0.2.2:9000'; do
  schedule_before="$(sha256sum "$user_root/schedule.json" | awk '{print $1}')"
  cron_before="$(sha256sum "$user_root/customSchedule.cron" | awk '{print $1}')"
  set +e
  env \
    CRF_EXPECTED_KACHE_ENDPOINT="$unsafe_endpoint" \
    CRF_BOOT_CONFIG_ROOT="$boot" \
    CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
    CRF_AUDIT_LOG_ROOT="$tmp/logs" \
    CRF_UPDATE_CRON=0 \
    CRF_INSTALL_RUN_AUDIT=0 \
    bash "$INSTALLER" > "$tmp/install-reject.out" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || crf_fail "installer accepted unsafe Kache endpoint: $unsafe_endpoint"
  [ ! -e "$plugin_dir/fleet-audit.sh" ] || crf_fail "rejected install wrote the fleet audit"
  [ ! -e "$plugin_dir/fleet-audit.env" ] || crf_fail "rejected install wrote the audit config"
  [ ! -e "$plugin_dir/audit-schedule-backups" ] || crf_fail "rejected install wrote schedule backups"
  [ ! -e "$user_root/scripts/ci-runner-farm-audit" ] || crf_fail "rejected install wrote the User Scripts wrapper"
  crf_assert_eq "$schedule_before" "$(sha256sum "$user_root/schedule.json" | awk '{print $1}')" "schedule after rejected install"
  crf_assert_eq "$cron_before" "$(sha256sum "$user_root/customSchedule.cron" | awk '{print $1}')" "cron after rejected install"
done

# Installer preflight must independently enforce the plaintext boundary. This
# catches drift between its duplicated parser and the audit's parser above.
gotify_env="$user_root/gotify.env"

# The installer runs as root in production, so treating gotify.env as shell code
# would give configuration-file writers root command execution. Every malformed,
# executable, ambiguous, or untrusted fixture below must be rejected before any
# install/schedule state changes.
gotify_rejects_without_mutation() {
  local label="$1" fixture="$2" fake_path="${3:-$PATH}"
  local fixture_mode="${4:-0600}"
  local schedule_before cron_before status
  printf '%s' "$fixture" >"$gotify_env"
  chmod "$fixture_mode" "$gotify_env"
  schedule_before="$(sha256sum "$user_root/schedule.json" | awk '{print $1}')"
  cron_before="$(sha256sum "$user_root/customSchedule.cron" | awk '{print $1}')"
  set +e
  env \
    PATH="$fake_path" \
    CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000' \
    CRF_GOTIFY_ENV="$gotify_env" \
    CRF_BOOT_CONFIG_ROOT="$boot" \
    CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
    CRF_AUDIT_LOG_ROOT="$tmp/logs" \
    CRF_UPDATE_CRON=0 CRF_INSTALL_RUN_AUDIT=0 \
    bash "$INSTALLER" >"$tmp/gotify-parser-reject.out" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || crf_fail "installer accepted $label Gotify config"
  [ ! -e "$plugin_dir/fleet-audit.sh" ] || crf_fail "$label Gotify config wrote the fleet audit"
  [ ! -e "$plugin_dir/fleet-audit.env" ] || crf_fail "$label Gotify config wrote the audit config"
  [ ! -e "$plugin_dir/audit-schedule-backups" ] || crf_fail "$label Gotify config wrote schedule backups"
  [ ! -e "$user_root/scripts/ci-runner-farm-audit" ] || crf_fail "$label Gotify config wrote the User Scripts wrapper"
  crf_assert_eq "$schedule_before" "$(sha256sum "$user_root/schedule.json" | awk '{print $1}')" "schedule after $label Gotify rejection"
  crf_assert_eq "$cron_before" "$(sha256sum "$user_root/customSchedule.cron" | awk '{print $1}')" "cron after $label Gotify rejection"
}

payload_marker="$tmp/gotify-payload-executed"
gotify_rejects_without_mutation 'command-line' \
  "touch '$payload_marker'"$'\n'"GOTIFY_URL='https://gotify.internal'"$'\n'"GOTIFY_TOKEN='$notify_secret'"$'\n'
[ ! -e "$payload_marker" ] || crf_fail 'installer executed a Gotify command line'
gotify_rejects_without_mutation 'command-substitution' \
  "GOTIFY_URL=\"\$(touch '$payload_marker')\""$'\n'"GOTIFY_TOKEN='$notify_secret'"$'\n'
[ ! -e "$payload_marker" ] || crf_fail 'installer executed Gotify command substitution'
gotify_rejects_without_mutation 'duplicate-key' \
  "GOTIFY_URL='https://gotify.internal'"$'\n'"GOTIFY_URL='https://gotify.other.internal'"$'\n'"GOTIFY_TOKEN='$notify_secret'"$'\n'
gotify_rejects_without_mutation 'unknown-key' \
  "GOTIFY_URL='https://gotify.internal'"$'\n'"GOTIFY_TOKEN='$notify_secret'"$'\n'"GOTIFY_PRIORITY='8'"$'\n'
gotify_rejects_without_mutation 'world-readable' \
  "GOTIFY_URL='https://gotify.internal'"$'\n'"GOTIFY_TOKEN='$notify_secret'"$'\n' \
  "$PATH" 0644

# Simulate a file owned by another account at the stat boundary. The real file
# remains usable by this unprivileged test process; production must still reject
# the reported foreign UID before interpreting any bytes.
mkdir -p "$tmp/foreign-owner-bin"
real_stat="$(command -v stat)"
cat >"$tmp/foreign-owner-bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %u ] && [ "${3:-}" = "$CRF_FOREIGN_OWNER_FILE" ]; then
  echo 65534
  exit 0
fi
exec "$CRF_REAL_STAT" "$@"
SH
chmod +x "$tmp/foreign-owner-bin/stat"
export CRF_FOREIGN_OWNER_FILE="$gotify_env" CRF_REAL_STAT="$real_stat"
gotify_rejects_without_mutation 'foreign-owner' \
  "touch '$payload_marker'"$'\n'"GOTIFY_URL='https://gotify.internal'"$'\n'"GOTIFY_TOKEN='$notify_secret'"$'\n' \
  "$tmp/foreign-owner-bin:$PATH"
unset CRF_FOREIGN_OWNER_FILE CRF_REAL_STAT
[ ! -e "$payload_marker" ] || crf_fail 'foreign-owned Gotify config executed a command'

gotify_real="$tmp/gotify-real.env"
printf "GOTIFY_URL='https://gotify.internal'\nGOTIFY_TOKEN='%s'\n" "$notify_secret" >"$gotify_real"
chmod 0600 "$gotify_real"
rm -f "$gotify_env"
ln -s "$gotify_real" "$gotify_env"
gotify_rejects_without_mutation 'symlink' ''
rm -f "$gotify_env" "$gotify_real"

for hostile_gotify_url in \
  'http://gotify.internal:8080' \
  'http://user@localhost:8080'; do
  cat >"$gotify_env" <<EOF
GOTIFY_URL='$hostile_gotify_url'
GOTIFY_TOKEN='$notify_secret'
EOF
  chmod 0600 "$gotify_env"
  schedule_before="$(sha256sum "$user_root/schedule.json" | awk '{print $1}')"
  cron_before="$(sha256sum "$user_root/customSchedule.cron" | awk '{print $1}')"
  set +e
  env \
    CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000' \
    CRF_GOTIFY_ENV="$gotify_env" \
    CRF_BOOT_CONFIG_ROOT="$boot" \
    CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
    CRF_AUDIT_LOG_ROOT="$tmp/logs" \
    CRF_UPDATE_CRON=0 CRF_INSTALL_RUN_AUDIT=0 \
    bash "$INSTALLER" >"$tmp/gotify-hostile-install.out" 2>&1
  gotify_install_status=$?
  set -e
  [ "$gotify_install_status" -ne 0 ] || crf_fail "installer accepted hostile Gotify URL: $hostile_gotify_url"
  [ ! -e "$plugin_dir/fleet-audit.sh" ] || crf_fail 'rejected Gotify install wrote the fleet audit'
  [ ! -e "$plugin_dir/fleet-audit.env" ] || crf_fail 'rejected Gotify install wrote the audit config'
  [ ! -e "$plugin_dir/audit-schedule-backups" ] || crf_fail 'rejected Gotify install wrote schedule backups'
  [ ! -e "$user_root/scripts/ci-runner-farm-audit" ] || crf_fail 'rejected Gotify install wrote the User Scripts wrapper'
  crf_assert_eq "$schedule_before" "$(sha256sum "$user_root/schedule.json" | awk '{print $1}')" 'schedule after rejected Gotify install'
  crf_assert_eq "$cron_before" "$(sha256sum "$user_root/customSchedule.cron" | awk '{print $1}')" 'cron after rejected Gotify install'
done

# A token-only environment is rejected by the same read-only preflight.
printf "GOTIFY_TOKEN='%s'\n" "$notify_secret" >"$gotify_env"
chmod 0600 "$gotify_env"
set +e
env \
  CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000' \
  CRF_GOTIFY_ENV="$gotify_env" \
  CRF_BOOT_CONFIG_ROOT="$boot" \
  CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
  CRF_AUDIT_LOG_ROOT="$tmp/logs" \
  CRF_UPDATE_CRON=0 CRF_INSTALL_RUN_AUDIT=0 \
  bash "$INSTALLER" >"$tmp/gotify-install-reject.out" 2>&1
gotify_install_status=$?
set -e
[ "$gotify_install_status" -ne 0 ] || crf_fail 'installer accepted GOTIFY_TOKEN without GOTIFY_URL'
[ ! -e "$plugin_dir/fleet-audit.sh" ] || crf_fail 'rejected Gotify install wrote the fleet audit'
[ ! -e "$plugin_dir/fleet-audit.env" ] || crf_fail 'rejected Gotify install wrote the audit config'
[ ! -e "$plugin_dir/audit-schedule-backups" ] || crf_fail 'rejected Gotify install wrote schedule backups'
[ ! -e "$user_root/scripts/ci-runner-farm-audit" ] || crf_fail 'rejected Gotify install wrote the User Scripts wrapper'

cat >"$gotify_env" <<EOF
GOTIFY_URL="http://127.0.0.1:8080"
GOTIFY_TOKEN='$notify_secret'
EOF
chmod 0600 "$gotify_env"

env \
  CRF_EXPECTED_KACHE_ENDPOINT="http://10.23.45.67:9000" \
  CRF_GOTIFY_ENV="$gotify_env" \
  CRF_BOOT_CONFIG_ROOT="$boot" \
  CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
  CRF_AUDIT_LOG_ROOT="$tmp/logs" \
  CRF_UPDATE_CRON=0 \
  CRF_INSTALL_RUN_AUDIT=0 \
  bash "$INSTALLER" > "$tmp/install.out"

installed="$plugin_dir/fleet-audit.sh"
installed_validator="$plugin_dir/endpoint-validation.sh"
config="$plugin_dir/fleet-audit.env"
wrapper="$user_root/scripts/ci-runner-farm-audit/script"
crf_assert_file_mode "$installed" 755
crf_assert_file_mode "$installed_validator" 755
cmp -s "$VALIDATOR" "$installed_validator" || crf_fail 'installer changed the canonical endpoint validator'
crf_assert_file_mode "$config" 600
crf_assert_file_mode "$wrapper" 755
grep -Fq "CRF_EXPECTED_PLUGIN_VERSION='9.9.9'" "$config"
grep -Fq "$(sha256sum "$plugin_dir/$package" | awk '{print $1}')" "$config"
grep -Fq "CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000'" "$config"
if grep -Fq "$notify_secret" "$config" "$tmp/install.out"; then
  crf_fail 'installer copied or printed the Gotify token'
fi
grep -Fq "exec '$installed'" "$wrapper"
jq -e --arg script "$wrapper" '
  .["/existing/script"].custom == "0 1 * * *" and
  .[$script].frequency == "custom" and
  .[$script].custom == "30 6 * * *"
' "$user_root/schedule.json" >/dev/null
grep -Fq '/existing/script' "$user_root/customSchedule.cron"
crf_assert_eq 1 "$(grep -Fc "startCustom.php $wrapper " "$user_root/customSchedule.cron")" "audit cron entry count"

# Reinstalling is idempotent and must preserve unrelated schedules.
sleep 1
env \
  CRF_GOTIFY_ENV="$gotify_env" \
  CRF_BOOT_CONFIG_ROOT="$boot" \
  CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
  CRF_AUDIT_LOG_ROOT="$tmp/logs" \
  CRF_UPDATE_CRON=0 \
  CRF_INSTALL_RUN_AUDIT=0 \
  bash "$INSTALLER" >/dev/null
crf_assert_eq 1 "$(grep -Fc "startCustom.php $wrapper " "$user_root/customSchedule.cron")" "idempotent audit cron entry"
jq -e '.["/existing/script"].id == "scheduleexisting"' "$user_root/schedule.json" >/dev/null
grep -Fq "CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000'" "$config"
[ "$(find "$plugin_dir/audit-schedule-backups" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ge 2 ] ||
  crf_fail "installer did not preserve schedule backups"

echo 'nashost-fleet-audit: OK'
