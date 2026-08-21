# Distributed Runner Farm Progress

Last updated: 2026-08-21

## Active checkpoint

- PR #37 and every review remediation are merged. Production follow-ups through
  PR #64 fixed materialization, scale-set selectors, demand-driven capacity,
  startup session health, fresh initial snapshots, and fairness-cursor drift.
- The Dookie controller runs immutable clean release
  `10aae171711af21936345fe87a5ba095b09f8ad4` from `/opt/ci-runner-farm`.
  Controller configuration, sidecar state, placement state, and GitHub
  credentials remain on Dookie, not Unraid flash.
- Registered nodes: Dookie (Linux native), Squirts (Linux native), Steamy
  (Windows native), Steamy WSL (Linux native), and Tootie (Linux container).
- Tootie advertises 16000 CPU millis and 16 GiB. Its node binary,
  configuration, TLS, state, logs, and operator projection live under
  `/mnt/cache/appdata/ci-runner-farm/distributed-node`; only the PID is tmpfs.
- Production owns seven scale sets: Rust, Python, TypeScript, Go, Ops, System,
  and Residential Egress. After final qualification and test-scale-set cleanup
  on 2026-08-21, the clean restored set used IDs 238-244; IDs are runtime
  evidence, not durable configuration.
- Real GitHub jobs passed on Dookie, Squirts, Steamy, Steamy WSL, and Tootie's
  container backend. A live Dookie cancellation observed TERM, completed as
  cancelled in GitHub, removed the complete runner process group, returned
  resources, and removed runner credentials.
- Final-release qualification used dedicated temporary Linux and Windows scale
  sets so shared production Ops demand could not select or disrupt unrelated
  organization jobs. Runs `32525456114` (Tootie container), `32525954093`
  (Dookie), `32526980166` (Squirts), `32527137309` (Steamy WSL), and
  `32527420841` (Steamy Windows) all passed. Each native run reported the
  expected host, OS, architecture, and service cgroup; the container run also
  proved `/.dockerenv`. Controller placement evidence tied the WSL and Windows
  runs to node IDs `steamy-wsl` and `steamy`. All temporary scale sets and JIT
  runners were removed, the seven production pools were recreated eligible,
  all five nodes returned full resources, and the placement/offer ledgers were
  empty.
- The acceptance workflow now offers a constrained
  `ci-pool-acceptance-linux` dispatch choice. Its default remains
  `ci-pool-ops` for ordinary production-ops checks; fleet qualification should
  provision and select the isolated label.
- Classic replacement is complete. Busy classic jobs were quarantined and
  allowed to finish; their exact registrations and containers were then retired.
  GitHub and Docker both reported zero classic runners, and the temporary runner
  group was empty before deletion.
- Fresh main-branch Build Plugin and Release Please workflows completed through
  distributed Ops runners after the PR #64 deployment. The Lint workflow's
  distributed Ubuntu and Windows jobs passed; its shell job exposed an
  unguarded acceptance-workflow selector, now corrected in this branch.
- Current verification on the controller-projection/WebUI branch: **130 Rust
  tests**, **122 Elixir tests**, distributed-status, Fleet UI behavior, shell
  syntax, and UI JavaScript tests pass.

