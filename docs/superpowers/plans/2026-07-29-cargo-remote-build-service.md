# Cargo-Native Remote Build Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend CI Runner Farm with a disabled-by-default, Cargo-only remote build service that securely runs trusted Rust workspaces on an Unraid host and returns build artifacts or test/lint results.

**Architecture:** A locally installed Rust controller terminates mTLS, validates a bounded source archive, records operations in SQLite, and creates one isolated Docker worker per operation. A separate `crf-build` client submits only typed `build`, `test`, or `clippy` requests. The existing GitHub Actions runner fleet remains untouched: it has separate names, labels, networks, config, roots, locks, and lifecycle commands.

**Tech Stack:** Rust stable, Axum, rustls, SQLite, Docker Engine, Bash/PHP Unraid plugin pages, `tar` + zstd, Cargo JSON messages.

## Global Constraints

- V1 accepts trusted enrolled developers only; it is never a public or multi-tenant sandbox.
- V1 accepts only `build`, `test`, and `clippy`; it never accepts shell text, Dockerfiles, host paths, arbitrary Cargo config, arbitrary environment variables, `cargo run`, or `cargo install`.
- Every operation must include `Cargo.toml`, `Cargo.lock`, and a Cargo-vendored dependency tree. The controller generates the only Cargo config and runs `cargo --frozen --offline`.
- The controller runs as a host-installed binary with Docker authority. Workers have no Docker socket, no host networking, no privilege, no added capabilities, and no arbitrary bind mounts.
- The worker create contract requires numeric non-root UID/GID, read-only root, `cap-drop=ALL`, `no-new-privileges`, default seccomp/AppArmor, `network=none`, explicit CPU/memory/PID/time limits, and a read-only source mount.
- `CARGO_HOME`, `CARGO_TARGET_DIR`, `CARGO_BUILD_BUILD_DIR`, `HOME`, `TMPDIR`, and `PATH` are controller-owned per operation. A worker never sees registry credentials, Git credentials, or a writable global Cargo Home.
- Build scripts execute native code. Do not enable this service for untrusted repositories. Refuse multi-client mode unless the host reports the configured user-namespace/LSM isolation capability.
- V1 has no result cache, no durable SSE replay, no enabled-network profile, no private registry/Git dependency support, no `sccache-dist`, and no UI CA rotation/purge actions.
- Remote-build configuration lives in `/boot/config/plugins/ci-runner-farm/remote-build.cfg`; it is not added to `default.cfg`, `CFG_KEYS`, or the runner-farm config-parity test.
- Remote data lives under a dedicated configured subdirectory such as `/mnt/cache/ci-runner-farm/remote-build`, never under the runner `CACHE_ROOT`.
- Build artifacts are selected from Cargo `--message-format=json` `compiler-artifact` records. Test and Clippy operations return status and logs only.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `remote-build/Cargo.toml` | Locked Rust workspace for protocol, controller, client, and integration tests. |
| `remote-build/crates/protocol/src/lib.rs` | Versioned request/response/state types and canonical request digest. |
| `remote-build/crates/protocol/src/archive.rs` | Strict archive inventory and extraction validation. |
| `remote-build/crates/controller/src/main.rs` | Controller process startup, signal handling, and route wiring. |
| `remote-build/crates/controller/src/store.rs` | SQLite migrations, operation state machine, reservations, and audit records. |
| `remote-build/crates/controller/src/worker.rs` | Exact Docker create/inspect/reconcile contract. |
| `remote-build/crates/controller/src/api.rs` | mTLS-protected enrollment, submission, status, logs, and artifact endpoints. |
| `remote-build/crates/client/src/main.rs` | `crf-build` CLI, local key/CSR, tracked-file archive, polling, and safe extraction. |
| `remote-build/images/cargo-worker/Dockerfile` | Pinned Rust/Cargo/Clippy worker image. |
| `src/usr/local/emhttp/plugins/ci-runner-farm/include/remote-build.sh` | Single-instance Unraid lifecycle wrapper and guarded data-root operations. |
| `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmRemoteBuild.page` | Registered Remote builds status page; renders data as inert text. |
| `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php` | CSRF plus authenticated-admin gate and action-specific routing to `remote-build.sh`. |
| `tests/remote-build-controls.sh` | Shell regression tests for config, labels, paths, lifecycle, and permissions. |

