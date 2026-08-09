#!/usr/bin/env bash
# Keep the per-runner Kache daemon alive for the container lifetime.
# Persistent runners disable speculative prefetch, so readiness is daemon/socket
# ownership, not a full remote-key LIST. Exact remote checks and uploads remain
# enabled and are verified by the fleet cold canary.
set -uo pipefail

CACHE_DIR="${KACHE_CACHE_DIR:-/_work/.kache}"
DLOG="$CACHE_DIR/daemon.log"
SLOG=/home/runner/.kache-spawn.log
DOCKER_WAIT_SECS="${KACHE_SUPERVISOR_DOCKER_WAIT_SECS:-120}"
READY_WAIT_SECS="${KACHE_SUPERVISOR_READY_SECS:-120}"
KACHE_BIN=/usr/local/bin/kache
EXPECTED_EXE="$(readlink -f "$KACHE_BIN" 2>/dev/null)"
KENV="HOME=/home/runner PATH=/usr/local/bin:/usr/bin:/bin KACHE_CACHE_DIR=$CACHE_DIR KACHE_LOG=kache=info KACHE_VERIFY_RESTORES=sampled"

daemon_pids() {
  ps -eo user=,pid=,args= |
    awk -v uid="$(id -un)" '$1==uid && $0 ~ /[/]kache daemon run$/ {print $2}'
}

daemon_is_running() {
  local actual
  local -a pids=()
  [ -n "$EXPECTED_EXE" ] || return 1
  [ -S "$CACHE_DIR/daemon.sock" ] || return 1
  mapfile -t pids < <(daemon_pids)
  [ "${#pids[@]}" -eq 1 ] || return 1
  actual="$(readlink -f "/proc/${pids[0]}/exe" 2>/dev/null)"
  [ "$actual" = "$EXPECTED_EXE" ]
}

reset_daemons() {
  local pid alive
  local -a pids=()
  mapfile -t pids < <(daemon_pids)
  [ "${#pids[@]}" -gt 0 ] || { rm -f "$CACHE_DIR/daemon.sock"; return 0; }
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do
    alive=0
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true; done
  rm -f "$CACHE_DIR/daemon.sock"
}

for _ in $(seq 1 "$DOCKER_WAIT_SECS"); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done

while true; do
  mkdir -p "$CACHE_DIR" /home/runner/.cache/kache 2>/dev/null
  if ! daemon_is_running; then
    reset_daemons
    : > "$DLOG"
    : > "$SLOG"
    env -i $KENV "$KACHE_BIN" daemon run >>"$SLOG" 2>&1 &
    ready=""
    for _ in $(seq 1 "$READY_WAIT_SECS"); do
      if daemon_is_running; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ -z "$ready" ]; then
      logger -t kache-supervise "daemon did not become ready - bouncing" 2>/dev/null || true
      env -i $KENV "$KACHE_BIN" daemon stop >/dev/null 2>&1 || true
      sleep 3
      continue
    fi
    logger -t kache-supervise "daemon ready; speculative prefetch disabled, exact remote cache active" 2>/dev/null || true
  fi
  sleep 10
done
