# Cargo-native remote build server

## Outcome

Extend CI Runner Farm with an opt-in, Cargo-only remote-build service. A
developer runs a local `crf-build` client; it creates a deterministic source
bundle, authenticates to the Unraid host, submits an allowlisted Cargo
operation, streams structured progress, and downloads a verified artifact
bundle. The existing GitHub Actions runner farm remains independent and fully
compatible.

This is deliberately not a generic remote shell, SSH replacement, or arbitrary
container execution API. Cargo has compiler-wrapper configuration, but it has
no protocol for sending an entire `cargo build` to another machine. The product
therefore needs its own narrow client/server protocol. Distributed `sccache`
is a possible later optimization for compilation; it is not the v1 execution
engine.

## Locked decisions

- V1 exposes only `build`, `test`, and `clippy`; it never accepts a shell
  command, a Dockerfile, a host path, `cargo run`, or `cargo install`.
- A submitted build must use a lockfile and runs Cargo with `--locked` by
  default. Any future unlock policy is explicit and off by default.
- The server performs each build in a fresh, unprivileged worker container. It
  must not use the runner fleet's privileged Docker-in-Docker configuration,
  host Docker socket, runner workspace, or GitHub token.
- V1 is single-host: one Unraid server schedules its own bounded worker pool.
  It is a remote build server, not a multi-node distributed-execution system.
- The host-installed Rust controller is trusted and has narrowly scoped Docker
  authority to create labeled workers; it never runs in a container with the
  Docker socket. Workers never receive that authority.
- The external endpoint terminates TLS and verifies mTLS directly in the
  controller. A client generates and retains its own private key, submits a
  CSR, and receives only a short-lived certificate chain. Pairing is a
  high-entropy, rate-limited, expiry-bound, atomically single-use code shown
  once in the authenticated Unraid UI. Tokens, private keys, pairing codes,
  and source archives never appear in cfg files, status APIs, or logs.
- The service is disabled by default and defaults to no worker-network access.
  `network=none` is the only V1 isolation claim. Any later registry profile
  requires a tested dedicated egress proxy or firewall policy; until then the
  UI calls it “network enabled,” not “registry-only.”
- Build caches are keyed by a server-computed input manifest, Cargo lockfile,
  canonical effective invocation, target/custom-target digest, selected
  features/profile, Cargo/Clippy version, worker image digest, native package
  manifest, sanitized environment/config policy, and policy version. Never
  share writable Cargo Home, build, or target state between jobs.
- A submitted source snapshot is authoritative; it is not promised to be
  equivalent to an arbitrary local checkout. V1 rejects private registries and
  Git dependencies and has no worker-visible registry credentials.

## Product boundary and success criteria

### Client experience

```text
crf-build enroll https://builder.example.ts.net <one-time-code>
crf-build build --release --package ci-runner-farm
crf-build test --workspace
crf-build clippy --workspace -- -D warnings
```

The client discovers the workspace, rejects unsupported invocation shapes
locally, reads `.gitignore` plus a service-owned exclusion list, creates a
canonical tar+zstd source archive, and shows an operation ID. It streams server
events (`queued`, `preparing`, `building`, `uploading`, `complete`, `failed`),
then writes artifacts and a JSON manifest into an explicit local output
directory. It never silently replaces the local `cargo` executable.

The protocol represents package/workspace/exclude, profile, target, feature,
and permitted Rust/Clippy argument selections as typed fields; it does not
forward an argv string. In particular, `clippy -- -D warnings` is modeled as a
restricted lint-argument list. The client force-includes required Cargo files,
reports exclusions, refuses a missing `Cargo.toml`/`Cargo.lock`, and generates
a local CSR during enrollment. It extracts results into a new 0700 temporary
directory, validates only regular files/directories against the authenticated
result manifest, then atomically renames a new output directory.

### Server experience

The Unraid UI adds a **Remote builds** tab and a status card: enabled state,
listener URL/fingerprint, worker capacity, queued/running operations, cache
usage and hit rate, egress mode, latest failures, enrolled-client count, and
certificate expiry. Operators can pair/revoke clients, rotate the local CA,
clear caches by scope, drain workers, and stop the service.

### Acceptance criteria

- A Linux Rust workspace can remotely build, test, and run Clippy using the
  selected pinned toolchain, returning exit status, logs, and declared output.
