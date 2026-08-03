FROM ci-runner-farm-runner:s3-v5-20260802

USER root

ARG KACHE_FLEET_TAG=fleet-v0.12.0-prefetch-controls.1
ARG KACHE_FLEET_ARCHIVE=kache-fleet-v0.12.0-prefetch-controls.1-x86_64-unknown-linux-gnu.tar.gz
ARG KACHE_FLEET_ARCHIVE_SHA256=2c7e86b2fde706387389958ead210b94ca5f1469c730ceaf7f242032957f2eec
ARG KACHE_FLEET_BINARY_SHA256=86d13a5c8c7a1c38c947deb1d7b36c881c524d111233d2420b957d89112b34b2

RUN set -euo pipefail \
 && url="https://github.com/jmagar/kache/releases/download/${KACHE_FLEET_TAG}/${KACHE_FLEET_ARCHIVE}" \
 && tmp="$(mktemp -d)" \
 && curl -fsSL --retry 3 -o "$tmp/${KACHE_FLEET_ARCHIVE}" "$url" \
 && echo "${KACHE_FLEET_ARCHIVE_SHA256}  $tmp/${KACHE_FLEET_ARCHIVE}" | sha256sum -c - \
 && tar -xzf "$tmp/${KACHE_FLEET_ARCHIVE}" -C "$tmp" \
 && echo "${KACHE_FLEET_BINARY_SHA256}  $tmp/kache" | sha256sum -c - \
 && rm -rf /opt/hostedtoolcache/kache/0.12.0 \
 && install -d -m 0755 /opt/hostedtoolcache/kache/0.12.0/x64 \
 && install -m 0755 "$tmp/kache" /opt/hostedtoolcache/kache/0.12.0/x64/kache \
 && : > /opt/hostedtoolcache/kache/0.12.0/x64.complete \
 && ln -sfn /opt/hostedtoolcache/kache/0.12.0/x64/kache /usr/local/bin/kache \
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
