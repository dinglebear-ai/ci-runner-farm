# ci-runner-farm runner image (starter). Edit this from the plugin UI
# (Settings -> Utilities -> CI Runner Farm -> Runner image builder), then Build,
# and point the IMAGE setting at the resulting tag.
#
# This is a minimal starting point: the stock self-hosted runner base plus a
# docker-in-docker readiness wrapper. Add whatever your CI needs (language
# runtimes, browsers, build tools) in the marked section below.
# ubuntu 26.04 "resolute" (glibc 2.43), built LOCALLY from upstream's own
# recipe (myoung34/docker-github-actions-runner Dockerfile.base + Dockerfile
# with FROM swapped to ubuntu:26.04) because upstream ships no 26.04 tag.
# Why 26.04: kache keys proc-macros/dylibs on the glibc version and dookie is
# glibc 2.43 — on 24.04 (2.39) the runners and dookie were two disjoint cache
# key populations in the shared remote (ADR-0023). Matching glibc merges them.
# The pinned runner version inside the local image self-updates at runtime;
# rebuild recipe: /tmp/gha-runner-src on tootie or re-clone
# github.com/myoung34/docker-github-actions-runner and re-run the two builds.
# 26.04 keeps the ubuntu-latest package universe (libwebkit2gtk-4.1-dev etc.
# verified present for Tauri builds).
FROM local/github-runner:ubuntu-resolute

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Shared cargo-registry cache across all farm runners: disable cargo auto-GC so
# a build in one runner cannot evict registry crates a concurrent build in
# another is still compiling (root cause of intermittent aws-lc-sys "No such
# file or directory" .S failures). Prune manually if the cache ever grows.
ENV CARGO_CACHE_AUTO_CLEAN_FREQUENCY=never

