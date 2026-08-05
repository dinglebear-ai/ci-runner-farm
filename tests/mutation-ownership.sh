#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. tests/lib/assert.sh
ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '
  /^mutation_owner_token_valid\(\)/ {copy=1}
  /^# Serialize all fleet mutation/ {copy=0}
  copy {print}
' "$ENGINE" > "$tmp/functions.sh"
awk '/^with_fleet_lock\(\)/ {copy=1} copy {print} copy && /^}$/ {exit}' "$ENGINE" >> "$tmp/functions.sh"
# shellcheck disable=SC1091
. "$tmp/functions.sh"

RUNDIR="$tmp/run"
mkdir -p "$RUNDIR"
MUTATION_OWNER_FILE="$RUNDIR/mutation-owner.state"
resource_uint_valid() { [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]] && [ "$1" -le "${2:-9000000000000000000}" ]; }
resource_positive_uint_valid() { resource_uint_valid "${1:-}" "${2:-9000000000000000000}" && [ "$1" != 0 ]; }
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
err() { printf 'ERR %s\n' "$*" >&2; }
log() { printf 'LOG %s\n' "$*" >&2; }
record_action() { printf '%s\n' "${1:-ran}" > "$tmp/action"; }

claim="$(cmd_mutation_owner_claim session-a 300)"
grep -Fq '"active":true' <<<"$claim" || crf_fail "owner claim did not report active"
crf_assert_file_mode "$MUTATION_OWNER_FILE" 600

if cmd_mutation_owner_claim session-b 300 >/dev/null 2>&1; then
  crf_fail "competing mutation owner replaced an active lease"
fi
if cmd_mutation_owner_claim session-a 59 >/dev/null 2>&1; then
  crf_fail "undersized mutation lease TTL was accepted"
fi

unset CRF_MUTATION_OWNER || true
if mutation_owner_guard wait record_action >/dev/null 2>&1; then
  crf_fail "unowned mutation passed an active lease"
fi
rm -f "$tmp/action"
if with_fleet_lock wait record_action unowned >/dev/null 2>&1; then
  crf_fail "fleet lock admitted an unowned mutation"
fi
[ ! -e "$tmp/action" ] || crf_fail "blocked mutation still executed"

export CRF_MUTATION_OWNER=session-a
with_fleet_lock wait record_action owned
crf_assert_eq owned "$(cat "$tmp/action")" "owned mutation execution"

unset CRF_MUTATION_OWNER
rm -f "$tmp/action"
with_fleet_lock try record_action daemon-tick
[ ! -e "$tmp/action" ] || crf_fail "daemon tick ignored active mutation ownership"

grep -Fq '"owner":"session-a"' < <(cmd_mutation_owner_status) ||
  crf_fail "mutation owner status lost the active owner"
if cmd_mutation_owner_release session-b >/dev/null 2>&1; then
  crf_fail "non-owner released mutation lease"
fi
cmd_mutation_owner_release session-a >/dev/null
[ ! -e "$MUTATION_OWNER_FILE" ] || crf_fail "owner release left state behind"
with_fleet_lock wait record_action released
crf_assert_eq released "$(cat "$tmp/action")" "unleased mutation execution"

cmd_mutation_owner_claim session-a 300 >/dev/null
sed -i 's/^expires_at=.*/expires_at=1/' "$MUTATION_OWNER_FILE"
status="$(cmd_mutation_owner_status)"
grep -Fq '"active":false' <<<"$status" || crf_fail "expired owner remained active"
[ ! -e "$MUTATION_OWNER_FILE" ] || crf_fail "expired owner state was not removed"

cmd_mutation_owner_claim session-a 300 >/dev/null
sed -i 's/^boot_id=.*/boot_id=00000000-0000-000-0000-000000000000/' "$MUTATION_OWNER_FILE"
status="$(cmd_mutation_owner_status)"
grep -Fq '"active":false' <<<"$status" || crf_fail "previous-boot owner remained active"
[ ! -e "$MUTATION_OWNER_FILE" ] || crf_fail "previous-boot owner state was not removed"

cmd_mutation_owner_claim session-a 300 >/dev/null
chmod 0644 "$MUTATION_OWNER_FILE"
set +e
mutation_owner_state_load >/dev/null 2>&1
rc=$?
set -e
crf_assert_eq 2 "$rc" "unsafe owner state must fail closed"
chmod 0600 "$MUTATION_OWNER_FILE"
rm -f "$MUTATION_OWNER_FILE"

for guarded in \
  "autoscale-tick)   with_fleet_lock wait autoscale_tick" \
  "imageupdate-tick)   with_fleet_lock wait imageupdate_tick" \
  "begin-migration)  with_fleet_lock wait migration_start" \
  "continue-migration) with_fleet_lock wait migration_continue_guarded" \
  "rollback-backend) with_fleet_lock wait migration_rollback"; do
  grep -Fq "$guarded" "$ENGINE" || crf_fail "mutation dispatch is not owner-fenced: $guarded"
done

echo 'mutation-ownership: OK'