### Historical implementation checkpoint

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
- Process-birth identity commit: `e822b7a8091d7509a670a7dd3bda2ff163f0ad00`; Steamy WSL and Agent OS both passed stable identity + forged-live-PID rejection on the exact SHA.
- Hostname/MagicDNS transport commit: `158226bbc824b4d8a6a0d9c3edd2212fb3e0e1a7`; Steamy WSL and Agent OS both pass exact endpoint/config tests and resolve `dookie` through tailnet MagicDNS.
- Node placement-state GC commit: `e092e625e8d38a7553a14dbd58dc9ce01c92490b`; Steamy WSL and Agent OS each passed all 14 crash-safe GC/state tests on the exact SHA.
- Controller terminal-placement compaction commit: `f63fd023baba2741cd817162e7cb35e69a413fe1`; schema-v1 migration, compact schema-v2 replay tombstones, and 105/105 controller tests are green.
- Shared Unraid runner-runtime checkpoint: `58a72447dfe9e7e883ff23d51cc2b1a47f0de652`; `runner-runtime.sh` is packaged mode 0755 and the solitary full legacy `final-release-gate.sh` exits 0.
- Portable runtime-identity checkpoint: `f00c26707152898bcffd1428fa1bdb6404c98139`; legacy native spawned-state migration plus tagged native/container identities are green, and PR #37 hosted Build Plugin, Shell/PHP, Ubuntu, and Windows jobs are all green/CLEAN on this SHA.
- Bounded container-adapter client checkpoint: `b46646ef928ed2f28cde14b966040e8d57ee7ab9`; 7/7 adapter behavior tests prove stdin-only JIT delivery, bounded typed output, oversized-response rejection, and timeout process-tree containment.
- Controller-approved container executor checkpoint: `f1684b9d50fe4c0b85e88a975225c163e44f9cc8`; crash adoption, exact-ID cancellation, uncertain start, lost-container reporting, and cross-backend identity preservation are covered.
- Current implementation checkpoint: the local Unraid adapter endpoint maps controller-approved Start/Inspect/Cancel requests onto `runner-runtime.sh`, with private crash-recovery state, exact container identity fencing, local resource/config validation, and no duplicate scheduler or GitHub JIT-retirement authority.
- Unraid pool-policy mapping: validated legacy single-fleet or V2 pool configuration exports as the controller's exact typed `demand.pools` JSON for x86_64/arm64 container nodes; export is read-only and never enables distributed mode.
- Historical deployment state at this checkpoint: five nodes were staged while
  distributed demand remained disabled and classic admission remained effective.
- Verification: **120 Rust tests**, strict Clippy for all Rust crates, Windows GNU all-target checks plus Windows-target Clippy for node/scheduler, all Go scale-set packages, **109 Elixir controller tests**, Steamy WSL + Agent OS native process-tree/process-birth-identity/MagicDNS/node-GC proofs, live TLS 1.3 already-connected-session revocation proof, certificate/admin helper smokes, verified Linux service bundle install/runtime smoke, `actionlint`, shell syntax, and `git diff --check`
- PR #37 first hosted run: Ubuntu distributed-core green; Windows Clippy and the legacy final-release constant assertion failed. Both were fixed in `5f65e77`.
- PR #37 second hosted run on `5f65e77`: Windows Clippy passed, but native Windows config tests exposed Unix-only fixture paths; Ubuntu bundle build exposed a locally ignored/untracked node example; legacy regression exposed the intentional routed-workflow count increase from 7 to 8. All three landed in `b297b04`.
- PR #37 third hosted run on `b297b04`: Ubuntu distributed-core green including bundle verification; native Windows Rust tests green; Windows formatter exposed CRLF normalization, fixed by `d493f4b`.
- PR #37 fourth hosted run on `d493f4b`: Ubuntu remained green and Windows advanced through formatting/Rust to Elixir tests, exposing POSIX-only mode validation in two durable-state readers. Those were fixed in `0e95021`; Unix still requires exact `0600`, Windows uses ACL-backed regular-file semantics plus schema/checksum validation. The same run surfaced a pre-existing reconcile crash-boundary test that assumed `setsid` direct-child parentage; `0e95021` strengthens it to verify the authoritative prepublication identity record (PID/starttime/PGID/SID/token) instead.
- PR #37 hosted runs for `0e95021` are fully green: both the distributed lint workflow and Build Plugin workflow completed successfully, proving native Windows Rust+Elixir, Ubuntu bundle verification, and the full legacy behavioral regression suite on the recovery fixes.
- PR #37 hosted runs for `a114746` are fully green with merge state CLEAN: Build Plugin, legacy Shell/PHP regression suite, Ubuntu distributed-core/bundle verification, and native Windows distributed-core all pass with live certificate authorization included.
- Process-tree containment on `6b3bce1` is proven on the requested real hosts: Steamy WSL2 x86_64 with Rust 1.97.1 passed the stubborn-descendant Unix process-group TERM→KILL test in 5.05s after a clean checkout; Agent OS native Windows x64/MSVC passed suspended-start + Job Object descendant termination in 1.39s after a clean checkout. Hosted Ubuntu/legacy/plugin CI also pass `6b3bce1`. The hosted-Windows-only PowerShell test-fixture issue was replaced by the Win32 ToolHelp proof in `31ebe51`; Agent OS reran that exact fixture in 0.14s.
- Process-birth identity on `e822b7a` is proven on both requested hosts: Steamy WSL passed stable/nonzero Linux `/proc/<pid>/stat` birth-token capture plus forged-live-PID rejection; Agent OS passed stable/nonzero Windows `GetProcessTimes` creation-token capture plus the same forged-live-PID recovery rejection.
- Real tailnet DNS evidence for the hostname checkpoint: Steamy WSL `getaddrinfo("dookie")` and Agent OS `.NET DNS`/`Resolve-DnsName dookie` all resolve `dookie.manatee-triceratops.ts.net` to `100.88.16.79`. Node transport now accepts that hostname shape and re-resolves it on every reconnect rather than pinning the first IP.