- The same input manifest resolves to a cache hit; changing `Cargo.lock`,
  toolchain image digest, target, policy version, or an included source file
  never reuses that result.
- Result reuse applies only to successful `build` operations. `test` always
  executes and `clippy` begins uncached in V1; a prior validation can be shown
  as history but never represented as a new test execution.
- A public/non-enrolled client, expired/revoked client certificate, malformed
  archive, archive traversal entry, unsupported Cargo option, oversized upload,
  or exhausted quota is rejected before worker creation.
- A worker can neither reach the Docker socket nor access another operation's
  source, output, or writable cache. A worker crash or server restart leaves no
  runnable orphan and preserves only valid completed artifacts.
- Existing runner start/stop/autoscaling behavior and its current tests keep
  passing with remote builds disabled.

## Architecture

```text
crf-build CLI
  |  mTLS + framed HTTPS (source archive, request metadata)
  v
remote-build-server (Rust, host-managed controller binary)
  |-- enrollment / certificate revocation / audit log
  |-- request validator + content-addressed input store
  |-- bounded FIFO scheduler
  |-- event + artifact API
  `-- Docker worker manager
        `-- fresh cargo-worker container per operation
              read-only toolchain image + readonly source input
              private Cargo Home + work/target/build directories
              CPU/memory/PID/disk/time limits, no Docker socket, no privilege
```

### Protocol

Use a versioned `crf.remote-build.v1` protocol described by Rust request and
response types in a shared crate. HTTP endpoints are intentionally limited to:

- `POST /v1/enrollments`: consumes a pairing code plus a client CSR over TLS
  and returns a client certificate chain and server identity pin. It never
  returns or generates a client private key.
- `POST /v1/builds`: mTLS client uploads a bounded archive plus a typed build
  request and idempotency key. The server persists the client-scoped key and
  body digest transactionally, then returns an immutable operation ID.
- `GET /v1/builds/{id}/events`: Server-Sent Events with sequence numbers and
  resume support; logs are UTF-8 text with explicit truncation metadata.
- `GET /v1/builds/{id}`: typed status/result record, restricted to the
  submitting client or an administrator.
- `GET /v1/builds/{id}/artifacts`: a manifest whose SHA-256 values are bound to
  the authenticated result response, followed by a tar+zstd artifact archive
  only after a successful build.

The request includes operation (`build|test|clippy`), workspace/package/target
selectors, Cargo profile, typed feature and lint selections, required toolchain
ID, and an input manifest. The server re-computes the manifest while unpacking.
It runs an absolute Cargo binary with controlled `CARGO_HOME`, `HOME`, `PATH`,
`TMPDIR`, `CARGO_TARGET_DIR`, and `CARGO_BUILD_BUILD_DIR`, and rejects archive
`.cargo/config*` until an explicit, server-owned allowlist exists. It rejects
`--config`, `--manifest-path`, `--target-dir`, arbitrary environment input,
unsupported targets/profiles/features, target runners/linkers, and unbounded
jobs. It rejects
duplicate archive entries, absolute paths, symlinks escaping the source root,
hard links/devices/FIFOs, non-UTF-8 or NUL paths, excessive entry/path/depth or
uncompressed-byte limits, a missing or mismatched manifest, and all source
paths outside the declared root. Upload quota is reserved before the body is
streamed to a server-owned temporary file; partial uploads are always removed.

### Worker policy

The scheduler chooses only pre-approved worker images. Each image has a pinned
Rust/Cargo version and digest and contains the native linker/build packages
needed by the selected target. The server creates workers with:

- a read-only root filesystem and a non-root UID;
- a read-only source mount; a per-operation tmpfs work and target directory;
- no host Docker socket, `--privileged`, added capabilities, host networking,
  or arbitrary bind mounts;
- `cap-drop=ALL`, `no-new-privileges`, default seccomp/AppArmor, and no host
  PID/IPC/user namespace, devices, or unconfined security profile;
- explicit CPU, hard-memory/swap, PID, ulimit, wall-clock, and log limits;
  startup refuses the requested mode if Docker/host capability checks cannot
  enforce it;
- a per-operation network namespace. The default profile has no egress; a
  future enabled-network profile must prove its egress enforcement.

