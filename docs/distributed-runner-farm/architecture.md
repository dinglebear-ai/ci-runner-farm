# Distributed Runner Farm Architecture

## Topology

`GitHub Actions -> Go scale-set adapter -> Elixir controller -> Rust scheduler -> Rust node agents -> local runner runtime`

All four pieces belong to one control plane, but each has a deliberately narrow responsibility.

### GitHub scale-set adapter

The existing Go `crf-scaleset` implementation remains the GitHub Actions protocol boundary. It owns the actions/scaleset SDK/session machinery, GitHub-side scale-set identity, acquired work handles, one-shot JIT issuance, and owned-scale-set cleanup.

The adapter runs beside the Elixir controller and exposes a same-UID Unix-domain control socket. The Elixir controller does not duplicate GitHub SDK/session logic.

One-shot JIT descriptors are centrally cached only when necessary for crash recovery. The cache directory is mode 0700 and descriptor files are mode 0600. A normal issued descriptor can be replayed after controller restart without another GitHub call. An ambiguous `issue_started` state without a cached descriptor is never reissued and remains explicitly retireable.

### Elixir/OTP controller

The controller owns orchestration and reconciliation:

- pool policy and hard global concurrency ceilings;
- node registry, freshness, drain state, and active-placement evidence;
- durable placement lifecycle ledger;
- resource-backed offer ledger;
- GitHub work-handle/JIT recovery orchestration through the Go adapter;
- scheduler request construction and effective-capacity accounting;
- per-node command mailboxes;
- node ingress over TLS;
- serialized optional automatic reconciliation;
- authenticated operator snapshots and mutations through the controller-local
  CLI;
- a bounded secret-free operator projection for explicitly capable nodes,
  delivered on the existing mTLS response path.

The controller is platform-neutral and contains no Unraid filesystem, Docker, or shell assumptions.

The authority boundary is intentional. The Unraid page reads a private local
snapshot written atomically by its authenticated node; it does not tunnel the
same-UID controller RPC. The projection contains read-only nodes, resources,
offers, placements, demand/session, sidecar, and freshness data. Credentials,
JIT descriptors, certificate material, and mutation capability are excluded.
Drain/undrain and orphan remediation remain controller-local operations.

### Rust scheduler

`crf-scheduler` is the only placement algorithm. It runs as one persistent framed stdin/stdout process supervised by Elixir. The scheduler is deterministic and pure: work requirements + node snapshots produce placements/unplaced reasons. Elixir does not contain a second best-fit implementation.

Before each scheduler call the controller subtracts:

1. nonterminal placements not yet reflected in a node heartbeat; and
2. node-bound distributed offers.

The exact offer being converted into a placement is excluded from the final commit-time subtraction so resources are transferred, not double charged.

### Rust node agent

`crf-node` owns:

- platform identity and monotonic durable node generation;
- mTLS connection to the controller;
- resource and active-placement reporting;
- idempotent command processing;
- durable placement intent/runtime/terminal state with portable native-process or container identity;
- native runner materialization and lifecycle;
- controller-approved container execution through a bounded local adapter process;
- file-backed native stdout/stderr logs;
- durable terminal-report outbox;
- durable resource accounting plus restarted-PID and container-ID recovery.

The node never persists the JIT descriptor.

## Capacity and demand flow

The distributed model preserves the legacy single-host invariant that GitHub capacity is backed before it is advertised.

1. Elixir reconciles central JIT recovery state before admitting new work.
2. Elixir reads a fresh scale-set snapshot and acquired handles.
3. Existing acquired/JIT handles are reconciled first.
4. For free capacity, Elixir asks Rust to place a bounded number of synthetic offer requirements.
5. Every successful placement becomes a node-bound `Offer` reservation.
6. Published GitHub capacity for a pool is exactly `nonterminal placements + live offers`, capped by the same 64-runner fuse.
7. When GitHub returns a work handle, the oldest matching offer is assigned to the handle. If no offer exists, the actual work handle is placed through Rust before JIT issuance.
8. JIT is issued/replayed through the Go adapter.
9. `PlacementCoordinator` atomically converts the assigned offer into a durable placement and JIT-bearing node command.

Assigned offers do not expire while a handle is in flight. Free offers may expire or be trimmed if pool policy shrinks.

## Placement and node flow

1. Controller records a durable placement and enqueues a fenced `start_placement` command.
2. Node heartbeat receives at most one pending command in the response.
3. Node validates protocol, certificate-bound identity, generation, TTL, and idempotency.
4. Node records placement intent before local runtime creation.
5. The configured backend executes the already-approved placement: native mode materializes a private runner and launches with JIT only in `ACTIONS_RUNNER_INPUT_JITCONFIG`; container mode sends a bounded request and JIT descriptor to the local adapter only over stdin.
6. Node records the runtime identity before ACKing accepted: PID + process birth token for native runners, immutable container ID for containers.
7. Runtime exit/loss is durable before being reported.
8. Terminal report remains pending until controller acceptance.

## Restart and ambiguity behavior

- **Elixir restart, Go adapter survives:** durable scale-set sequence continues at N+1, so the adapter replay fence is not regressed.
- **Elixir restart, mailbox lost:** durable commanded placement + Go descriptor cache rebuild the JIT-bearing command exactly once.
- **Node agent restart, runner survives:** the new authenticated node generation may adopt the same-node placement when heartbeat reports it active; stale old-generation mailbox state is discarded.
- **Unregistered higher generation:** rejected at ingress even though placement generation adoption is monotonic.
- **Controller loss:** no new placements; already-running node runners continue.
- **Lost command ACK:** node replays the original accepted/rejected outcome.
- **Lost terminal response:** durable terminal outbox retries.
- **Crash after local placement intent but before known runtime:** native mode stays uncertain and never auto-respawns; container mode first inspects by placement identity and retries start only after the adapter explicitly proves the runtime absent.
- **Dead durable runtime after node restart:** a missing native PID becomes `runner_process_lost`; a previously identified but absent container becomes `container_lost`.
- **GitHub JIT ambiguity:** the adapter never retries the one-shot GitHub issue call unless it has an already-fsynced cached descriptor to replay.

## Storage and caches

Controller placement state and scale-set sequence state use private atomic files. The placement file keeps full nonterminal records and compact schema-v2 terminal replay tombstones; legacy v1 state migrates in place. Terminal tombstones retain the identity/replay fence but drop scheduling-only resource/work/pool fields. JIT secrets are not stored in those files. The only durable JIT copy is the central private adapter recovery cache.

Node-local terminal state is retained through controller acknowledgement and the current node generation. On a later generation, acknowledged terminal directories move atomically into a sibling quarantine and are deleted resumably; unexpected quarantine contents fail closed.

The legacy Unraid backend now has an explicit container-runtime boundary in `runner-runtime.sh`. Classic fixed runners, scale-set JIT runners, and manual recycle all use the same prepared-container launch and remove primitives. Admission, fleet locks, resource reservations, GitHub registration/JIT state, credential FIFO handoff, identity validation, and cache policy remain in their existing higher-level shell modules. Registry-mirror lifecycle and validation probes are intentionally outside the runner runtime boundary. The portable node side has a strict bounded container-adapter client/executor and explicit backend selection. The local Unraid Start/Inspect/Cancel adapter translates controller-approved placements into the shared runtime boundary without re-running global scheduling/admission or owning GitHub JIT retirement.

Workspaces and mutable package caches remain node-local. Cross-node compiler reuse should use concurrency-safe services such as Kache/sccache. Docker image sharing should use a registry mirror rather than a shared writable Docker filesystem.