## Interfaces

```rust
pub const PROTOCOL_VERSION: u16 = 1;

pub enum OperationKind { Build, Test, Clippy }
pub enum Selector { Workspace, Package(String) }
pub enum BuildProfile { Debug, Release }
pub struct BuildRequest {
    pub protocol_version: u16,
    pub request_id: uuid::Uuid,
    pub operation: OperationKind,
    pub selector: Selector,
    pub profile: BuildProfile,
    pub source_sha256: [u8; 32],
}
pub enum OperationState {
    Accepted, Queued, Assigned, Starting, Running,
    Succeeded, Failed, Cancelled, Interrupted,
}
```

The controller exposes `POST /v1/enrollments`, `POST /v1/builds`, `GET /v1/builds/{id}`, `GET /v1/builds/{id}/logs`, and `GET /v1/builds/{id}/artifacts`. Every endpoint except enrollment requires mTLS and authorizes the client certificate serial against the operation owner. `GET /artifacts` returns 409 unless the operation is a successful `build`.

### Task 1: Create the protocol workspace and failing policy tests

**Files:**
- Create: `remote-build/Cargo.toml`
- Create: `remote-build/crates/protocol/Cargo.toml`
- Create: `remote-build/crates/protocol/src/lib.rs`
- Create: `remote-build/crates/protocol/src/policy.rs`
- Create: `remote-build/crates/protocol/tests/policy.rs`

**Interfaces:**
- Produces: `BuildRequest::validate() -> Result<(), PolicyError>` and `canonical_request_sha256(&BuildRequest) -> [u8; 32]`.

- [ ] **Step 1: Write policy tests before types**

```rust
#[test]
fn test_rejects_wrong_version_and_empty_package() {
    let mut request = fixture_request(OperationKind::Build);
    request.protocol_version = 2;
    assert_eq!(request.validate(), Err(PolicyError::UnsupportedVersion(2)));
    request.protocol_version = PROTOCOL_VERSION;
    request.selector = Selector::Package(String::new());
    assert_eq!(request.validate(), Err(PolicyError::EmptyPackage));
}

#[test]
fn test_canonical_digest_is_independent_of_struct_allocation() {
    assert_eq!(canonical_request_sha256(&fixture_request(OperationKind::Build)),
               canonical_request_sha256(&fixture_request(OperationKind::Build)));
}
```

- [ ] **Step 2: Run the failing test**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-protocol --test policy`

Expected: FAIL because the workspace and protocol crate do not exist.

- [ ] **Step 3: Add only typed V1 request validation**

```rust
impl BuildRequest {
    pub fn validate(&self) -> Result<(), PolicyError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(PolicyError::UnsupportedVersion(self.protocol_version));
        }
        if matches!(&self.selector, Selector::Package(name) if name.is_empty()) {
            return Err(PolicyError::EmptyPackage);
        }
        Ok(())
    }
}
```

Serialize the fields in declaration order with `postcard` or a manually
specified byte format before hashing; do not hash debug output or a map.

- [ ] **Step 4: Run format and protocol tests**

Run: `cargo fmt --manifest-path remote-build/Cargo.toml --check && cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-protocol`

Expected: PASS.

- [ ] **Step 5: Commit the independently testable protocol base**

```bash
git add remote-build/Cargo.toml remote-build/crates/protocol
git commit -m "feat(remote-build): add versioned request protocol"
```

### Task 2: Enforce a safe, vendored source archive

**Files:**
- Create: `remote-build/crates/protocol/src/archive.rs`
- Create: `remote-build/crates/protocol/tests/archive.rs`
- Modify: `remote-build/crates/protocol/src/lib.rs`

**Interfaces:**
- Consumes: `BuildRequest` from Task 1.
- Produces: `validate_and_unpack(reader, destination) -> Result<ArchiveInventory, ArchiveError>`.

- [ ] **Step 1: Write malicious-archive tests**

```rust
#[test]
fn test_rejects_links_pax_and_untracked_secrets() {
    assert_matches!(unpack(entry("link", EntryType::Symlink)), Err(ArchiveError::Link));
    assert_matches!(unpack(entry(".env.production", EntryType::Regular)), Err(ArchiveError::ForbiddenPath(_)));
    assert_matches!(unpack(entry("vendor/.cargo-checksum.json", EntryType::Regular)), Ok(_));
}
```

- [ ] **Step 2: Run the failing archive corpus**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-protocol --test archive`

