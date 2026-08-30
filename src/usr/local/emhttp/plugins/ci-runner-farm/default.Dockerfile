# ci-runner-farm runner image (starter). Edit this from the plugin UI
# (Settings -> Utilities -> CI Runner Farm -> Runner image builder), then Build,
# and point the IMAGE setting at the resulting tag.
#
# This is a minimal starting point: the stock self-hosted runner base plus a
# docker-in-docker readiness wrapper. Add whatever your CI needs (language
# runtimes, browsers, build tools) in the marked section below.
FROM myoung34/github-runner@sha256:bc766ffbf9c8e6fd301d486a0aecbfbaa7920ab33cef05958a9eab62dd119537

USER root
ENV DEBIAN_FRONTEND=noninteractive

# --- Add your packages / tools here ---
RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby \
 && rm -rf /var/lib/apt/lists/* \
 && usermod -aG docker runner

# Pre-create the default CACHE_MOUNTS destinations as runner-owned. When these
# paths are absent from the image, Docker's bind-mount auto-creation makes the
# missing parent directories root-owned, and a non-root runner (RUN_AS_ROOT=false)
# can then no longer write beside them — e.g. rustup fails with "could not
# create bin directory '/home/runner/.cargo/bin': Permission denied".
RUN mkdir -p /home/runner/.cargo/registry /home/runner/.cargo/git \
      /home/runner/.cache/sccache /home/runner/.cache/yarn /home/runner/.cache/ms-playwright \
      /home/runner/.npm /home/runner/.local/share/pnpm/store \
 && chown -R runner:runner /home/runner/.cargo /home/runner/.cache /home/runner/.npm /home/runner/.local

# DinD: the base entrypoint starts dockerd (START_DOCKER_SERVICE=true) but does
# NOT wait for it to be ready. Wrap the runner CMD so it waits for docker before
# the runner accepts jobs — otherwise 'Checking docker version'/services: race a
# cold daemon.
# The dockerd recovery body lives in its own root-only script rather than inline
# in the supervisor: it keeps the restart out of two nested levels of quoting,
# gives the pidfile guard and log cap somewhere to live, and lets a sudoers
# grant be scoped to this one command instead of relying on NOPASSWD:ALL.
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# Recover a dead dockerd. Root only - invoked by the wait-docker.sh supervisor.' \
  'log=/var/log/dockerd.log' \
  '[ -d /var/log/dind ] && log=/var/log/dind/dockerd.log' \
  '# Cap the log. This runs on every failed probe, and /var/log is the container' \
  '# writable layer when the dind bind mount is absent - on Unraid that is the' \
  '# shared docker.img, so an unrotated crashloop log is a host-wide disk vector.' \
  '[ "$(stat -c%s "$log" 2>/dev/null || echo 0)" -gt 33554432 ] && : > "$log"' \
  '# Never delete a LIVE daemon pidfile. dockerd refuses to start when this file' \
  '# names a running process, so removing it disarms the duplicate-instance guard' \
  '# and a later start can bring a second daemon up on the same data root -' \
  '# concurrent boltdb writers, which corrupts it unrecoverably.' \
  'pid=$(cat /var/run/docker.pid 2>/dev/null || true)' \
  'if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then exit 0; fi' \
  'rm -f /var/run/docker.pid' \
  'logger -t crf-docker-supervise "restarting dockerd" 2>/dev/null || true' \
  'service docker start >>"$log" 2>&1' \
  > /usr/local/bin/crf-dockerd-restart \
 && chmod +x /usr/local/bin/crf-dockerd-restart
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# Reach root at runtime rather than assuming a shape: the base image grants the' \
  '# runner user passwordless sudo, RUN_AS_ROOT=true runs this as root already,' \
  '# and a custom FROM may have neither. Say so instead of failing silently.' \
  'crf_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }' \
  'crf_can_root() { [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; }' \
  '# Wait for first readiness before the runner accepts jobs. timeout guards a' \
  '# daemon that accepts the connection but never answers - an untimed docker' \
  '# info blocks this loop forever.' \
  'for _ in $(seq 1 90); do timeout 10 docker info >/dev/null 2>&1 && break; sleep 1; done' \
  '# Supervise dockerd for the container lifetime: it can die under the services:' \
  '# workload (nested overlay). Start supervising only AFTER readiness resolves -' \
  '# the entrypoint launches dockerd asynchronously just before this script runs,' \
  '# so a supervisor started earlier fires a restart at a live, still-initialising' \
  '# daemon on every single boot. Back off on repeated failure so a dockerd that' \
  '# cannot start (ENOSPC, corrupt overlay) does not hot-loop forever.' \
  'if crf_can_root; then' \
  '  ( delay=3' \
  '    while true; do' \
  '      sleep "$delay"' \
  '      if timeout 10 docker info >/dev/null 2>&1; then delay=3; continue; fi' \
  '      crf_root /usr/local/bin/crf-dockerd-restart || true' \
  '      [ "$delay" -lt 60 ] && delay=$(( delay * 2 ))' \
  '    done ) &' \
  'else' \
  '  echo "crf: dockerd supervisor disabled (not root, no passwordless sudo)" >&2' \
  'fi' \
  'exec "$@"' \
  > /usr/local/bin/wait-docker.sh \
 && chmod +x /usr/local/bin/wait-docker.sh

# Health probe so ci-runner-farm can reap a runner whose GitHub registration was
# removed: its listener then loops forever on "Registration was not found /
# Retrying until reconnected" instead of exiting, so it never gets recycled and
# silently counts as idle capacity. Reports unhealthy ONLY in that stuck state —
# never a runner that is running a job or still starting.
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  '# Running a job => healthy, unconditionally (never interrupt a build).' \
  'pgrep -x Runner.Worker >/dev/null 2>&1 && exit 0' \
  '# No listener => nothing services jobs; recycle it.' \
  'pgrep -x Runner.Listener >/dev/null 2>&1 || exit 1' \
  '# Idle: require positive proof of a live session in the newest listener log.' \
  'log="$(ls -1t /actions-runner/_diag/Runner_*.log 2>/dev/null | head -1)"' \
  '[ -n "$log" ] || exit 0   # too early to tell; --start-period covers startup' \
  'last="$(grep -niE "Session created|Listening for Jobs|create session|connect error|Registration.*not found|has been removed|SessionConflict|SessionExpired|Retrying until reconnected|Runner listener exit" "$log" 2>/dev/null | tail -1)"' \
  'case "$last" in' \
  '  *"Session created"*|*"Listening for Jobs"*) exit 0 ;;  # connected' \
  '  "") exit 0 ;;                                          # inconclusive -> healthy' \
  '  *) exit 1 ;;                                           # stuck disconnected' \
  'esac' \
  > /usr/local/bin/runner-healthcheck.sh \
 && chmod +x /usr/local/bin/runner-healthcheck.sh
HEALTHCHECK --start-period=120s --interval=30s --timeout=10s --retries=3 \
  CMD ["/usr/local/bin/runner-healthcheck.sh"]

CMD ["/usr/local/bin/wait-docker.sh", "./bin/Runner.Listener", "run", "--startuptype", "service"]
