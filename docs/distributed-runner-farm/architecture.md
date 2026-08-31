# Distributed Runner Farm Architecture

## Topology

`GitHub Actions -> Go scale-set adapter -> Elixir controller -> Rust scheduler -> Rust node agents -> local runner runtime`

All four pieces belong to one control plane, but each has a deliberately narrow responsibility.

### GitHub scale-set adapter

The existing Go `crf-scaleset` implementation remains the GitHub Actions protocol boundary. It owns the actions/scaleset SDK/session machinery, GitHub-side scale-set identity, acquired work handles, one-shot JIT issuance, and owned-scale-set cleanup.

The adapter runs beside the Elixir controller and exposes a same-UID Unix-domain control socket. The Elixir controller does not duplicate GitHub SDK/session logic.

One-shot JIT descriptors are centrally cached only when necessary for crash recovery. The cache directory is mode 0700 and descriptor files are mode 0600. A normal issued descriptor can be replayed after controller restart without another GitHub call. An ambiguous `issue_started` state without a cached descriptor is never reissued and remains explicitly retireable.

The adapter also owns adaptive GitHub admission because this is where `JobAvailable` metadata exists before acquisition. For candidates already visible in a GitHub message batch, it ranks work by a bounded runtime hint keyed by pool, owner, repository, normalized workflow path, and job display name. Completed jobs update a 75/25 EWMA from runner-assignment to finish time. Unknown jobs use a five-minute neutral estimate; jobs queued for at least ten minutes override runtime ranking so duration optimization cannot starve long work. Acquisition is capped by the pool capacity remaining after GitHub's authoritative `TotalAssignedJobs`.

Runtime hints are optional scheduling evidence, not durable correctness state. They are bounded to 2,048 entries / 1 MiB, keyed on SHA-256 digests so owner/repository/workflow/job metadata is not persisted in plaintext, stored beside the replay journal in a private mode-0600 file, throttled to avoid an fsync per completion, and ignored on malformed or unavailable history so the adapter cold-starts safely. Completion samples are applied only after GitHub accepts the containing message acknowledgement, so retries and ambiguous session resets cannot double-count a job; persisted millisecond values are range-checked before `time.Duration` conversion to prevent overflow-shaped hints.

This admission policy never inflates GitHub's `X-ScaleSetMaxCapacity` to manufacture lookahead. The upstream scale-set contract defines that header as the real capacity the backend may rely on when assigning work. When GitHub's authoritative `TotalAvailableJobs` exceeds the candidates carried by the current message and the pool still has admission capacity, the adapter performs a best-effort admin lookup through `/{scaleSetID}/acquirablejobs`. That lookup has a two-second child deadline and two distinct bounds: the vendored HTTP client refuses a response body larger than 16 MiB before JSON decoding, while the adapter rejects a decoded list larger than 10,000 jobs. The result is merged with rather than substituted for message-visible candidates, and the controller falls back to the visible batch on error, empty response, or race. Ranking then selects only the best K candidates where K is the remaining pool capacity, using an O(N log K) top-K heap rather than sorting the entire hidden backlog.

The current `actions/scaleset` client does not expose that admin endpoint, so the runner farm temporarily pins a v0.4.0-compatible backport from `dinglebear-ai/scaleset` at `035cda46ea086d5faaa13f4b17953112c1c7f295` (pseudo-version `v0.4.1-0.20260822023756-035cda46ea08`). The same minimal API addition is proposed upstream as `actions/scaleset#126`; remove the fork replacement once an upstream release contains the API. The fork changes only client transport surface, adds the 16 MiB response-body bound, validates the response count contract, permits concurrent queue polls while serializing request preparation and token refresh with context-aware waiting, and reuses the SDK's existing Actions admin authentication; the runner farm does not duplicate or intercept GitHub credentials.

This deeper queue visibility also feeds a proactive, borrowable fast lane without changing GitHub's published capacity. The policy samples at most 64 evenly spaced visible/acquirable candidates, derives the 75th-percentile known runtime, and clamps the long-work threshold to 4–8 minutes so adaptation can become more protective than the original eight-minute rule but never less protective. Queue pressure adjusts the base hold target: very deep backlog uses 10 seconds, elevated backlog 15 seconds, ordinary saturation 20 seconds, and sparse queues 25 seconds; a marginal job at least twice the tuned long threshold may add one five-second step, with a hard 5–30 second bound. Reservation width is elastic too: the normal target is roughly one quarter of pool capacity, hard-capped at four slots and always below total capacity; backlog at least four times capacity halves that target, while backlog at least eight times capacity collapses it to one slot. Per-scale-set hysteresis limits threshold movement to two minutes, hold movement to five seconds, and width movement to one slot per tuning step.

