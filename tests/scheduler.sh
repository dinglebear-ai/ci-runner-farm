#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
. src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scheduler.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/demand" <<'EOF'
rust|5|1|0|0|0|0|auto|4000|8589934592|1|1
python|8|1|0|0|0|0|auto|1000|2147483648|1|1
typescript|7|1|0|0|0|0|auto|1000|2147483648|1|1
go|3|1|0|0|0|0|auto|2000|4294967296|1|1
ops|1|0|0|0|0|0|2|500|1073741824|1|1
EOF

while IFS='|' read -r name cursor cpu memory fresh expected_cursor expected_starts; do
  [[ "$name" == \#* ]] && continue
  scheduler_plan "$tmp/demand" "$cpu" "$memory" "$cursor" "$fresh" >"$tmp/out"
  [ "$SCHEDULER_CURSOR" = "$expected_cursor" ]
  [ "$SCHEDULER_STARTS" = "$expected_starts" ]
  [ "$(awk -F'|' '{n += $3} END {print n+0}' "$tmp/out")" = "$expected_starts" ]
  if [ "$fresh" = 0 ]; then
    [ "$(grep -c 'stale_demand' "$tmp/out")" = 5 ]
    [ "$(awk -F'|' '{n += $6} END {print n+0}' "$tmp/out")" = 0 ]
  fi
done < tests/fixtures/scheduler.tsv

# Broken pools cannot consume capacity or block healthy peers.
awk -F'|' 'BEGIN{OFS=FS} $1=="rust"{$11=0} {print}' "$tmp/demand" >"$tmp/broken"
scheduler_plan "$tmp/broken" 1000 2147483648 0 1 >"$tmp/out"
grep -q '^rust|.*|session_unhealthy|' "$tmp/out"
grep -q '^python|.*|1|' "$tmp/out"

# Service-capable slots satisfy demand; draining/charged slots do not.
cat >"$tmp/charged" <<'EOF'
python|3|1|4|2|0|0|8|1000|2147483648|1|1
rust|2|0|0|2|1|1|8|4000|8589934592|1|1
EOF
scheduler_plan "$tmp/charged" 8000 17179869184 0 1 >"$tmp/out"
grep -q '^python|4|0|none|none|0|4|0|0$' "$tmp/out"
grep -q '^rust|2|0|none|none|0|2|1|0$' "$tmp/out"

# Per-pool stale observations fail closed without blocking a fresh peer.
awk -F'|' 'BEGIN{OFS=FS} $1=="rust"{$12=0} {print}' "$tmp/demand" >"$tmp/stale"
scheduler_plan "$tmp/stale" 4000 8589934592 0 1 >"$tmp/out"
grep -q '^rust|.*|stale_demand|' "$tmp/out"
grep -Eq '^(python|typescript|go|ops)\\|.*\\|1\\|' "$tmp/out"

# Hard fuse wins even if a caller asks for an unsafe burst.
SCHEDULER_START_LIMIT=99 scheduler_plan "$tmp/demand" 64000 137438953472 0 1 >"$tmp/out"
[ "$SCHEDULER_STARTS" = 4 ]
[ "$(awk -F'|' '{n += $9} END {print n+0}' "$tmp/out")" -gt 0 ]

# Hostile counts are rejected before Bash arithmetic can wrap them.
printf 'rust|999999999999999999999|1|0|0|0|0|auto|4000|8589934592|1|1\n' >"$tmp/overflow"
if scheduler_plan "$tmp/overflow" 8000 17179869184 0 1 >/dev/null; then
  echo 'overflowing scheduler count was accepted' >&2
  exit 1
fi
[ "$SCHEDULER_ERROR" = invalid_scheduler_count ]

echo "scheduler: OK"
