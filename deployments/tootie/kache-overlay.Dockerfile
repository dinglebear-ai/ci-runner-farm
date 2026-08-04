FROM ci-runner-farm-runner:s3-v7-kache-013-20260803

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      php-cli ripgrep file \
 && rm -rf /var/lib/apt/lists/*

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
 && rm -rf /opt/hostedtoolcache/kache/0.13.0 \
 && install -d -m 0755 /opt/hostedtoolcache/kache/0.13.0/x64 \
 && install -m 0755 "$tmp/kache" /opt/hostedtoolcache/kache/0.13.0/x64/kache \
 && : > /opt/hostedtoolcache/kache/0.13.0/x64.complete \
 && ln -sfn /opt/hostedtoolcache/kache/0.13.0/x64/kache /usr/local/bin/kache \
 && rm -rf "$tmp" \
 && test "$(sha256sum /usr/local/bin/kache | awk '{print $1}')" = "$KACHE_FLEET_BINARY_SHA256" \
 && /usr/local/bin/kache --version

RUN mkdir -p /home/runner/.config/kache \
 && printf '%s\n' \
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

COPY kache-supervise.sh /usr/local/bin/kache-supervise.sh
RUN chmod 0755 /usr/local/bin/kache-supervise.sh

ENV KACHE_VERIFY_RESTORES=sampled