When the trailing candidates that would fill remaining capacity are learned, non-starved jobs at or above the tuned threshold, admission acquires the higher-ranked work and may leave 1–4 trailing long-work slots open according to the tuned width. It never reserves a quick, unknown-runtime, or starvation-protected candidate. While a reservation is active, the pool's existing supervisor heartbeat (bounded to at most ten seconds) probes authenticated `acquirablejobs` and skips the GitHub message long-poll while only learned-long work remains. Unknown work, work below the reservation's persisted threshold, or any job protected by the ten-minute starvation override releases the hold so the next normal replay-fenced message transaction can acquire it. Expiry or lookup degradation permits exactly one long-work borrow pass, recovering utilization without immediately re-arming the reservation.

Fast-lane state is optional optimization state, never acquisition authority. Active reservations persist their deadline, tuned long-work threshold, exact hold duration, and reserved-slot width atomically beside the replay journal in a private mode-0600 `fast-lanes.json` file bounded to eight entries / 16 KiB. A restart restores a live hold with the same policy, converts an already-expired hold into a one-shot borrow, and cold-starts with no reservation if the file is missing or malformed. The longer-lived hysteresis accumulator is intentionally in-memory only; a restart recomputes it from current queue/runtime evidence while the active reservation itself remains deterministic. Capacity changes, empty queue evidence, quick-work consumption, and completed borrow passes clear the durable reservation. Persistence failure keeps the live in-memory policy and logs degradation rather than failing job admission. `AcquireJobs` is never issued by the heartbeat probe or outside the existing message journal transaction, so the optimization does not create a second acquisition/replay protocol. The strict Go/Elixir pool snapshot exposes only lane state, threshold, hold duration, reserved width, deadline, capacity/health, and freshness metadata; the controller projects those into operator `pool_status` while deliberately omitting acquired handles and GitHub job identity. Rust remains the sole resource/node placement algorithm after GitHub admission.

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
- retained native runner materialization code that is not selectable until a per-placement OS sandbox exists;
- controller-approved container execution through a bounded local adapter process;
- file-backed runner stdout/stderr logs;
- durable terminal-report outbox;
- durable resource accounting plus restarted-PID and container-ID recovery.

The node never persists the JIT descriptor.

## Capacity and demand flow

The distributed model preserves the legacy single-host invariant that GitHub capacity is backed before it is advertised.

1. Elixir reconciles central JIT recovery state before admitting new work.
2. Elixir reads a fresh scale-set snapshot and acquired handles.
3. Existing acquired/JIT handles are reconciled first.
4. An idle healthy pool receives exactly one resource-backed bootstrap lease. Once GitHub reports assigned demand, Elixir asks Rust to place only the additional offer requirements needed to match that observed demand.
5. Every successful placement becomes a node-bound `Offer` reservation. Synthetic bootstrap offers are assigned to real work handles when those handles arrive; stale assigned offers are released only when acquired-handle, JIT, and durable-placement evidence are all absent.
6. Published GitHub capacity for a pool is exactly `nonterminal placements + live offers`, capped by the same 64-runner fuse.
7. When GitHub returns a work handle, the oldest matching offer is assigned to the handle. If no offer exists, the actual work handle is placed through Rust before JIT issuance.
8. JIT is issued/replayed through the Go adapter.
9. `PlacementCoordinator` atomically converts the assigned offer into a durable placement and JIT-bearing node command.

Assigned offers do not expire while a handle is in flight. Their originating scale-set identity is stored on the in-memory offer reservation so cleanup remains correct if a pool disappears or is replaced. Free offers may expire or be trimmed if pool policy shrinks.

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

JIT terminalization atomically detaches per-runner work and Docker data into the private `${CACHE_ROOT}/.jit-gc` quarantine before retiring the GitHub handle or releasing its reservation, including create attempts that never produced an observable container. A single background sweeper reclaims at most eight entries per pass outside the autoscale/fleet locks and with its standard streams detached from the invoking command; failed entries are rotated for fair retry on later reconciliation. Sweep configuration is validated before launch. Detach, reclaim, retry, and sweeper-start failures are emitted as `jit-gc` operator telemetry, while unsafe roots or failed detaches keep the durable cleanup state and reservation for retry.

Workspaces and mutable package caches remain node-local. Cross-node compiler reuse should use concurrency-safe services such as Kache/sccache. Docker image sharing should use a registry mirror rather than a shared writable Docker filesystem.
