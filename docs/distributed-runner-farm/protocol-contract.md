# Distributed Protocol and Durability Contract

## Node transport

- TLS 1.3 only.
- Controller requires a client certificate.
- Controller certificate trust is explicit on every node.
- Client certificate fingerprint maps to one configured node identity.
- Claimed `node_id` must match authenticated identity.
- Four-byte unsigned big-endian application length prefix followed by one JSON payload.
- Maximum node/control JSON payload is 256 KiB and is checked before body allocation.
- Node/controller wire schema is version 1 and rejects unknown fields on both sides.

## Node -> controller

Every message contains protocol version, message ID, node ID, node generation, timestamp, and one typed payload: registration, heartbeat, command ACK, or placement update.

The controller caches exact response bytes by node generation + message ID + request fingerprint. Exact network replay receives byte-identical response. Message-ID reuse with changed bytes is rejected.

A command ACK or placement update is accepted only when its generation equals the generation currently registered for that authenticated node. Placement storage may adopt a newer generation only after this ingress fence succeeds.

## Controller -> node

A response contains protocol version, correlated message ID, accepted/duplicate/rejected status, optional error code, and optionally one controller command. Rejected responses cannot carry commands. Accepted/duplicate responses cannot carry an error code.

Every command contains command ID, idempotency key, target node identity/generation, issue/expiry timestamps, and one typed payload: start placement, cancel placement, or set drain. Maximum TTL is five minutes.

## Scheduler bridge

The Elixir controller communicates with the Rust scheduler over one persistent Port using four-byte framing. Scheduler protocol version is 1, maximum payload is 256 KiB, maximum request/node list is 4096 items, and unknown fields fail closed.

The response is correlated by request ID. A scheduler process timeout or exit causes the pure scheduler process to be restarted; requests remain serialized and bounded by the client queue.

## Go scale-set adapter IPC

The scale-set adapter exposes a same-effective-UID Unix-domain socket. Each request contains:

- schema version;
- request ID;
- operation;
- configuration revision;
- ownership revision;
- controller instance ID;
- strictly increasing sequence;
- typed payload.

The sequence high-water mark is persisted by Elixir before socket write. A controller crash may burn a number but cannot reuse it. Corrupt/identity-mismatched sequence state fails closed.

Important operations are `apply_sessions`, `publish_capacity_leases`, `read_snapshot`, `read_jit_state`, `issue_jit`, `retire_jit`, reconcile, and owned-scale-set deletion.

`read_jit_state` is deliberately non-secret: it exposes only pool ID, scale-set ID, work handle, lifecycle state, and a boolean indicating whether a private descriptor cache exists. A response that attempts to include the descriptor is rejected by the Elixir parser.

## JIT secrecy and replay

Rust and Elixir use redacting secret wrappers. Debug/Inspect output never contains JIT. Native node launch injects JIT through `ACTIONS_RUNNER_INPUT_JITCONFIG`; it is not in argv.

The node does not persist JIT. The controller placement ledger and scale-set sequence store do not persist JIT.

## Operator projection

A node configured with `CRF_OPERATOR_PROJECTION_PATH` advertises the
`operator-projection-v1` capability. Only that authenticated node receives the
optional projection field in controller responses, preserving rolling
compatibility with older nodes. The projection is bounded by the normal 256 KiB
wire frame, contains only the redacted operator snapshot plus controller ID and
wall-clock observation time, and carries no JIT, GitHub credential, private key,
or mutation token. The node writes the latest projection atomically to the
configured absolute path; Unix files use mode `0600` and symlink targets are
rejected. Unraid accepts projection files only beneath its fixed cache-backed
distributed-node root.

The central Go adapter may persist a descriptor solely for one-shot recovery:

- descriptor directory: mode 0700;
- descriptor files: mode 0600;
- descriptor content is bounded and validated;
- normal issued state replays the cached descriptor without another GitHub call;
- `issue_started` with a cache self-promotes to issued and replays;
- `issue_started` without a cache remains ambiguous and never retries GitHub;
- retirement deletes both descriptor and issued-state tombstone.

## Capacity reservations

An advertised scale-set slot must be backed by either a nonterminal placement or an `Offer` reservation on one node generation.

Offers transition `offered -> assigned(handle) -> consumed into placement`. Only free offered slots expire. Assigned offers remain reserved until converted/released. One pool work handle may own at most one offer.

## Durable placement state

Controller placement state is persisted in a private atomic JSON file when configured. Schema v2 keeps full scheduling fields only for nonterminal placements. When a placement becomes terminal, the controller atomically compacts it into a replay-fence tombstone containing placement ID, command ID, a SHA-256 digest of the idempotency key, node identity/generation, final state, and detail code. Tombstones preserve redispatch, late-ACK, late-update, JIT-retirement, placement-ID, and command-ID fences while dropping work/pool/resource scheduling data. No controller placement record contains JIT. Schema-v1 files remain readable and terminal v1 records migrate to tombstones on the next write.

The placement file is deliberately bounded to 65,536 combined live placements and tombstones and 16 MiB. Compaction keeps normal terminal history inside that bound; longer-horizon archival/segmentation is a separate concern rather than an excuse to weaken replay fencing.

JIT-bearing NodeMailbox entries are intentionally ephemeral. After a controller restart, a durable commanded placement can reconstruct a missing mailbox command only by replaying the central cached descriptor through the scale-set adapter.

Node placement state is phase-based: intent, spawned PID plus OS process-birth token, terminal outcome, reported marker. After the controller acknowledges a terminal report and the node advances to a newer generation, node-local terminal state is crash-safely quarantined and pruned. Same-generation, unreported, and nonterminal state remains durable.
