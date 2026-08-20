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
- [x] Schema-v2 terminal placement compaction into durable replay-fence tombstones, with schema-v1 migration and live-only capacity snapshots.
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
- [x] Literal IP or DNS/MagicDNS controller endpoints with syntax validation and fresh OS resolution on every reconnect; TLS server identity remains separately pinned.
- [x] Host memory/resource probing and durable local reservation accounting.
- [x] Restart recovery for durable spawned processes with PID + OS process-birth identity, rejecting PID reuse instead of adopting an unrelated process.
- [x] Crash-safe node placement-state GC: only controller-acknowledged terminal tombstones from older generations are atomically quarantined and deleted; same-generation, unreported, and nonterminal state is retained.
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
- [ ] CA/server-certificate automation and additional target-distribution Linux bundles.
- [x] Native Windows node service entry point, low-privilege/manual-start installer, release ZIP builder, and hosted-Windows packaging validation.
- [x] Conservative placement-loss grace, operator-visible orphan tracking, node-recovery recheck, and explicit force-abandon/JIT cleanup without automatic duplicate execution.

## Phase 5: existing Unraid integration

- [x] Extract current local Docker/JIT container mutation mechanics behind `runner-runtime.sh`; classic registration, scale-set JIT, recycle, graceful stop/remove, and force-remove now share one Docker runtime boundary while policy/locks/secrets remain above it.
- [x] Add portable `crf-node` container runtime identity, bounded stdin/stdout adapter client, crash-safe start/inspect/cancel executor, and explicit `native_process`/`container` daemon backend selection.
- [x] Add the local Unraid adapter endpoint that maps controller-approved placement requests onto `runner-runtime.sh` without duplicating scheduling/admission or GitHub JIT retirement authority.
- [x] Preserve single-host behavior as the default local backend; the distributed adapter is reachable only through its dedicated stdin-only command and is not part of normal fleet startup.
- [x] Map validated legacy single-fleet and V2 Unraid pool/resource configuration into strict distributed controller pool-policy JSON without enabling distributed mode.
- [ ] Add distributed node status/configuration to API and UI.
- [x] Add migration/default behavior so existing plugin installs, controller startup, and node execution remain legacy/native unless their dedicated distributed configuration is explicitly supplied.

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
