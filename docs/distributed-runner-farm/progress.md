# Distributed Runner Farm Progress

Last updated: 2026-08-19

## Active checkpoint

- Worktree: `/home/jmagar/workspace/ci-runner-farm/.claude/worktrees/distributed-elixir-rust`
- Branch: `worktree-distributed-elixir-rust`
- Base: current `origin/main` at `00c0c95349db5ff04d15a87525ae4e4d50ae4414`
- Pull request: draft PR #37, `Distributed Elixir/Rust runner farm control plane`
- Initial implementation commit: `5efe6b6ce0325924e93b5ec1c1613339ab6004cc`
- Tracker checkpoint commit: `f6ed39faa52017a7af16778a1b1464d1ee5d3977`
- Packaging checkpoint commit: `5f65e77fc809391536c831a2b1d295585d0361d2`
- Hosted-CI portability repair commit: `b297b04d53f477655e59bfdab1f8e59105abc8a6`
- Current Windows LF-normalization checkpoint: pending commit/push
- Deployment: not deployed; existing Unraid production behavior remains untouched
- Verification: 87 Rust tests, strict Clippy for all Rust crates, Windows GNU all-target checks plus Windows-target Clippy for node/scheduler, all Go scale-set packages, 96 Elixir controller tests, verified Linux service bundle install/runtime smoke, `actionlint`, shell syntax, and `git diff --check`
- PR #37 first hosted run: Ubuntu distributed-core green; Windows Clippy and the legacy final-release constant assertion failed. Both were fixed in `5f65e77`.
- PR #37 second hosted run on `5f65e77`: Windows Clippy passed, but native Windows config tests exposed Unix-only fixture paths; Ubuntu bundle build exposed a locally ignored/untracked node example; legacy regression exposed the intentional routed-workflow count increase from 7 to 8. All three landed in `b297b04`.
- PR #37 third hosted run on `b297b04`: Ubuntu distributed-core is green, including bundle build/verification; native Windows Rust tests are green; Windows only failed at `mix format --check-formatted` because checkout CRLF differed from formatter LF. A narrow `.gitattributes` LF contract is the pending checkpoint. Legacy behavioral regressions are still completing.

This document is the living implementation tracker. Update this checkpoint section whenever the branch, PR, commits, verification evidence, or remaining-work inventory changes.

## Current state

The distributed control/data path now exists end to end in code but remains opt-in and is not deployed. Existing Unraid production behavior is unchanged.

The implemented path is:

`GitHub scale-set adapter (Go) -> Elixir demand/reconciliation -> Rust scheduler -> PlacementCoordinator -> mTLS node mailbox -> Rust node runtime`

## Verified today

- Rust workspace: **87 tests pass** across protocol, scheduler service, node unit tests, native executor integration, and hostile runner-package/cache tests.
- Rust strict Clippy: all three crates pass independently with `-D warnings`.
- Windows portability: both `crf-node --all-targets` and `crf-scheduler --all-targets` cross-check successfully for `x86_64-pc-windows-gnu`. Native MSVC remains covered by the Windows GitHub-hosted CI job because DOOKIE does not have Microsoft linker tools.
- Elixir controller: **96 tests pass** with warnings-as-errors compilation, including real Rust scheduler Port integration, strict production-config tests, managed Go-sidecar lifecycle tests, and conservative orphan/remediation behavior.
- Go scale-set adapter: every package in `tools/crf-scaleset` passes.
- GitHub workflow: `actionlint` passes. Distributed core CI builds/tests Rust and Elixir on Ubuntu and Windows and exposes the real scheduler binary to controller tests.
- `git diff --check` passes and isolated Cargo target directories are ignored.
- Linux service packaging: a clean `b297b04` Ubuntu 26.04 x86_64 bundle was assembled at 33,546,551 bytes with `GIT_SHA=b297b04d53f477655e59bfdab1f8e59105abc8a6` and `GIT_DIRTY=false`, then passed the full checksum, symlink-boundary, packaged-binary, OTP-release, and twice-idempotent `DESTDIR` verifier. The builder now rejects dirty/untracked source trees by default and requires every static packaging input to be Git-tracked. Hosted Ubuntu CI also builds and verifies the bundle successfully on this SHA.
- Hosted-CI portability repair proofs: Linux node config tests 5/5, Windows-target Clippy green, `runner-pools.sh` 118/118, repaired dirty-validation bundle verified end to end, and its packaged `node-env.example` contains the real `CRF_RUNNER_CACHE_DIR` contract.

## Implemented controller/runtime behavior

