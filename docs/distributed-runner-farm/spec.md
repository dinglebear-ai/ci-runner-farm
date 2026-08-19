# Distributed Runner Farm Specification

## Goal

Run one CI Runner Farm across heterogeneous devices while preserving global pool limits, deterministic placement, resource safety, one-shot JIT semantics, restart recovery, and the existing single-host path.

## Required properties

1. Long-lived GitHub credentials and scale-set protocol state stay in the central control plane, never on worker nodes.
2. The existing Go scale-set implementation is the GitHub protocol adapter; Elixir orchestrates it instead of duplicating SDK/session logic.
3. Nodes are portable Linux/Windows executors and contain no Unraid-specific assumptions.
4. Rust `crf-scheduler` is the single placement algorithm. Elixir may revalidate capacity at commit time but must not implement a divergent best-fit scheduler.
5. Every advertised GitHub slot is backed by one node-specific resource reservation or one nonterminal placement before publication.
6. Every placement belongs to exactly one node identity and current authenticated generation. A newer generation may adopt a surviving same-node placement only after NodeRegistry/ingress validation.
7. Node resource feasibility is evaluated per host. Aggregate capacity must never make an individually impossible job schedulable.
8. JIT configuration must never be persisted on nodes, controller placement state, or logs. A central private recovery cache is permitted solely to make one-shot GitHub issuance crash-recoverable.
9. Command delivery is idempotent. Reusing an idempotency key with changed bytes fails closed.
10. Command ACK outcomes are replayed exactly. A rejected command cannot later replay as success.
11. Node generation numbers are monotonic across process restarts. A partially reserved generation is burned, not reused.
12. Terminal node updates are a durable outbox and remain pending until controller acceptance.
13. Controller scale-set request sequences are durable and monotonic across controller restarts.
14. Controller placement state is durable when distributed mode is configured. JIT-bearing mailboxes are deliberately reconstructed, not persisted.
15. Unknown fields, oversized frames, malformed identities, stale generations, contradictory responses, corrupt durable state, and replay regressions fail closed.
16. Existing single-host Unraid behavior remains the default local backend until distributed mode is explicitly configured.

## Initial execution path

Portable nodes execute native GitHub Actions runners on Linux and Windows. The existing Unraid Docker/container runtime remains the current local backend until it is moved behind the same execution interface.

## Admission model

For every pool the controller enforces a hard ceiling no larger than the existing 64-runner scale-set fuse. Capacity is represented as:

`advertised = nonterminal placements + live resource-backed offers`

Work handles are reconciled before new offers are planned. Pools with unresolved/ambiguous work are blocked from creating additional offers for that tick.

## Acceptance criteria

- Rust protocol/scheduler/node tests and strict Clippy pass.
- Elixir compiles with warnings as errors and runs controller tests against the real Rust scheduler binary.
- Go scale-set adapter tests pass, including durable JIT replay and ambiguous issuance retirement.
- Node and scheduler cross-compile for Windows; native Windows GitHub-hosted CI is configured.
- Exact heartbeat retries receive byte-identical responses.
- Transport failure cannot mark a terminal report delivered.
- Crash after node placement intent but before durable spawn cannot auto-double-spawn.
- Full mailbox/ledger rejects or defers new work instead of evicting unacknowledged commands.
- Controller restart cannot regress scale-set sequence or cause a second GitHub JIT issue call for an already-issued handle.
- Missing JIT-bearing mailbox can be rebuilt only from durable commanded placement + central descriptor cache.
- An unregistered higher node generation cannot adopt a placement; the currently registered newer incarnation can.
- Back-to-back admissions cannot oversubscribe stale heartbeat capacity.
- No distributed capacity is advertised without a concrete node resource backing.
