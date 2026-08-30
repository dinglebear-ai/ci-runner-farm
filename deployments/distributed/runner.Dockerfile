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
 && apt-get install -y --no-install-recommends apt-transport-https build-essential ca-certificates clang cmake curl file gettext-base git gnupg gosu inotify-tools iptables jq libicu74 libssl3 libssl-dev lld locales lsb-release mold nodejs npm openssh-client php-cli pkg-config python3 python3-pip python3-venv ripgrep rsync sudo uidmap unzip wget xz-utils zip zstd \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1001 --shell /bin/bash runner \
 && install -d -o runner -g runner /actions-runner /actions-runner/_work \
 && printf 'runner ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# Docker and GitHub tooling ships from signed upstream repositories rather than
# the Ubuntu archive. The daemon is installed but remains stopped by default;
# only an explicitly privileged, START_DOCKER_SERVICE=true runner starts its
# container-local daemon. No host Docker socket is mounted.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    arch="$(dpkg --print-architecture)"; \
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"; \
    curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
      > /etc/apt/sources.list.d/docker.list; \
    curl -fsSL --retry 3 https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli.gpg; \
    chmod a+r /etc/apt/keyrings/githubcli.gpg; \
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      containerd.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin gh; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version; \
    dockerd --version; \
    docker buildx version; \
    docker compose version; \
    gh --version

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
