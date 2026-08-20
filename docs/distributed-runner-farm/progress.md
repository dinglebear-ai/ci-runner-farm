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
- Windows LF-normalization commit: `d493f4bd6120cf7ffce5b602254d3611f2126b12`
- Cross-platform recovery commit: `0e950214be70aac916dcce07e7115794dfdf65be`
- Live certificate authorization commit: `a114746e6cd071510cbdc34adcea69730cedccd1`
- Process-tree containment commit: `6b3bce10b3f39ab1a18a0ee1f2cd4ca3680d1d5a`.
- Hosted-Windows process-tree test fix commit: `31ebe51f6a53d2f2ae50dd88d2f5e2d17f094762`; Agent OS rerun passed the ToolHelp-based test in 0.14s.
- Current process-birth identity checkpoint: pending commit/push; Linux/Windows live-host identity probes pending.
- Deployment: not deployed; existing Unraid production behavior remains untouched
- Verification: **91 Rust tests**, strict Clippy for all Rust crates, Windows GNU all-target checks plus Windows-target Clippy for node/scheduler, all Go scale-set packages, **100 Elixir controller tests**, Steamy WSL + Agent OS native process-tree proofs, live TLS 1.3 already-connected-session revocation proof, certificate/admin helper smokes, verified Linux service bundle install/runtime smoke, `actionlint`, shell syntax, and `git diff --check`
- PR #37 first hosted run: Ubuntu distributed-core green; Windows Clippy and the legacy final-release constant assertion failed. Both were fixed in `5f65e77`.
- PR #37 second hosted run on `5f65e77`: Windows Clippy passed, but native Windows config tests exposed Unix-only fixture paths; Ubuntu bundle build exposed a locally ignored/untracked node example; legacy regression exposed the intentional routed-workflow count increase from 7 to 8. All three landed in `b297b04`.
- PR #37 third hosted run on `b297b04`: Ubuntu distributed-core green including bundle verification; native Windows Rust tests green; Windows formatter exposed CRLF normalization, fixed by `d493f4b`.
- PR #37 fourth hosted run on `d493f4b`: Ubuntu remained green and Windows advanced through formatting/Rust to Elixir tests, exposing POSIX-only mode validation in two durable-state readers. Those were fixed in `0e95021`; Unix still requires exact `0600`, Windows uses ACL-backed regular-file semantics plus schema/checksum validation. The same run surfaced a pre-existing reconcile crash-boundary test that assumed `setsid` direct-child parentage; `0e95021` strengthens it to verify the authoritative prepublication identity record (PID/starttime/PGID/SID/token) instead.
- PR #37 hosted runs for `0e95021` are fully green: both the distributed lint workflow and Build Plugin workflow completed successfully, proving native Windows Rust+Elixir, Ubuntu bundle verification, and the full legacy behavioral regression suite on the recovery fixes.
- PR #37 hosted runs for `a114746` are fully green with merge state CLEAN: Build Plugin, legacy Shell/PHP regression suite, Ubuntu distributed-core/bundle verification, and native Windows distributed-core all pass with live certificate authorization included.
- Process-tree containment on `6b3bce1` is proven on the requested real hosts: Steamy WSL2 x86_64 with Rust 1.97.1 passed the stubborn-descendant Unix process-group TERM→KILL test in 5.05s after a clean checkout; Agent OS native Windows x64/MSVC passed suspended-start + Job Object descendant termination in 1.39s after a clean checkout. Hosted Ubuntu/legacy/plugin CI also pass `6b3bce1`. Hosted Windows failed only because the test fixture depended on nested PowerShell publishing a child PID; the Job Object implementation itself passed Agent OS. The pending test fix replaces that fixture with `cmd.exe` + `ping.exe` and discovers the child through Win32 ToolHelp.

This document is the living implementation tracker. Update this checkpoint section whenever the branch, PR, commits, verification evidence, or remaining-work inventory changes.

## Current state

The distributed control/data path now exists end to end in code but remains opt-in and is not deployed. Existing Unraid production behavior is unchanged.

The implemented path is:

`GitHub scale-set adapter (Go) -> Elixir demand/reconciliation -> Rust scheduler -> PlacementCoordinator -> mTLS node mailbox -> Rust node runtime`

## Verified today

- Rust workspace: **87 tests pass** across protocol, scheduler service, node unit tests, native executor integration, and hostile runner-package/cache tests.
- Rust strict Clippy: all three crates pass independently with `-D warnings`.
- Windows portability: both `crf-node --all-targets` and `crf-scheduler --all-targets` cross-check successfully for `x86_64-pc-windows-gnu`. Native MSVC remains covered by the Windows GitHub-hosted CI job because DOOKIE does not have Microsoft linker tools.
- Elixir controller: **100 tests pass** with warnings-as-errors compilation, including real Rust scheduler Port integration, strict production-config tests, managed Go-sidecar lifecycle tests, conservative orphan/remediation behavior, dynamic certificate authorization, and live TLS session revocation.
- Go scale-set adapter: every package in `tools/crf-scaleset` passes.
- GitHub workflow: `actionlint` passes. Distributed core CI builds/tests Rust and Elixir on Ubuntu and Windows and exposes the real scheduler binary to controller tests.
- `git diff --check` passes and isolated Cargo target directories are ignored.
- Linux service packaging: a clean `b297b04` Ubuntu 26.04 x86_64 bundle was assembled at 33,546,551 bytes with `GIT_SHA=b297b04d53f477655e59bfdab1f8e59105abc8a6` and `GIT_DIRTY=false`, then passed the full checksum, symlink-boundary, packaged-binary, OTP-release, and twice-idempotent `DESTDIR` verifier. The builder now rejects dirty/untracked source trees by default and requires every static packaging input to be Git-tracked. Hosted Ubuntu CI also builds and verifies the bundle successfully on this SHA.
- Hosted-CI portability repair proofs: Linux node config tests 5/5, Windows-target Clippy green, `runner-pools.sh` 118/118, repaired dirty-validation bundle verified end to end, and its packaged `node-env.example` contains the real `CRF_RUNNER_CACHE_DIR` contract.
- Certificate authorization proof: `PeerRegistry` supports atomic overlap rotation, revoke-all, malformed-replacement rollback, and per-frame live-session reauthorization; a real TLS 1.3 mTLS integration test revokes an already-open node session and observes closure on its next heartbeat. `crf-cert-fingerprint` matches OpenSSL DER SHA-256 exactly; `crf-peer-admin` status/reload/revoke-all wrappers pass smoke tests and require explicit `--force` for revoke-all. A staged certificate-enabled 33,550,571-byte Linux bundle passed the complete bundle verifier with packaged admin helpers and systemd `ExecReload`.

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

1. Add automated CA/server-certificate rotation, additional target-distribution Linux bundles, and Windows service packaging.
2. Unify the existing Unraid Docker execution path behind the distributed runtime/backend boundary while preserving legacy default behavior.
3. Add API/UI surfaces for distributed nodes, pools, offers, placements, orphans/remediation, drains, package versions, and recovery state.
4. Run live Linux and Windows end-to-end GitHub Actions smokes, a real multi-node scale-set smoke, controller/node restart/partition matrix, sustained load/fairness tests, and adversarial release/security review.
5. Complete Steamy WSL + Agent OS live proof of durable process birth-token recovery, add hostname/MagicDNS controller addressing, and finish durable-state/cache retention GC.

## Deployment status

Nothing in this worktree has been deployed. The distributed loop is opt-in and the existing live Unraid runner farm has not been restarted or altered by this work.
