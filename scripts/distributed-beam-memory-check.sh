#!/usr/bin/env bash
set -euo pipefail

readonly MIN_MEMORY_BYTES=10737418240

usage() {
  echo "usage: $0 snapshot|assert BASELINE_FILE" >&2
  exit 64
}

case "${1:-}" in
  snapshot|assert) mode="$1" ;;
  *) usage ;;
esac
baseline="${2:-}"
[ -n "$baseline" ] || usage

cgroup_dir="${CRF_CGROUP_DIR:-}"
if [ -z "$cgroup_dir" ]; then
  relative="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
  [ -n "$relative" ] || { echo 'cgroup v2 membership is unavailable' >&2; exit 1; }
  cgroup_dir="/sys/fs/cgroup${relative}"
fi

for name in memory.max memory.swap.max memory.events; do
  [ -r "$cgroup_dir/$name" ] || { echo "$name is unavailable at $cgroup_dir" >&2; exit 1; }
done

memory_max="$(<"$cgroup_dir/memory.max")"
memory_swap_max="$(<"$cgroup_dir/memory.swap.max")"
if [ "$memory_max" = max ] || ! [[ "$memory_max" =~ ^[0-9]+$ ]] || (( memory_max < MIN_MEMORY_BYTES )); then
  echo "finite memory.max must be at least $MIN_MEMORY_BYTES bytes; got $memory_max" >&2
  exit 1
fi
if [ "$memory_swap_max" != 0 ]; then
  echo "memory.swap.max must be 0 for the no-swap BEAM pool; got $memory_swap_max" >&2
  exit 1
fi

event_value() {
  awk -v key="$1" '$1 == key { print $2; found=1 } END { if (!found) exit 1 }' "$2"
}

oom="$(event_value oom "$cgroup_dir/memory.events")"
oom_kill="$(event_value oom_kill "$cgroup_dir/memory.events")"
printf 'cgroup=%s\nmemory.max=%s\nmemory.swap.max=%s\noom=%s\noom_kill=%s\n' \
  "$cgroup_dir" "$memory_max" "$memory_swap_max" "$oom" "$oom_kill"

if [ "$mode" = snapshot ]; then
  umask 077
  printf 'oom %s\noom_kill %s\n' "$oom" "$oom_kill" >"$baseline"
  exit 0
fi

[ -r "$baseline" ] || { echo "baseline is unavailable: $baseline" >&2; exit 1; }
baseline_oom="$(event_value oom "$baseline")"
baseline_oom_kill="$(event_value oom_kill "$baseline")"
if (( oom != baseline_oom || oom_kill != baseline_oom_kill )); then
  echo "BEAM acceptance caused an OOM event: oom $baseline_oom->$oom, oom_kill $baseline_oom_kill->$oom_kill" >&2
  exit 1
fi