This document is the living implementation tracker. Update this checkpoint section whenever the branch, PR, commits, verification evidence, or remaining-work inventory changes.

## Current state

The distributed control/data path exists end to end, five live nodes are
registered, production scale sets are active, and classic production runners
have been replaced. The classic implementation remains available as a guarded
rollback/legacy backend, not as active production capacity.

The implemented path is:

`GitHub scale-set adapter (Go) -> Elixir demand/reconciliation -> Rust scheduler -> PlacementCoordinator -> mTLS node mailbox -> Rust node runtime`

## Verified today

- Rust workspace: **120 tests pass** across protocol, scheduler service, node unit tests, native/container executor integration, bounded container-adapter behavior, process-tree/process-birth identity, hostname endpoint parsing/resolution, crash-safe placement GC, and hostile runner-package/cache tests.
- Rust strict Clippy: all three crates pass independently with `-D warnings`.
- Windows portability: both `crf-node --all-targets` and `crf-scheduler --all-targets` cross-check successfully for `x86_64-pc-windows-gnu`. Native MSVC remains covered by the Windows GitHub-hosted CI job because DOOKIE does not have Microsoft linker tools.
- Windows service packaging proof: on 2026-08-20, Agent OS (`AGENT-OS`, Windows 11 Pro 10.0.26200 x64) installed the `f0c7687` GNU x86_64 release through the packaged PowerShell installer. SCM reported an own-process, Manual-start `CiRunnerFarmNode` service running as `NT AUTHORITY\\LocalService`, with the quoted `--windows-service` binary path and bounded restart policy; the installed binary reported `crf-node 0.1.0`, the ProgramData ACL contained only SYSTEM, Administrators, and Local Service, and SCM assigned PID 5188 on start. The intentionally unprovisioned example certificate/controller paths then produced the expected stopped/exit-code-1 boundary. The service and all three test directories were deleted and absence was verified. This proves installation and SCM dispatch only; connected TLS registration, cooperative stop while running, runner execution, and restart adoption still require real controller trust/configuration.
- Elixir controller: **110 tests pass** with warnings-as-errors compilation, including real Rust scheduler Port integration, strict production-config tests, managed Go-sidecar lifecycle tests, conservative orphan/remediation behavior, dynamic certificate authorization, live TLS session revocation, schema-v1 placement-state migration, compact schema-v2 terminal replay tombstones, and redacted operator status/actions.
- Live Windows distributed-node acceptance on 2026-08-20: an isolated controller built from `dc84541` listened on Dookie port 7444 with a seven-day acceptance CA and automatic GitHub reconciliation disabled. Agent OS installed the packaged x86_64 node as a Manual `LocalService`, completed TLS 1.3 mutual authentication, and appeared in the operator snapshot as Windows/x86_64 generation 1 with the native-process backend and full 1000m/1 GiB capacity. The live snapshot exposed and drove the list-backed orphan-status fix in `dc84541`; after rebuilding, the same production-config path rendered cleanly. SCM Stop/Start produced a new PID and controller-fenced generation 2; generation-specific drain and undrain both succeeded. In-memory revoke-all closed the established `100.109.125.128` session, config reload restored the exact fingerprint, and the node reconnected. This proves packaging, service control, mTLS registration/revocation, controller reconnect, node restart fencing, and operator actions. A real JIT runner/job was not executed because Tootie's scale-set compatibility/ownership evidence and credentials were not reachable through its closed SSH service, while Labby advertised connected `unRAID` tooling but returned an empty Code Mode catalog. The live service/controller and short-lived acceptance CA were removed after verification.
- Go scale-set adapter: every package in `tools/crf-scaleset` passes.
- GitHub workflow: `actionlint` passes. Distributed core CI builds/tests Rust and Elixir on Ubuntu and Windows and exposes the real scheduler binary to controller tests.
- `git diff --check` passes and isolated Cargo target directories are ignored.
- Linux service packaging: a clean `b297b04` Ubuntu 26.04 x86_64 bundle was assembled at 33,546,551 bytes with `GIT_SHA=b297b04d53f477655e59bfdab1f8e59105abc8a6` and `GIT_DIRTY=false`, then passed the full checksum, symlink-boundary, packaged-binary, OTP-release, and twice-idempotent `DESTDIR` verifier. The builder now rejects dirty/untracked source trees by default and requires every static packaging input to be Git-tracked. Hosted Ubuntu CI also builds and verifies the bundle successfully on this SHA.
- Hosted-CI portability repair proofs: Linux node config tests 5/5, Windows-target Clippy green, `runner-pools.sh` 118/118, repaired dirty-validation bundle verified end to end, and its packaged `node-env.example` contains the real `CRF_RUNNER_CACHE_DIR` contract.
- Certificate authorization proof: `PeerRegistry` supports atomic overlap rotation, revoke-all, malformed-replacement rollback, and per-frame live-session reauthorization; a real TLS 1.3 mTLS integration test revokes an already-open node session and observes closure on its next heartbeat. `crf-cert-fingerprint` matches OpenSSL DER SHA-256 exactly; `crf-peer-admin` status/reload/revoke-all wrappers pass smoke tests and require explicit `--force` for revoke-all. A staged certificate-enabled 33,550,571-byte Linux bundle passed the complete bundle verifier with packaged admin helpers and systemd `ExecReload`.
- Retention proof: node GC at `e092e62` passes 14/14 on both Steamy WSL and Agent OS. Controller placement state now migrates schema v1 terminal records to schema-v2 replay tombstones, keeps only live placements in scheduling snapshots, and passes 105/105 controller tests. A representative deterministic terminal record shrinks from 430 bytes to 162 bytes (**62.3% reduction**); 65,536 representative tombstones are approximately 10.12 MiB of payload under the 16 MiB file ceiling.

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
- durable placement ledger with atomic private state file; live placements retain scheduling fields, terminal placements compact immediately to replay-fence tombstones, schema v1 migrates forward, and no JIT descriptors are written there;
- deliberate non-persistence of JIT-bearing mailbox commands; a lost commanded mailbox entry is rebuilt from the central replay cache;
- automatic reconciliation loop is implemented but opt-in;
- scale-set transport/session failure resets activation and reapplies sessions on the next tick;
- runnable portable `crf-node` daemon with explicit resource budget, durable generation, reconnect backoff, resource accounting, terminal outbox, and graceful shutdown;
- native Linux/Windows runner lifecycle, private materialization, file-backed logs, cancellation, and PID recovery;
- portable node runtime identity with backward-compatible native v1 migration and tagged native-process/container v2 spawned state;
- bounded local container-adapter wire/client with JIT only on stdin, hard request/response limits, process-tree timeout containment, exact immutable container identity, and no GitHub credentials on nodes;
- controller-approved container executor with inspect-before-retry crash recovery, exact-ID cancellation, durable lost-container reporting, and fail-closed backend identity mismatch behavior;
- local Unraid Start/Inspect/Cancel adapter over the shared runner runtime, with deterministic placement/container/reservation identities, private phase state, exact-label discovery, terminal-before-removal persistence, and safe replay of prepared or secret-pending starts;
- explicit daemon backend selection: existing configuration defaults to `native_process`, while opt-in `container` mode requires only an absolute adapter program and bounded timeout and advertises only the instantiated backend/capability;
- strict schema-versioned portable controller configuration with legacy fallback and a fully supervised distributed child tree;
- optional OTP-owned `crf-scaleset` sidecar with bounded socket readiness and verified SIGTERM/SIGKILL child cleanup;
- managed pinned GitHub runner acquisition using Rustls HTTPS, exact byte count + SHA-256 verification, TAR/ZIP traversal/link defenses, immutable content-addressed cache, cache-tamper detection, OS-backed cache locking, and current-plus-one-rollback pruning;
- placement-loss grace tracking that surfaces nonterminal work on unavailable node incarnations as orphans without automatically retrying it;
- explicit force-abandon remediation that re-checks live node health, requires confirmation, terminalizes the durable placement, removes stale mailbox work, and retires matching central JIT state;
- distribution-tagged Linux service bundle containing the self-contained OTP controller release, Rust scheduler/node, Go scale-set sidecar, hardened systemd units, versioned atomic install layout, checksums/build metadata, fake-root/idempotent installer verification, and CI bundle smoke.
- packaged `crf-operator-status` local-RPC helper exposing a deterministic secret-free snapshot of nodes, resources, offers, placements, replay fences, orphan/pool state, peer authorization counts, and sidecar health.
- generation-fenced operator drain/undrain and explicit `force-abandon ... --force` actions, with fixed command grammar, safe identifier validation, and redacted mutation results.