The scheduler never invokes Cargo from the HTTP handler. It persists an
operation row before work begins, uses a bounded concurrency semaphore, starts
the container from a reconciler loop, and records a state machine
`accepted → queued → assigned(generation) → starting → running → terminal`.
On restart it inspects/removes only matching labeled containers and marks every
possibly-started operation `interrupted`; a client retry creates a linked new
operation rather than re-executing unknown build-script side effects. SSE uses
a durable, client-scoped, sequence-numbered event log with `Last-Event-ID`,
retention/gap behavior, heartbeats, and bounded backpressure.

### Controller deployment and operations

The controller binds only to the explicitly selected address and terminates
TLS/mTLS itself. A reverse proxy is supported only as TLS pass-through in V1;
if TLS termination is added later, the backend must be unreachable except from
that proxy and consume a cryptographically authenticated client identity, never
a user-supplied forwarding header. Startup preflight verifies controller and
worker-image checksums/digests, certificate/key coherence, dedicated data-root
ownership/mode, listener availability, Docker cgroup/LSM capability, and the
applied worker security contract. It fails closed rather than displaying a
configured-but-ineffective isolation mode.

Remote data lives under a separately configured, canonicalized, 0700 root with
operation, registry snapshot, result, artifact, and audit subdirectories. Its
guard and cleanup commands are independent of `CACHE_ROOT`; cleanup is label-
and generation-scoped and must not share the runner network/firewall tag.

### Cache and artifacts

Keep Cargo registry/git caches separate from compiled artifacts. V1 permits
only server-owned, prewarmed registry/mirror snapshots; each worker gets a
private Cargo Home and never sees a global writable `CARGO_HOME`, credentials,
or Git auth. The no-egress mode requires a prewarmed or validated vendored
fixture and is tested with `--frozen`; Cargo may otherwise resolve differently
offline. Both Cargo build and target directories are operation-owned. The first
release uses content-addressed whole-result reuse only for successful `build`
operations with exactly matching cache keys. It must checksum every artifact,
select final artifacts by parsing Cargo `--message-format=json`
`compiler-artifact` messages (not by guessing `target/release`), store a
manifest with filenames and sizes, enforce retention/quota, and delete only
paths proved beneath the dedicated remote-build root.

Do not turn on `sccache-dist` in this milestone. If later enabled, it needs a
proper HTTPS scheduler, client/server authentication, toolchain packaging, and
its own status/telemetry; it must remain separately configurable from remote
execution.

## Repository layout

```text
remote-build/
  Cargo.toml                       # Rust workspace and locked dependencies
  crates/protocol/                 # versioned wire types and validation
  crates/client/                   # `crf-build` CLI
  crates/server/                   # Axum/rustls service and scheduler
  crates/worker/                   # worker policy/image metadata helpers
  images/cargo-worker/Dockerfile   # pinned, multiarch Rust worker image
  tests/                           # protocol, integration, adversarial fixtures
src/usr/local/emhttp/plugins/ci-runner-farm/
  bin/remote-build-server          # CI-built controller binary, executable
  include/remote-build.sh          # dedicated lifecycle/config wrapper
  include/runner-farm.sh           # coordinated status/start/stop only
  include/exec.php                 # CSRF-protected administrative actions
  RunnerFarmRemoteBuild.page       # operator UI
  remote-build.default.cfg          # independent defaults, no secrets
  event/{docker_started,stopping_docker}
```

The existing `RunnerFarmImage.page` Rust preset stays for GitHub Actions
runners. The remote service uses a separately built worker image so a runner
image change cannot alter the remote-build trust boundary.

The `crf-build` client is a separate versioned release artifact, with checksums
and a published client/server protocol compatibility matrix. It is never hidden
inside the Unraid plugin package. The controller is built in CI for every
supported Unraid architecture; installation explicitly sets executable bits and
verifies binary checksum plus worker-image digest before enabling the service.

## Delivery plan (proposed epic and child beads)

The Beads environment inherited by this checkout points at the unrelated
`syslog-mcp` database, so these are intentionally not created there. Once this
repository has a project-local tracker, create the epic **Add Cargo-native
remote build service** and import the five children below in dependency order.

### 1. Define the v1 protocol, policy, and Rust workspace

**What:** Add the `remote-build` Cargo workspace, `protocol` crate, canonical
archive/input-manifest algorithm, typed operation states, configuration schema,
and an operator/developer protocol document.

