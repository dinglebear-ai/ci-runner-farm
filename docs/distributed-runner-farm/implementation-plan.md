# Distributed Runner Farm Implementation Plan

## Phase 1: shared contracts and scheduler

- [x] Rust workspace and shared protocol crate.
- [x] Platform-neutral node/work/resource models.
- [x] Deterministic heterogeneous node scheduler.
- [x] Persistent framed `crf-scheduler` service.
- [x] Thin Elixir Port client using the Rust scheduler as the single placement algorithm.
- [x] Elixir controller node registry.

## Phase 2: authenticated wire and durability

- [x] Versioned strict JSON wire models in Rust and Elixir.
- [x] Shared cross-language controller-command fixture.
- [x] Four-byte bounded framing.
- [x] TLS 1.3 controller listener with mandatory client certificate.
- [x] Certificate fingerprint -> node identity authorization.
- [x] Persistent Rust rustls mTLS client.
- [x] Pull-based command mailbox attached to node responses.
- [x] Exact response-byte retry cache.
- [x] Node generation fencing and durable generation reservation.
- [x] Authenticated newer-generation adoption for a surviving runner.
- [x] Two-phase controller ACK/mailbox transaction.
- [x] Durable controller placement ledger.
- [x] Durable scale-set sequence/replay fence.

## Phase 3: portable node execution

- [x] Linux/Windows native runner invocation.
- [x] Command prepare/commit/reconcile pipeline.
- [x] Durable placement intent/spawn/terminal state without JIT persistence.
- [x] Private per-placement runner materialization.
- [x] File-backed runner stdout/stderr.
- [x] Managed process-tree cancellation and terminal polling: dedicated Unix process groups with TERM→KILL escalation and race-free Windows Job Object assignment via suspended startup.
- [x] Durable terminal-report outbox and agent sync.
- [x] Runnable `crf-node` configuration, startup, reconnect/backoff, heartbeat loop, and shutdown.
- [x] Host memory/resource probing and durable local reservation accounting.
- [x] Restart recovery for durable spawned PIDs.
- [x] Native GitHub runner package acquisition, pinned manifest, exact-size/SHA verification, safe TAR/ZIP extraction, immutable cache, tamper detection, bounded rollback retention, and garbage collection.

## Phase 4: GitHub demand and distributed admission

- [x] Preserve the existing Go scale-set implementation as the GitHub protocol adapter.
- [x] Same-UID authenticated local IPC between Elixir and the Go adapter.
- [x] Strict Elixir scale-set request/response/snapshot client.
- [x] Private durable one-shot JIT replay cache in the central Go adapter.
- [x] Ambiguous issuance protection and explicit retirement.
- [x] Non-secret JIT recovery-state endpoint.
- [x] Resource-backed node-specific offer ledger.
- [x] Rust-scheduled fair bounded offer planning.
- [x] Advertised capacity = resource-backed nonterminal placements + live offers.
- [x] Acquired handle -> offer assignment -> JIT -> placement -> node mailbox flow.
- [x] Controller restart recovery for lost JIT-bearing mailbox commands.
- [x] Surviving node runner adoption across node-agent generation restart.
- [x] Opt-in serialized automatic reconciliation loop and sidecar-session recovery.
- [x] Load real pool policies, TLS peers, scale-set adapter identity, durable state, scheduler, and reconciliation settings from a strict controller config.
- [x] Optional OTP supervision of the Go adapter + Elixir controller + Rust scheduler with bounded child-process cleanup.
- [x] Distribution-tagged Linux release bundle with OTP controller, Rust scheduler/node, optional Go sidecar, hardened systemd units, idempotent installer, checksums, and CI verification smoke.
- [x] CA-agnostic node leaf enrollment, fingerprint helper, atomic hot allowlist reload, overlap rotation, already-connected-session revocation, and explicit emergency revoke-all.
- [ ] CA/server-certificate automation, additional target-distribution Linux bundles, and Windows service packaging.
- [x] Conservative placement-loss grace, operator-visible orphan tracking, node-recovery recheck, and explicit force-abandon/JIT cleanup without automatic duplicate execution.

## Phase 5: existing Unraid integration

- [ ] Extract current local Docker/JIT execution behind the shared runtime interface.
- [ ] Preserve single-host behavior as the local-node backend.
- [ ] Map legacy pool policy and resource configuration into distributed pool policy.
- [ ] Add distributed node status/configuration to API and UI.
- [ ] Add migration/default behavior so existing installs remain unchanged unless distributed mode is enabled.

## Phase 6: hardening and release

- [x] Windows-target GNU cross-check for node and scheduler.
- [x] GitHub-hosted Ubuntu/Windows distributed-core CI wiring.
- [x] Native Windows MSVC CI run from PR #37.
- [ ] Live Linux node smoke.
- [ ] Live Windows node smoke.
- [ ] Real GitHub scale-set two-node smoke.
- [ ] Controller/node restart and network-partition matrix.
- [ ] Resource fragmentation/oversubscription/fairness matrix at sustained load.
- [x] Leaf certificate rotation/revocation/enrollment workflow with live-session reauthorization.
- [ ] Automated CA/server certificate rotation and revocation-provider integration policy.
- [ ] Security review of credentials, certificates, durable JIT cache, filesystem permissions, and logs.
- [ ] Distributed API/UI production-readiness sweep.
- [ ] Adversarial PR review and full existing plugin regression suite.
