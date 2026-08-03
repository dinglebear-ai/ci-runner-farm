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
KENV="HOME=/home/runner PATH=/usr/local/bin:/usr/bin:/bin KACHE_CACHE_DIR=$CACHE_DIR KACHE_LOG=kache=info KACHE_VERIFY_RESTORES=sampled"

daemon_is_running() {
  [ -S "$CACHE_DIR/daemon.sock" ] || return 1
  pgrep -u "$(id -u)" -f '(^|/)kache daemon run$' >/dev/null 2>&1
}

for _ in $(seq 1 "$DOCKER_WAIT_SECS"); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done

while true; do
  mkdir -p "$CACHE_DIR" /home/runner/.cache/kache 2>/dev/null
  if ! daemon_is_running; then
    : > "$DLOG"
    : > "$SLOG"
    env -i $KENV /usr/local/bin/kache daemon run >>"$SLOG" 2>&1 &
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
      env -i $KENV /usr/local/bin/kache daemon stop >/dev/null 2>&1 || true
      sleep 3
      continue
    fi
    logger -t kache-supervise "daemon ready; speculative prefetch disabled, exact remote cache active" 2>/dev/null || true
  fi
  sleep 10
done