**Locked decisions:** Honor every locked decision above. Make protocol version,
archive canonicalization, input limits, idempotency, and lockfile mandatory.
Define the exact cache-key serialization and effective invocation. Give every
state transition an operation ID, timestamp, terminal reason, worker generation,
and bounded log metadata. Define CSR-only enrollment, pairing replay/race,
serial/SPKI client identity, CRL `nextUpdate` fail-closed behavior, and
per-request authorization including SSE/artifact access.

**Files:** `remote-build/Cargo.toml`, `remote-build/crates/protocol/**`,
`remote-build/tests/protocol/**`, `docs/remote-build-protocol.md`.

**Testing:** Deterministic manifest/archive fixtures; identical tree equals
same digest; modifications change digest; traversal/duplicate/absolute/device,
hard-link, compressed/uncompressed-limit, non-UTF-8, and symlink entries fail;
serde/protocol compatibility snapshots; request-policy table tests; one
enrollment succeeds under pairing-code replay/race; no private key crosses HTTP;
revocation/expired CRL fails every endpoint.

**Validation:** No network, Docker, or Unraid plugin changes in this bead.

### 2. Implement the authenticated `crf-build` client

**What:** Build the client CLI from the shared protocol. Implement secure local
credential storage and CSR generation, workspace discovery, canonical archive
upload/idempotency, event reconnect, result rendering, and explicit artifact
extraction.

**Dependencies:** 1.

**Files:** `remote-build/crates/client/**`,
`remote-build/tests/client/**`, `docs/remote-build-client.md`.

**Testing:** Invocation matrix for typed package/workspace/features/target and
Clippy lint args; rejected unsupported flags/config/env; archive exclusions
and mandatory-file failures; interrupted upload/idempotency/event reconnect;
mTLS hostname/pin mismatch; unsafe artifact path/link rejection into an
existing mutable output directory; terminal failures retain logs and return
Cargo-compatible nonzero status.

**Validation:** The CLI cannot execute shell text from the server or write
outside its explicit output directory.

### 3. Implement the remote-build server, scheduler, and hardened worker

**What:** Implement rustls/mTLS enrollment and revocation, persisted operation
state, bounded upload handling, scheduler/reconciler, SSE/status/artifact APIs,
separate registry/result/artifact stores, and a pinned unprivileged
cargo-worker image. The controller owns Docker calls; workers are separate,
labeled, and never use runner-farm `build_args`, names, networks, firewall tag,
cache root, or workspace.

**Dependencies:** 1.

**Files:** `remote-build/crates/server/**`, `remote-build/crates/worker/**`,
`remote-build/images/cargo-worker/**`, `remote-build/tests/server/**`.

**Testing:** Enrollment/revocation/expiry and open-stream termination;
authorization isolation; archive/zstd-bomb attacks; scheduler capacity,
cancellation, state-fencing and restart recovery; exact `docker inspect`
security-contract assertions; no-host-mount/no-Docker-socket worker assertions;
network-none and enabled-network bypass probes; result-cache key matrix;
uncached test execution; JSON artifact selection/checksums/retention; Docker-
backed happy-path build/test/clippy integration.

**Validation:** No request reaches a worker until authentication, validation,
quota, and policy checks complete. Workers run unprivileged with the intended
network profile and cannot see another operation's writable state.

### 4. Integrate service lifecycle and Unraid management UI

**What:** Add a disabled-by-default, independent remote-build config and
secure file-backed CA/pairing material; add service start/stop/reconcile hooks,
CSRF-protected admin actions, and the Remote builds UI. Register its tab as
`Menu="RunnerFarm:4"`. Keep runner-farm and remote-build state/logs distinct.

**Dependencies:** 3.

**Files:** `src/usr/local/emhttp/plugins/ci-runner-farm/include/remote-build.sh`,
`include/runner-farm.sh`, `include/exec.php`, `RunnerFarm.page`,
`RunnerFarmRemoteBuild.page`, `RunnerFarmSettings.page`,
`remote-build.default.cfg`, `event/*`, `tests/remote-build-controls.sh`,
`tests/remote-build-config-parity.sh`.

**Testing:** Independent configuration parity; disabled service performs no Docker work;
secret writes are mode 0600 and absent from cfg/status/log payloads; CSRF and
input validation for every admin action; safe-path guards cover every cache and
result cleanup path; runner autoscaling regression suite remains green.