Expected: FAIL because archive validation is absent.

- [ ] **Step 3: Implement default-deny inventory and extraction**

Accept only UTF-8 relative regular files/directories from Git-tracked paths plus
`Cargo.toml`, `Cargo.lock`, `vendor/**`, and the generated source inventory.
Reject `.git`, nested repositories, `.env*`, `target/**`, credentials/key
suffixes, links, PAX/GNU sparse extensions, devices, FIFOs, duplicate or Unicode
normalization-colliding paths. Count compressed bytes before unpacking and entry,
path-depth, path-length, and uncompressed bytes during unpacking. Create every
destination below a newly created 0700 directory using no-follow traversal.

- [ ] **Step 4: Verify the generated Cargo config is the only config**

Write this controller-owned file after extraction:

```toml
[source.crates-io]
replace-with = "crf-vendor"
[source.crf-vendor]
directory = "/crf/input/vendor"
```

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-protocol --test archive`

Expected: PASS, including missing-vendor and `.cargo/config.toml` rejection.

- [ ] **Step 5: Commit archive safety**

```bash
git add remote-build/crates/protocol
git commit -m "feat(remote-build): validate vendored source archives"
```

### Task 3: Persist operations and supervise a single controller

**Files:**
- Create: `remote-build/crates/controller/Cargo.toml`
- Create: `remote-build/crates/controller/src/main.rs`
- Create: `remote-build/crates/controller/src/store.rs`
- Create: `remote-build/crates/controller/tests/store.rs`

**Interfaces:**
- Consumes: `BuildRequest`, `OperationState`.
- Produces: `Store::accept`, `Store::transition`, `Store::interrupt_uncertain`, and `Store::operation_for_owner`.

- [ ] **Step 1: Write transition and crash-recovery tests**

```rust
#[test]
fn test_restart_interrupts_only_uncertain_operations() {
    let store = test_store();
    let running = store.accept(owner(), request()).unwrap();
    store.transition(running, OperationState::Assigned, "ctr-a").unwrap();
    store.transition(running, OperationState::Starting, "ctr-a").unwrap();
    store.interrupt_uncertain().unwrap();
    assert_eq!(store.get(running).unwrap().state, OperationState::Interrupted);
}
```

- [ ] **Step 2: Run the failing state test**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-controller --test store`

Expected: FAIL because the controller crate does not exist.

- [ ] **Step 3: Implement SQLite state and controller process rules**

Use WAL SQLite with short transactions: acquire/write/release before every
await. Persist owner certificate serial, request id, source digest, worker
generation, timestamps, terminal code, and bounded log location. Permit only
`Accepted -> Queued -> Assigned -> Starting -> Running -> terminal`; reject all
other transitions. On startup, reconcile labels matching only
`net.unraid.ci-runner-farm.remote-build.managed=true`, then mark `Assigned`,
`Starting`, and `Running` operations interrupted if their matching generation is
not alive. Handle SIGTERM as stop-accepting, drain until configured deadline,
kill only matching workers, persist terminal states, and exit.