- strict versioned Rust/Elixir node wire with unknown-field rejection and bounded four-byte framing;
- TLS 1.3 mutual authentication and certificate-to-node identity binding;
- monotonic node generations and authenticated newer-generation adoption for surviving runners;
- persistent Rust scheduler process used by Elixir, with no duplicate scheduler implementation in BEAM;
- controller-side effective-capacity view that subtracts heartbeat-gap placement reservations and node-bound offers exactly once;
- serialized placement commit gate and node mailbox;
- resource-backed distributed offer ledger equivalent to the legacy single-host offer reservations;
- offer planner that rotates pool order, honors pool ceilings, uses Rust placement, and advertises only resource-backed capacity;
- Go scale-set adapter retained as the GitHub protocol/JIT boundary;
- same-UID Unix-socket authorization instead of an unnecessary root-only controller requirement;
- durable scale-set request sequence, so an Elixir restart cannot regress the sidecar replay fence;
- private JIT descriptor replay cache in the Go adapter (directory 0700, files 0600), never on nodes;
- ambiguous one-shot JIT issuance never calls GitHub twice and can be explicitly retired;
- non-secret `read_jit_state` recovery endpoint;
- durable placement ledger with atomic private state file; no JIT descriptors are written there;
- deliberate non-persistence of JIT-bearing mailbox commands; a lost commanded mailbox entry is rebuilt from the central replay cache;
- automatic reconciliation loop is implemented but opt-in;
- scale-set transport/session failure resets activation and reapplies sessions on the next tick;
- runnable portable `crf-node` daemon with explicit resource budget, durable generation, reconnect backoff, resource accounting, terminal outbox, and graceful shutdown;
- native Linux/Windows runner lifecycle, private materialization, file-backed logs, cancellation, and PID recovery;
- strict schema-versioned portable controller configuration with legacy fallback and a fully supervised distributed child tree;
- optional OTP-owned `crf-scaleset` sidecar with bounded socket readiness and verified SIGTERM/SIGKILL child cleanup;
- managed pinned GitHub runner acquisition using Rustls HTTPS, exact byte count + SHA-256 verification, TAR/ZIP traversal/link defenses, immutable content-addressed cache, cache-tamper detection, OS-backed cache locking, and current-plus-one-rollback pruning;
- placement-loss grace tracking that surfaces nonterminal work on unavailable node incarnations as orphans without automatically retrying it;
- explicit force-abandon remediation that re-checks live node health, requires confirmation, terminalizes the durable placement, removes stale mailbox work, and retires matching central JIT state;
- distribution-tagged Linux service bundle containing the self-contained OTP controller release, Rust scheduler/node, Go scale-set sidecar, hardened systemd units, versioned atomic install layout, checksums/build metadata, fake-root/idempotent installer verification, and CI bundle smoke.

## Recovery invariants covered by tests

- no JIT secret in Rust Debug, Elixir Inspect, durable node placement state, controller placement state, or recovery metadata;
- exact node-message replay returns the same response bytes;
- stale or unregistered node generations cannot self-authorize;
- a legitimate newly registered generation can adopt a surviving placement from the same node;
- stale old-generation mailbox commands are discarded when a surviving placement is observed on the new generation;
- uncommitted node commands are never evicted;
- original accepted/rejected command outcome is replayed exactly;
- placement intent is durable before process creation;
- intent-only crash state never auto-spawns a duplicate;
- dead persisted runner PIDs become durable `runner_process_lost` reports;
- terminal reports remain pending until controller acceptance;
- a dropped terminal response does not mark the report delivered;
- a persisted commanded placement with a lost mailbox rebuilds the command exactly once from the central cached JIT descriptor;
- Go JIT replay works through a fresh control object without another GitHub call;
- a truly ambiguous `issue_started` state refuses reissuance but remains retireable;
- controller placement and scale-set sequence corruption fail closed;
- back-to-back placements cannot oversubscribe stale heartbeat capacity;
- a pool work handle cannot own two distributed offers;
- assigned offers do not expire while the handle is in flight;
- advertised scale-set capacity equals resource-backed nonterminal placements plus live offers.

## Remaining major work

1. Add certificate enrollment/rotation/revocation, additional target-distribution Linux bundles, and Windows service packaging.
2. Unify the existing Unraid Docker execution path behind the distributed runtime/backend boundary while preserving legacy default behavior.
3. Add API/UI surfaces for distributed nodes, pools, offers, placements, orphans/remediation, drains, package versions, and recovery state.
4. Run live Linux and Windows end-to-end GitHub Actions smokes, a real multi-node scale-set smoke, controller/node restart/partition matrix, sustained load/fairness tests, and adversarial release/security review.
5. Harden explicit cancellation with Unix process groups and Windows Job Objects, persist process-start identity to close PID-reuse ambiguity, add hostname/MagicDNS controller addressing, and finish durable-state/cache retention GC.

## Deployment status

Nothing in this worktree has been deployed. The distributed loop is opt-in and the existing live Unraid runner farm has not been restarted or altered by this work.