**Validation:** Turning off stops only remote workers/service and preserves
metadata by default. A prior explicit, audited purge action is required for
irreversible removal. Uninstall stops remote workers/service and preserves its
state/credentials by default; it never stops GitHub runners unexpectedly.

### 5. Package, document, and verify the release

**What:** Add reproducible multiarch controller/worker-image and separate
client-release builds to CI, bind their checksums/digests/SBOM or provenance to
the release, extend raw deployment with a complete explicit runtime manifest,
document setup/security/backup/rollback, and run end-to-end acceptance tests on
Unraid.

**Dependencies:** 2, 4.

**Files:** `.github/workflows/{lint,package-plugins,release}.yml`,
`build-plg.sh`, `deploy.sh`, `ci-runner-farm.plg`, `README.md`,
`src/usr/local/emhttp/plugins/ci-runner-farm/README.md`,
`docs/remote-build-operations.md`.

**Testing:** Locked Cargo dependency checks; Rust fmt/clippy/test; shell/PHP
lint; reproducible package check; controller/client architecture builds and
compatibility test; package-content executable/checksum/no-secret assertion;
install/upgrade/uninstall smoke test; real CSR enrollment and remote
build/test/clippy; denied/revoked-client and cache-clear tests; existing plugin
test suite.

**Validation:** A release package contains every executable with explicit
permissions and checksums, never ships private keys, and documents rollback to
the current runner-only release.

## Rollout and rollback

1. Ship the protocol/client/controller behind a hidden development flag and use
   a dedicated test Unraid host or isolated Docker environment. First prove a
   no-egress, vendored/prewarmed fixture with Docker `network=none`.
2. Release the plugin with Remote builds disabled. Verify no new listener,
   container, secret, or cache directory exists until an operator enables it.
3. Enable for one enrolled developer and one Rust workspace, with worker count
   one and no egress. Validate artifacts and failure paths.
4. Enable the selected registry profile only after the no-egress path works;
   expand capacity gradually while checking host resource and cache metrics.
5. Roll back by draining/stopping remote workers and disabling the service.
   Preserve operation metadata/logs for diagnosis; make cache/artifact deletion
   a separately confirmed, path-guarded action. The existing CI runner fleet is
   unaffected throughout.

## Risks and non-goals

- Running user-provided Rust build scripts is code execution. Container limits
  reduce blast radius but do not make untrusted multi-tenant execution safe;
  v1 is for enrolled, trusted developer projects.
- Perfect network allowlisting is host- and registry-dependent. Treat egress as
  a measurable policy with an explicit warning, not a claim of universal
  isolation.
- Cross-platform targets, custom target specs, private registries/Git
  dependencies, build scripts requiring hardware, and remote IDE integration
  are deferred until the Linux host path is robust.
- The current remote `sccache` setup needs separate HTTPS/trust work. It must
  not be implicitly enabled by this feature.

## Sources

- Existing runner lifecycle and safe cache handling:
  `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`.
- Existing Rust preset and local-cache policy:
  `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page` and
  `tests/rust-preset.sh`.
- Existing packaging/release model: `build-plg.sh`, `ci-runner-farm.plg`, and
  `.github/workflows/package-plugins.yml`.
- Cargo configuration reference: <https://doc.rust-lang.org/cargo/reference/config.html>.
- sccache distributed-compilation quickstart:
  <https://github.com/mozilla/sccache/blob/main/docs/DistributedQuickstart.md>.
- Docker Engine security guidance: <https://docs.docker.com/engine/security/>.
- Cargo build/cache/configuration behavior:
  <https://doc.rust-lang.org/cargo/commands/cargo-build.html>,
  <https://doc.rust-lang.org/cargo/reference/build-cache.html>, and
  <https://doc.rust-lang.org/cargo/reference/config.html>.
- Cargo build-script and artifact protocol behavior:
  <https://doc.rust-lang.org/cargo/reference/build-scripts.html> and
  <https://doc.rust-lang.org/cargo/reference/external-tools.html>.
- Docker network, tmpfs, and resource constraints:
  <https://docs.docker.com/engine/network/drivers/none/>,
  <https://docs.docker.com/engine/storage/tmpfs/>, and
  <https://docs.docker.com/engine/containers/resource_constraints/>.
- rustls client verification/CRL APIs:
  <https://docs.rs/rustls/latest/rustls/server/struct.WebPkiClientVerifierBuilder.html>.