# --- Add your packages / tools here ---
# Rust/C CI prerequisites: the workflows' "Setup Rust with kache" step needs
# a C toolchain and falls back to apt via sudo, which this image lacked
# ("apt-get is available but the runner is not root and sudo is missing").
# Bake the toolchain in and give the runner user passwordless sudo.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev cmake sudo clang lld mold \
 && rm -rf /var/lib/apt/lists/* \
 && printf 'runner ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# Fleet Kache backport: one canonical tool-cache binary, checksum-pinned.
# /usr/local/bin/kache is a symlink to the tool-cache entry so the container
# supervisor and kache-action clients resolve the same inode and protocol epoch.
ARG KACHE_FLEET_TAG=fleet-v0.13.0-prefetch-controls.1
ARG KACHE_FLEET_ARCHIVE=kache-fleet-v0.13.0-prefetch-controls.1-x86_64-unknown-linux-gnu.tar.gz
ARG KACHE_FLEET_ARCHIVE_SHA256=f9250450073dd48c23ee457093bb860a9acafc037608f11a1643471c0d00af6b
ARG KACHE_FLEET_BINARY_SHA256=87cddc742db80394a77e3c9e9cd53fb280bf2b3da2b2fd4c344d70820df46b06
RUN set -euo pipefail \
 && url="https://github.com/jmagar/kache/releases/download/${KACHE_FLEET_TAG}/${KACHE_FLEET_ARCHIVE}" \
 && tmp="$(mktemp -d)" \
 && curl -fsSL --retry 3 -o "$tmp/${KACHE_FLEET_ARCHIVE}" "$url" \
 && echo "${KACHE_FLEET_ARCHIVE_SHA256}  $tmp/${KACHE_FLEET_ARCHIVE}" | sha256sum -c - \
 && tar -xzf "$tmp/${KACHE_FLEET_ARCHIVE}" -C "$tmp" \
 && echo "${KACHE_FLEET_BINARY_SHA256}  $tmp/kache" | sha256sum -c - \
 && install -d -m 0755 /opt/hostedtoolcache/kache/0.13.0/x64 \
 && install -m 0755 "$tmp/kache" /opt/hostedtoolcache/kache/0.13.0/x64/kache \
 && : > /opt/hostedtoolcache/kache/0.13.0/x64.complete \
 && ln -sfn /opt/hostedtoolcache/kache/0.13.0/x64/kache /usr/local/bin/kache \
 && rm -rf "$tmp" \
 && /usr/local/bin/kache --version \
 && test "$(sha256sum /usr/local/bin/kache | awk '{print $1}')" = "$KACHE_FLEET_BINARY_SHA256"

ENV KACHE_VERIFY_RESTORES=sampled

# Rust 1.97.1 (fleet standard) baked as the runner user: saves the per-job
# toolchain download on fresh containers. dtolnay/rust-toolchain in jobs
# no-ops when the requested toolchain is already installed.
RUN gosu runner env HOME=/home/runner bash -c \
      "curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.97.1 --profile minimal -c clippy -c rustfmt" \
 && ls /home/runner/.rustup/toolchains

# Cache-mount destinations: pre-create as runner-owned, otherwise Docker's
# bind-mount auto-creation leaves root-owned parents and rustup/kache/npm
# cannot write beside them (e.g. "could not create bin directory
# '/home/runner/.cargo/bin': Permission denied").
RUN mkdir -p /home/runner/.cargo/registry /home/runner/.cargo/git \
      /home/runner/.cache/yarn /home/runner/.cache/ms-playwright \
      /home/runner/.npm /home/runner/.local/share/pnpm/store \
 && chown -R runner:runner /home/runner/.cargo /home/runner/.cache /home/runner/.npm /home/runner/.local

# Match dookie's host cargo profile EXACTLY (~/.cargo/config.toml on dookie).
# kache folds -C flags into the cache key, so profile drift forks the fleet
# into disjoint key populations even with identical glibc/toolchain: dev
# builds on dookie (debug=0, codegen-units=256) could never serve default-
# profile runner builds. Same speed-first philosophy as the dev box: fast
# agent compile loops over debuginfo. Keep this block in lockstep with
# dookie's [profile.dev]/[profile.test] or the shared remote splits again.
RUN mkdir -p /home/runner/.cargo && printf '%s\n' \
  "[profile.dev]" \
  "debug = 0" \
  "codegen-units = 256" \
  "split-debuginfo = \"off\"" \
  "incremental = false" \
  "opt-level = 0" \
  "" \
  "[profile.test]" \
  "debug = 0" \
  "codegen-units = 256" \
  "" \
  "[profile.dev.package.\"*\"]" \
  "opt-level = 0" \
  "" \
  "[target.x86_64-unknown-linux-gnu]" \
  "linker = \"clang\"" \
  "rustflags = [\"-C\", \"link-arg=-fuse-ld=mold\"]" \
  > /home/runner/.cargo/config.toml \
 && chown runner:runner /home/runner/.cargo/config.toml

# kache daemon config, read once at container boot by the supervised daemon
# below. ONE local store per container at /_work/.kache - /_work is this
# runner's PRIVATE persistent host mount, so the store survives jobs AND
# recycles without ever being shared across containers (the forbidden case is
# cross-OS-boundary sharing, not cross-repo: one store dedups all 19 repos).
RUN mkdir -p /home/runner/.config/kache && printf '%s\n' \
  "[cache]" \
  "local_store = \"/_work/.kache\"" \
  "daemon_idle_timeout_secs = 0" \
  "prefetch_enabled = false" \
  "modified_input_guard = true" \
  "local_max_size = \"80GiB\"" \
  "" \
  "[cache.remote]" \
  "type = \"s3\"" \
  "bucket = \"kache\"" \
  "endpoint = \"http://10.1.0.2:9000\"" \
  "region = \"us-east-1\"" \
  "prefix = \"rust\"" \
  "profile = \"kache\"" \
  > /home/runner/.config/kache/config.toml \
 && chown -R runner:runner /home/runner/.config

# Container-lifetime Kache daemon. Persistent runners disable speculative
# prefetch, so readiness is daemon/socket ownership rather than a full remote
# key LIST. Exact remote hits and asynchronous uploads are verified separately
# by the fleet cold canary. The supervisor stays outside job process groups so
# post-job orphan cleanup cannot kill it while uploads drain.
COPY kache-supervise.sh /usr/local/bin/kache-supervise.sh
RUN chmod 0755 /usr/local/bin/kache-supervise.sh

# DinD: the base entrypoint starts dockerd (START_DOCKER_SERVICE=true) but does
# NOT wait for it to be ready. Wrap the runner CMD so it waits for docker before
# the runner accepts jobs — otherwise 'Checking docker version'/services: race a
# cold daemon.
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# supervise dockerd: it can die under the services: workload (nested overlay)' \
  '( while true; do docker info >/dev/null 2>&1 || { rm -f /var/run/docker.pid; service docker start >>/var/log/dockerd.log 2>&1; }; sleep 3; done ) &' \
  '# supervise the kache daemon for the container lifetime: it is the only' \
  '# path that uploads dependency artifacts and serves remote lookups. A' \
  '# container-level daemon is outside job process groups, so the runner' \
  "# post-job orphan reaper cannot kill it and the upload queue survives" \
  '# job end (the per-job daemon lost ~half of each seeding run).' \
  '# (this wrapper already runs as the runner user - the base entrypoint' \
  '# drops privileges before exec-ing the CMD, so no gosu here)' \
  '/usr/local/bin/kache-supervise.sh &' \
  '# wait for first readiness before the runner accepts jobs' \
  'for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 1; done' \
  'exec "$@"' \
  > /usr/local/bin/wait-docker.sh \
 && chmod +x /usr/local/bin/wait-docker.sh
CMD ["/usr/local/bin/wait-docker.sh", "./bin/Runner.Listener", "run", "--startuptype", "service"]