## Recovery invariants covered by tests

- no JIT secret in Rust Debug, Elixir Inspect, durable node placement state, controller placement state, or recovery metadata;
- exact node-message replay returns the same response bytes;
- stale or unregistered node generations cannot self-authorize;
- a legitimate newly registered generation can adopt a surviving placement from the same node;
- stale old-generation mailbox commands are discarded when a surviving placement is observed on the new generation;
- uncommitted node commands are never evicted;
- original accepted/rejected command outcome is replayed exactly;
- placement intent is durable before process creation;
- native intent-only crash state never auto-spawns a duplicate; container intent recovery inspects first and retries start only after explicit `absent`;
- dead persisted runner PIDs become durable `runner_process_lost` reports and missing previously identified containers become `container_lost`;
- container cancellation carries the exact persisted immutable ID, so a reused name cannot target a newer runtime;
- native/container runtime identity mismatches preserve the foreign durable state and fail closed instead of manufacturing a terminal result;
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

1. Complete authenticated real-browser verification of the expanded Unraid
   distributed-fleet UI; backend, projection, DOM behavior, and responsive
   source-level tests are complete, but this checkout has no authenticated
   Unraid browser session.
2. Complete the controller/node restart and network-partition matrix plus
   orphan/force-abandon acceptance under production pool identities.
3. Add automated CA/server-certificate rotation, more target-distribution Linux
   bundles, sustained fairness/load tests, and longer-horizon replay-fence
   archival if operational scale requires it.

## Deployment status

The controller and five nodes are deployed and registered. Tootie's node is
cache-resident and integrated with Docker start/stop events. Compatibility,
five-node execution, drain rotation, duplicate-handle fencing, cancellation,
production scale-set startup, and non-disruptive classic retirement are proven.
The active production path is distributed.
