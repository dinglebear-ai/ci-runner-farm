# Linux Service Packaging

The distributed Linux stack ships independently from the legacy Unraid plugin as a native, distribution-tagged service bundle.

## Bundle contents

A bundle contains:

- self-contained OTP release for `crf_controller`;
- release-mode `crf-scheduler`;
- release-mode `crf-node`;
- `crf-scaleset` Go sidecar;
- hardened controller and node systemd units;
- strict controller, node, and runner-manifest examples;
- `BUILD-INFO` with version, platform, git SHA, source date epoch, and toolchain identity;
- `SHA256SUMS` covering every regular file in the bundle;
- an installer that supports a fake `DESTDIR` and never enables or starts services.

## Platform identity

OTP releases are native artifacts. The builder therefore identifies the build OS distribution, distribution version, and architecture instead of advertising a generic Linux archive.

Example from DOOKIE:

`ci-runner-farm-distributed-1.9.2-linux-ubuntu-26.04-x86_64.tar.gz`

A bundle built on Ubuntu must not be assumed compatible with Fedora or another distribution. Release automation should build and test the target distribution families explicitly.

## Installation layout

The installer places immutable release payloads under:

`/opt/ci-runner-farm/releases/<version>-<platform>/`

and atomically updates the relative symlink:

`/opt/ci-runner-farm/current`

Systemd units reference only the `current` path. Configuration remains external under `/etc/ci-runner-farm`, durable state under `/var/lib/ci-runner-farm`, runtime sockets under `/run/ci-runner-farm`, and logs under `/var/log/ci-runner-farm`.

The installer does not create an active `controller.json` or `node.env`. It installs examples under `/usr/share/doc/ci-runner-farm-distributed/examples` and requires the operator or provisioning system to install real credentials/configuration deliberately.

## Service semantics

The controller unit uses systemd hardening including private runtime/state/log directories, a 0077 umask, `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, and restricted address families. It intentionally does not use `MemoryDenyWriteExecute`, because the BEAM JIT requires executable memory.

The node unit intentionally uses `KillMode=process`. Restarting the node agent must not blindly terminate an already-running GitHub runner child, because that child may own a live job and the new agent generation can adopt the surviving durable placement. Explicit placement cancellation still requires the tracked Unix process-group / Windows Job Object hardening before production.

## Building

Run:

`scripts/build-distributed-bundle.sh`

The builder uses the repository `VERSION`, builds Rust with `--locked --release`, builds the Go sidecar with `-trimpath`, assembles the OTP release, writes checksums/build metadata, and emits a distribution-tagged tarball under `build/distributed/`.

## Verification

Run:

`scripts/verify-distributed-bundle.sh <bundle.tar.gz>`

The verifier:

1. checks every file against `SHA256SUMS`;
2. rejects absolute or bundle-escaping symlinks;
3. executes `--version`/`version` on the Rust and Go binaries;
4. executes a one-off command through the packaged OTP release;
5. validates installer shell syntax;
6. installs the bundle twice into a temporary `DESTDIR`;
7. verifies the versioned release/current-symlink layout and systemd/example files;
8. proves the installer did not create active configuration.

CI runs this build+verification smoke on Linux in the distributed-core job.

## Current proof

On 2026-08-19, DOOKIE built and verified a clean 33,546,551-byte Ubuntu 26.04 x86_64 bundle from `b297b04d53f477655e59bfdab1f8e59105abc8a6`; `BUILD-INFO` records `GIT_DIRTY=false`. The same SHA also passed the hosted Ubuntu bundle build/verification lane. These were artifact/fake-root installation proofs only; nothing was installed into or started on the live host root.