- [ ] **Step 4: Test controller restart behavior**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-controller --test store`

Expected: PASS.

- [ ] **Step 5: Commit durable operation state**

```bash
git add remote-build/crates/controller
git commit -m "feat(remote-build): persist and recover operations"
```

### Task 4: Create and attest isolated workers

**Files:**
- Create: `remote-build/crates/controller/src/worker.rs`
- Create: `remote-build/crates/controller/tests/worker.rs`
- Create: `remote-build/images/cargo-worker/Dockerfile`

**Interfaces:**
- Consumes: queued operation and its guarded operation directory.
- Produces: `WorkerManager::start(operation) -> Result<WorkerLease, WorkerError>`.

- [ ] **Step 1: Write Docker-contract tests**

```rust
#[test]
fn test_worker_contract_has_no_host_escape_features() {
    let args = WorkerSpec::for_test().docker_args();
    assert!(args.contains(&"--network=none".into()));
    assert!(args.contains(&"--read-only".into()));
    assert!(args.contains(&"--cap-drop=ALL".into()));
    assert!(!args.iter().any(|arg| arg.contains("docker.sock") || arg == "--privileged"));
}
```

- [ ] **Step 2: Run the failing worker test**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-controller --test worker`

Expected: FAIL because `WorkerSpec` does not exist.

- [ ] **Step 3: Implement the minimum supported worker contract**

Create a unique name `crf-remote-build-<operation>-<generation>` and labels for
managed state, operation, owner hash, and generation. Mount immutable input at
`/crf/input:ro`; create guarded host directories for `/crf/work`,
`/crf/target`, and `/crf/build` rather than claiming portable Docker disk quotas
or putting builds in RAM. Set numeric worker UID/GID, `--read-only`,
`--network=none`, `--cap-drop=ALL`, `--security-opt=no-new-privileges:true`,
`--pids-limit`, `--memory`, `--memory-swap`, `--cpus`, and a controller wall
timer. Require a successful `docker inspect` attestation for these fields before
transitioning to `Running`; return `isolation_unavailable` if required controls
are absent.

- [ ] **Step 4: Verify a real worker cannot use network or Docker**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-controller --test worker -- --ignored`

Expected: PASS against Docker; the probe cannot resolve a host, cannot find
`/var/run/docker.sock`, and cannot write outside `/crf/work`, `/crf/target`, or
`/crf/build`.

- [ ] **Step 5: Commit the worker boundary**

```bash
git add remote-build/crates/controller/src/worker.rs remote-build/crates/controller/tests/worker.rs remote-build/images
git commit -m "feat(remote-build): run isolated cargo workers"
```

### Task 5: Add mTLS API, enrollment, polling, and artifact semantics

**Files:**
- Create: `remote-build/crates/controller/src/api.rs`
- Create: `remote-build/crates/controller/tests/api.rs`
- Modify: `remote-build/crates/controller/src/main.rs`

**Interfaces:**
- Consumes: `Store`, `WorkerManager`, protocol types.
- Produces: the five `/v1` routes defined above.

- [ ] **Step 1: Write ownership, pairing, and polling tests**

```rust
#[tokio::test]
async fn test_other_client_cannot_read_operation_or_logs() {
    let operation = submit_as(client_a()).await;
    assert_eq!(get_as(client_b(), format!("/v1/builds/{operation}")).await.status(), 404);
}

#[tokio::test]
async fn test_pairing_code_is_single_use() {
    assert_eq!(enroll_with("code", csr_a()).await.status(), 201);
    assert_eq!(enroll_with("code", csr_b()).await.status(), 409);
}
```

- [ ] **Step 2: Run the failing API tests**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-controller --test api`

Expected: FAIL because routes are absent.

- [ ] **Step 3: Implement narrowly scoped authentication and routes**

The client generates its key locally and sends a CSR. Store only a hash of each
pairing code, consume it with a constant-time comparison in one transaction,
rate-limit enrollment attempts, record actor/IP/CSR fingerprint, issue client
authentication EKU certificates, and never put codes in URL/query/log output.
Require mTLS for submission and polling, use certificate serial as owner, bound
request body/log/connection counts per owner, and return structured terminal
codes such as `dependency_unavailable`, `storage_limit`, `isolation_unavailable`,
and `interrupted`. `build` returns immutable manifest generation and SHA-256;
`test` and `clippy` reject artifact retrieval with 409.

