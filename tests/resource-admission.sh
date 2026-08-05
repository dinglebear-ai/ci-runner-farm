#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. tests/lib/assert.sh
# shellcheck disable=SC1091
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
# shellcheck disable=SC1091
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-resources.sh
# shellcheck disable=SC2034 # fixture globals are consumed by sourced helpers

task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
RUNDIR="$task_tmp/run"
RESERVATION_DIR="$RUNDIR/reservations"
CRF_HOST_CPUS=24
CRF_HOST_MEMORY_BYTES=$((128 * 1024 * 1024 * 1024))
RESOURCE_CPU_BUDGET=auto
RESOURCE_MEMORY_BUDGET=auto
RESOURCE_CPU_RESERVE=2
RESOURCE_MEMORY_RESERVE=8g
RESOURCE_CPU_OVERCOMMIT=1.0

resource_budget_resolve
crf_assert_eq 22000 "$RESOURCE_CPU_BUDGET_MILLI" "auto CPU budget"
crf_assert_eq 128849018880 "$RESOURCE_MEMORY_BUDGET_BYTES" "auto memory budget"
CRF_HOST_MEMORY_BYTES=not-a-number
if resource_budget_resolve; then crf_fail "invalid host memory override was accepted"; fi
crf_assert_eq invalid_host_memory "$RESOURCE_REASON"
CRF_HOST_MEMORY_BYTES=$((128 * 1024 * 1024 * 1024))

RESOURCE_CPU_OVERCOMMIT=1.5
resource_budget_resolve
crf_assert_eq 33000 "$RESOURCE_CPU_BUDGET_MILLI" "CPU overcommit"
RESOURCE_CPU_OVERCOMMIT=1.0

RESOURCE_CPU_RESERVE=24
if resource_budget_resolve; then crf_fail "reserve exhausting CPU budget was accepted"; fi
crf_assert_eq cpu_reserve_exhausts_budget "$RESOURCE_REASON"
RESOURCE_CPU_RESERVE=2

resource_budget_resolve
crf_assert_eq 5 "$(resource_standalone_capacity 4000 $((24 * 1024 * 1024 * 1024)))" "standalone capacity"

export GH_OWNER=acme GH_SCOPE=org RUNNER_MODE=pools POOL_BACKEND=classic
export RUNNER_CPUS=2 RUNNER_MEMORY=4g
export RUNNER_POOLS='v2|rust|ci-rust|rust|1|1|8|1|4|16g'
pool_snapshot_load

inventory="$task_tmp/inventory.tsv"
printf 'ci-runner-rust-1|running|healthy|4000000000|17179869184|hash|rust|org:acme|1|ci-rust|valid\n' > "$inventory"
resource_snapshot_refresh "$inventory"
crf_assert_eq 4000 "$RESOURCE_INVENTORY_CPU_MILLI" "inventory CPU"
crf_assert_eq 17179869184 "$RESOURCE_INVENTORY_MEMORY_BYTES" "inventory memory"
resource_admit_one 4000 17179869184

CRF_BOOT_ID=test-boot CRF_OWNER_PID=1234
reservation_create rust ci-runner-rust-2 4000 17179869184 spec config op-1 2000000000
crf_assert_eq op-1 "$CRF_RESERVATION_ID"
crf_assert_file_mode "$RESERVATION_DIR/op-1.state" 600
resource_snapshot_refresh "$inventory"
crf_assert_eq 8000 "$RESOURCE_CPU_RESERVED_MILLI" "reservation CPU charge"
crf_assert_eq 34359738368 "$RESOURCE_MEMORY_RESERVED_BYTES" "reservation memory charge"

reservation_set_phase op-1 acting
crf_assert_eq acting "$(reservation_field "$RESERVATION_DIR/op-1.state" phase)"
if reservation_create rust ci-runner-rust-duplicate 4000 17179869184 spec config op-1 2000000000; then
  crf_fail "duplicate reservation ID overwrote live state"
fi
if reservation_set_phase '../escape' acting || reservation_release '../escape'; then
  crf_fail "unsafe reservation ID reached a filesystem mutation"
fi
reservation_release op-1
[ ! -e "$RESERVATION_DIR/op-1.state" ] || crf_fail "reservation was not released"

