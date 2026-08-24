# First-party Linux image for distributed/JIT runners. The Ubuntu base and
# Actions runner archives are immutable so every advertised capability can be
# traced to exact bytes.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG TARGETARCH
ARG ACTIONS_RUNNER_VERSION=2.336.0
ARG ACTIONS_RUNNER_X64_SHA256=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
ARG ACTIONS_RUNNER_ARM64_SHA256=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1
ENV DEBIAN_FRONTEND=noninteractive \
    ImageOS=ubuntu24 \
    ImageVersion=24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates curl git gosu inotify-tools jq libicu74 libssl3 xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1001 --shell /bin/bash runner \
 && install -d -o runner -g runner /actions-runner /_work

WORKDIR /actions-runner
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) runner_arch=x64; archive_sha="$ACTIONS_RUNNER_X64_SHA256" ;; \
      arm64) runner_arch=arm64; archive_sha="$ACTIONS_RUNNER_ARM64_SHA256" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    archive="actions-runner-linux-${runner_arch}-${ACTIONS_RUNNER_VERSION}.tar.gz"; \
    curl -fsSL --retry 3 -o "/tmp/$archive" \
      "https://github.com/actions/runner/releases/download/v${ACTIONS_RUNNER_VERSION}/$archive"; \
    echo "$archive_sha  /tmp/$archive" | sha256sum -c -; \
    tar -xzf "/tmp/$archive"; \
    rm -f "/tmp/$archive"; \
    ./bin/installdependencies.sh; \
    chown -R runner:runner /actions-runner

COPY runner-image-contract.sh /usr/local/bin/crf-runner-image-contract
RUN chmod 0755 /usr/local/bin/crf-runner-image-contract \
 && /usr/local/bin/crf-runner-image-contract >/usr/share/ci-runner-farm-image-contract.json

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["/usr/local/bin/crf-runner-image-contract"]
CMD ["./run.sh"]
