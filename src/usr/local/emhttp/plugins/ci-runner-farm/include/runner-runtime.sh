#!/bin/bash
# Shared runner runtime mutation boundary.
# Policy, admission, GitHub registration/JIT issuance, secret handoff, and
# reconciliation stay above this layer. This file owns only container runtime
# mutations so classic and scale-set paths cannot silently diverge.

crf_runtime_container_exists() {
  [ -n "${1:-}" ] || return 2
  docker inspect "$1" >/dev/null 2>&1
}

crf_runtime_run_prepared() {
  [ "${#ARGS[@]}" -gt 0 ] || return 2
  docker run "${ARGS[@]}" >/dev/null 2>&1
}

crf_runtime_run_prepared_capture() {
  [ "${#ARGS[@]}" -gt 0 ] || return 2
  docker run "${ARGS[@]}" 2>/dev/null
}

crf_runtime_stop_remove() {
  local container="${1:-}" timeout="${2:-30}"
  [ -n "$container" ] || return 2
  case "$timeout" in ""|*[!0-9]*) return 2 ;; esac
  [ "$timeout" -le 300 ] || return 2
  docker stop -t "$timeout" "$container" >/dev/null 2>&1 || true
  docker rm "$container" >/dev/null 2>&1
}

crf_runtime_force_remove() {
  [ -n "${1:-}" ] || return 2
  docker rm -f "$1" >/dev/null 2>&1
}