reservation_create rust ci-runner-rust-2 4000 17179869184 spec config observed 2000000000
printf 'ci-runner-rust-2|running|healthy|4000000000|17179869184|hash|rust|org:acme|2|ci-rust|valid\n' >> "$inventory"
reservation_reconcile "$inventory" 1700000000
[ ! -e "$RESERVATION_DIR/observed.state" ] || crf_fail "observed reservation was not reconciled"

reservation_create rust ci-runner-rust-3 4000 17179869184 spec config expired 100
reservation_reconcile "$inventory" 101
[ ! -e "$RESERVATION_DIR/expired.state" ] || crf_fail "expired orphan reservation was not released"

offer_lease_create rust poll-1 epoch-1 4000 17179869184 spec config 2000000000
lease_path="$RESERVATION_DIR/$CRF_RESERVATION_ID.state"
crf_assert_eq offered "$(reservation_field "$lease_path" phase)" "atomic lease offer phase"
crf_assert_eq poll-1 "$(reservation_field "$lease_path" poll_id)" "atomic lease poll identity"
offer_lease_assign "$CRF_RESERVATION_ID" ci-runner-rust-4
crf_assert_eq assigned "$(reservation_field "$lease_path" phase)" "lease assignment phase"
if offer_lease_assign "$CRF_RESERVATION_ID" ci-runner-rust-5; then
  crf_fail "assigned lease was reassigned"
fi
reservation_release "$CRF_RESERVATION_ID"

cat >"$RESERVATION_DIR/corrupt.state" <<'EOF'
schema_version=1
operation_id=corrupt
cpu_milli=999999999999999999999
memory_bytes=
EOF
chmod 0600 "$RESERVATION_DIR/corrupt.state"
resource_snapshot_refresh "$inventory"
crf_assert_eq 0 "$RESOURCE_CPU_ADMISSIBLE_MILLI" "corrupt reservation must fail CPU closed"
crf_assert_eq 0 "$RESOURCE_MEMORY_ADMISSIBLE_BYTES" "corrupt reservation must fail memory closed"
rm -f "$RESERVATION_DIR/corrupt.state"

printf 'unknown|running|healthy|0|0|hash|invalid||| |invalid-managed\n' > "$inventory"
resource_snapshot_refresh "$inventory"
crf_assert_eq 0 "$RESOURCE_CPU_ADMISSIBLE_MILLI" "invalid managed runner must consume CPU conservatively"
crf_assert_eq 0 "$RESOURCE_MEMORY_ADMISSIBLE_BYTES" "invalid managed runner must consume memory conservatively"

RESOURCE_CPU_BUDGET=4
RESOURCE_MEMORY_BUDGET=16g
RESOURCE_CPU_RESERVE=1
RESOURCE_MEMORY_RESERVE=1g
resource_snapshot_refresh /dev/null
if resource_admit_one 4000 1073741824; then crf_fail "oversized CPU claim accepted"; fi
crf_assert_eq cpu_claim_exceeds_budget "$RESOURCE_REASON"
if resource_admit_one 1000 17179869184; then crf_fail "oversized memory claim accepted"; fi
crf_assert_eq memory_claim_exceeds_budget "$RESOURCE_REASON"
if resource_admit_one 999999999999999999999 1; then crf_fail "overflowing CPU claim accepted"; fi
crf_assert_eq invalid_claim "$RESOURCE_REASON"
ln -s "$inventory" "$task_tmp/inventory-link"
if resource_inventory_totals "$task_tmp/inventory-link"; then crf_fail "symlink inventory was accepted"; fi

RESOURCE_CPU_BUDGET=auto RESOURCE_MEMORY_BUDGET=auto RESOURCE_CPU_RESERVE=2 RESOURCE_MEMORY_RESERVE=8g
SHARE_DOCKER_SOCK=true CRF_SKIP_CGROUP_PREFLIGHT=1
if resource_v2_preflight; then crf_fail "host Docker socket was accepted for V2"; fi
crf_assert_eq host_docker_socket_forbidden "$RESOURCE_REASON"
SHARE_DOCKER_SOCK=false
resource_v2_preflight

echo "resource-admission: OK"