- [ ] **Step 4: Run API tests**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-remote-controller --test api`

Expected: PASS, including replayed pairing, client isolation, request-size limit,
and artifact generation consistency.

- [ ] **Step 5: Commit authenticated control plane**

```bash
git add remote-build/crates/controller/src remote-build/crates/controller/tests/api.rs
git commit -m "feat(remote-build): add authenticated build API"
```

### Task 6: Implement the `crf-build` client

**Files:**
- Create: `remote-build/crates/client/Cargo.toml`
- Create: `remote-build/crates/client/src/main.rs`
- Create: `remote-build/crates/client/src/archive.rs`
- Create: `remote-build/crates/client/tests/cli.rs`

**Interfaces:**
- Consumes: protocol request types and controller endpoint contract.
- Produces: `crf-build enroll`, `crf-build build`, `crf-build test`, and `crf-build clippy`.

- [ ] **Step 1: Write CLI behavior tests**

```rust
#[test]
fn test_build_requires_vendor_and_excludes_dotenv() {
    let inventory = inventory_for("tests/fixtures/workspace-with-secret").unwrap();
    assert!(inventory.paths.contains(&"vendor/foo/.cargo-checksum.json".into()));
    assert!(!inventory.paths.iter().any(|path| path.starts_with(".env")));
}
```

- [ ] **Step 2: Run the failing client test**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-build --test cli`

Expected: FAIL because the client crate is absent.

- [ ] **Step 3: Implement key handling, upload, polling, and extraction**

Store client key/cert under the platform config directory with directory mode
0700 and key mode 0600. Build inventories from Git-tracked files plus required
Cargo/vendor files; print the inventory before upload. Submit a UUID request id,
poll `GET /v1/builds/{id}` with exponential backoff capped at five seconds, and
render logs as plain text. For build artifacts, create a new 0700 temp directory
under the requested output parent, reject links and paths not in the manifest,
verify every SHA-256, then atomically rename the newly created result directory.

- [ ] **Step 4: Run client tests**

Run: `cargo test --manifest-path remote-build/Cargo.toml -p crf-build --test cli`

Expected: PASS, including interrupted polling retry and malicious artifact rejection.

- [ ] **Step 5: Commit the developer client**

```bash
git add remote-build/crates/client
git commit -m "feat(remote-build): add cargo remote-build client"
```

### Task 7: Integrate an independent Unraid lifecycle and status page

**Files:**
- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/remote-build.sh`
- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmRemoteBuild.page`
- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/remote-build.default.cfg`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/event/docker_started`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/event/stopping_docker`
- Create: `tests/remote-build-controls.sh`

**Interfaces:**
- Consumes: installed `bin/remote-build-server` and `remote-build.cfg`.
- Produces: `remote-build.sh start|stop|reconcile|status-json` and `Menu="RunnerFarm:4"` UI.

- [ ] **Step 1: Write shell regression tests first**

```bash
grep -Fq 'REMOTE_LABEL="net.unraid.ci-runner-farm.remote-build.managed=true"' "$ENGINE"
grep -Fq 'flock -n' "$ENGINE"
grep -Fq 'REMOTE_CFG="${CFGDIR}/remote-build.cfg"' "$ENGINE"
! grep -Fq 'CACHE_ROOT=' "$ENGINE"
```

- [ ] **Step 2: Run the failing lifecycle test**

Run: `bash tests/remote-build-controls.sh`

Expected: FAIL because no remote-build lifecycle wrapper exists.

- [ ] **Step 3: Implement dedicated lifecycle rules**

Use `flock` and a PID file under `/var/local/emhttp/ci-runner-farm-remote-build`.
Read only an allowlisted independent config; guard the remote root with realpath,
dedicated-subdirectory, ownership, and symlink checks. `docker_started` invokes
remote `reconcile` only after Docker is ready. `stopping_docker` invokes remote
`stop` before runner-farm handling. Route only `remote-status`, `remote-start`,
and `remote-stop` through `exec.php` after existing CSRF and authenticated-admin
checks; validate every response as JSON and render all logs with `textContent`.
Remote disabled must make zero Docker calls.

- [ ] **Step 4: Run lifecycle and existing plugin tests**

Run: `bash tests/remote-build-controls.sh && bash tests/config-parity.sh && bash tests/safe-paths.sh && bash tests/rust-preset.sh`

Expected: PASS. Existing runner config parity remains unchanged.

- [ ] **Step 5: Commit plugin integration**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm tests/remote-build-controls.sh
git commit -m "feat(remote-build): manage controller from unraid plugin"
```

