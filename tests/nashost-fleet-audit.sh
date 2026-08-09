#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. tests/lib/assert.sh

AUDIT=deployments/nashost/fleet-audit.sh
INSTALLER=deployments/nashost/install-fleet-audit.sh
bash -n "$AUDIT"
bash -n "$INSTALLER"

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
  'mutation-owner-status' \
  'kache-watchdog-daemon' \
  'GOTIFY_ENV=' \
  'X-Gotify-Key:' \
  'notify_success'; do
  grep -Fq "$needle" "$AUDIT" || crf_fail "audit contract missing: $needle"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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

env \
  CRF_EXPECTED_KACHE_ENDPOINT="http://10.23.45.67:9000" \
  CRF_BOOT_CONFIG_ROOT="$boot" \
  CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
  CRF_AUDIT_LOG_ROOT="$tmp/logs" \
  CRF_UPDATE_CRON=0 \
  CRF_INSTALL_RUN_AUDIT=0 \
  bash "$INSTALLER" > "$tmp/install.out"

installed="$plugin_dir/fleet-audit.sh"
config="$plugin_dir/fleet-audit.env"
wrapper="$user_root/scripts/ci-runner-farm-audit/script"
crf_assert_file_mode "$installed" 755
crf_assert_file_mode "$config" 600
crf_assert_file_mode "$wrapper" 755
grep -Fq "CRF_EXPECTED_PLUGIN_VERSION='9.9.9'" "$config"
grep -Fq "$(sha256sum "$plugin_dir/$package" | awk '{print $1}')" "$config"
grep -Fq "CRF_EXPECTED_KACHE_ENDPOINT='http://10.23.45.67:9000'" "$config"
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
