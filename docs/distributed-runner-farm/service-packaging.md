# Service Packaging

The controller and Linux node ship together as a Linux bundle. The portable Windows node ships as a separate x86_64 ZIP; the controller remains a Linux OTP release.

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

`/opt/ci-runner-farm/releases/<version>-<platform>-<git-sha>/`

and atomically updates the relative symlink:

`/opt/ci-runner-farm/current`

Systemd units reference only the `current` path. Configuration remains external under `/etc/ci-runner-farm`, durable state under `/var/lib/ci-runner-farm`, runtime sockets under `/run/ci-runner-farm`, and logs under `/var/log/ci-runner-farm`.

The installer does not create an active `controller.json` or `node.env`. It installs examples under `/usr/share/doc/ci-runner-farm-distributed/examples` and requires the operator or provisioning system to install real credentials/configuration deliberately.

## Service semantics

The controller unit uses systemd hardening including private runtime/state/log directories, a 0077 umask, `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, and restricted address families. It intentionally does not use `MemoryDenyWriteExecute`, because the BEAM JIT requires executable memory.

The node unit intentionally uses `KillMode=process`. Restarting the node agent must not blindly terminate an already-running GitHub runner or container, because that runtime may own a live job and the new agent generation must reconcile the surviving durable placement. Native runners are adopted through persisted PID/start identity; container runners are rediscovered through the configured local adapter and persisted immutable container ID. Explicit native cancellation uses the tracked Unix process group / Windows Job Object, while container cancellation carries the expected immutable container ID so a reused name cannot target a newer runtime.

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

## Windows node package

On native Windows, run `scripts/build-distributed-windows-node.ps1`. The archive contains `crf-node.exe`, a strict environment example, the pinned runner manifest example, and `Install-CrfNodeService.ps1`.

The installer requires an explicit node binary and completed environment file. It copies both into protected Program Files/ProgramData locations, rejects malformed or duplicate environment keys, registers `CiRunnerFarmNode` under the low-privilege `LocalService` identity, and leaves startup set to Manual. It never starts the service. The binary's `--windows-service` mode registers directly with the Windows Service Control Manager and maps SCM Stop to the same cooperative shutdown flag used by the console daemon, preserving durable runner adoption across agent restarts.

The hosted Windows distributed-core lane compiles the real service entry point,
builds the release ZIP, parses the installer with PowerShell's AST parser, and
behaviorally installs/reinstalls a disposable service with ACL, registry,
failure-policy, rollback-injection, and observable error-log assertions.
PowerShell 5.1 and PowerShell 7 are supported: service creation avoids embedded
native-argv quote loss by setting the exact quoted SCM `ImagePath` through the
service registry before start. Live Steamy installation runs as LocalService
and has registered with the Dookie controller; a real GitHub job lifecycle is
still part of final acceptance.

`/opt/ci-runner-farm/current/bin/crf-operator-status` uses the release's authenticated local RPC channel to print a redacted snapshot of nodes, resources, offers, placements, orphan state, configured pools, peer authorization counts, and sidecar health. It also exposes generation-fenced `drain`/`undrain` and `force-abandon PLACEMENT_ID --force`. The fixed command grammar rejects unsafe identifiers and never includes JIT descriptors, idempotency keys, certificate bytes, or controller credentials.

## Unraid node layout

The optional Unraid container node is not installed under `/opt` and never runs
from flash. Its live layout is:

- `/mnt/cache/appdata/ci-runner-farm/distributed-node/bin` — node binary;
- `/mnt/cache/appdata/ci-runner-farm/distributed-node/status/controller.json` —
  optional mode-0600 secret-free controller projection, atomically refreshed by
  the authenticated node session;
- `config` — mode-restricted node environment and mTLS material;
- `state` and `logs` — durable ZFS-backed recovery and diagnostics;
- `/var/run/ci-runner-farm-distributed-node` — transient PID only.

The plugin's `docker_started` and `stopping_docker` events call the
cache-resident lifecycle wrapper only when it exists. Removing the optional node
leaves classic plugin behavior unchanged.

## Current proof

On 2026-08-21, Dookie built a clean Ubuntu 26.04 x86_64 bundle from
`d76c43f45710f68e3dc8ec0d9d240a981d362c45`; `BUILD-INFO` records
`GIT_DIRTY=false`, Go 1.25.3, Elixir 1.20.3/OTP 29, and Rust 1.97.1. The
controller is installed on Dookie, and Linux native nodes on Dookie, Squirts,
and Steamy WSL, a Windows native node on Steamy, and a cache-resident container
node on Tootie all register through mTLS. This proves packaging, service start,
and five-node heartbeat; final real-job scheduling remains gated separately.