### Task 8: Package, release, and prove the vertical slice

**Files:**
- Modify: `.github/workflows/lint.yml`
- Modify: `.github/workflows/package-plugins.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `build-plg.sh`
- Modify: `deploy.sh`
- Modify: `ci-runner-farm.plg`
- Modify: `README.md`
- Create: `docs/remote-build-operations.md`

**Interfaces:**
- Consumes: controller binary, pinned worker-image digest, plugin lifecycle wrapper, and client crate.
- Produces: a plugin package with an executable controller, a separate checked client release, and an operator runbook.

- [ ] **Step 1: Write package-content assertions**

```bash
tar -tzf ci-runner-farm.tgz | grep -Fx './bin/remote-build-server'
tar -tvzf ci-runner-farm.tgz | grep -E '^-rwxr-xr-x .*bin/remote-build-server$'
! tar -tzf ci-runner-farm.tgz | grep -E '(client-key|pairing-code|remote-build\.cfg)$'
```

- [ ] **Step 2: Run the failing package assertion**

Run: `bash tests/remote-build-package.sh`

Expected: FAIL until build CI places and marks the controller binary correctly.

- [ ] **Step 3: Build and verify release inputs**

CI runs `cargo fmt --check`, `cargo clippy -- -D warnings`, and `cargo test` for
`remote-build`; builds the supported controller architecture; verifies the worker
image by immutable digest; packages the controller with explicit 0755 permission;
and publishes `crf-build` separately with SHA-256 checksum. Replace `deploy.sh`'
partial copy list with an explicit complete manifest covering every
`RunnerFarm*.page`, `include/*`, `event/*`, `bin/*`, and `nchan/*` runtime file.

- [ ] **Step 4: Run packaging and end-to-end checks**

Run: `bash tests/remote-build-package.sh && ./build-plg.sh && bash tests/config-parity.sh`

Expected: PASS. On an isolated Unraid host: enroll one client, submit one vendored
workspace build, one test, and one Clippy run; confirm no worker network access,
no runner-farm containers or config changes, and safe uninstall preserves remote
data by default.

- [ ] **Step 5: Commit release verification**

```bash
git add .github build-plg.sh deploy.sh ci-runner-farm.plg README.md docs tests
git commit -m "feat(remote-build): package and document cargo build service"
```

## Follow-on Hardening Plan

Implement these only after Task 8 has real-host evidence: CSR pairing UI with
CA rotation and revocation, durable SSE replay, immutable dependency snapshots
instead of required vendor trees, enabled-network registry access, result cache
with owner/ACL namespace and atomic publish, multiarch controller/worker/client
releases, and `sccache-dist`. Each requires a separate design and threat-model
review because it changes either trust, persistence, or network boundaries.

## Self-Review

- Spec coverage: Tasks 1-2 implement the typed protocol and vendored source
  contract; Tasks 3-5 implement recovery, isolation, mTLS, polling, and
  artifact semantics; Task 6 implements the client; Task 7 keeps the extension
  independent of the existing runner fleet; Task 8 packages and verifies it.
- Placeholder scan: no open-ended implementation instructions are used; every
  code task has a test, command, expected result, implementation rule, and
  commit command.
- Type consistency: `BuildRequest`, `OperationState`, `Store`, and
  `WorkerManager` are defined before later tasks consume them; polling and
  artifact behavior are consistent with the V1 endpoint contract.
