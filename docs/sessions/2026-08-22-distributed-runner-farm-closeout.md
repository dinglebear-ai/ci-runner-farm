---
date: 2026-08-22 07:18:33 EDT
repo: git@github.com:dinglebear-ai/ci-runner-farm.git
branch: codex/integrate-pool-queue
head: 57fb5fe44a9c4d21fa682dba66e88b371c78416f
session id: 01a02112-d784-78f1-b1f5-7920ff9b1845
working directory: /home/jmagar/workspace/ci-runner-farm
worktree: /home/jmagar/workspace/ci-runner-farm
pr: "#69 Finish distributed runner farm closeout (https://github.com/dinglebear-ai/ci-runner-farm/pull/69)"
beads: crf-8ql, crf-q3t, crf-eg1, crf-wxo, crf-wxo.1-crf-wxo.14, crf-o8x
---

# Distributed runner farm closeout

## User Request

Determine everything already implemented for the Distributed Runner Farm, finish all remaining implementation and review work, integrate the adaptive queueing and JIT cleanup changes, update the Unraid WebUI and documentation, run full five-node acceptance, retire the classic fleet, and land the result.

## Session Overview

The session took the distributed Elixir/Rust control plane from implementation audit through reviewed production cutover. It merged the base distributed farm in PR #37, a sequence of deployment, UI, durability, scheduling, and acceptance follow-ups through PR #67, adaptive queue admission and asynchronous JIT cleanup in PR #68, and the final five-node/cutover remediation in PR #69. PR #69 merged as `db46e8a5c794c0011a8fbf32a0542ef8e82fc826` after all final checks passed.

Production acceptance covered Dookie, Squirts, Steamy WSL, Steamy native Windows, and Tootie container execution. The final live proof showed the classic backend disabled at boot, zero classic containers, zero matching GitHub registrations, an active Dookie controller, and Tootie's node binary and state under `/mnt/cache/appdata/ci-runner-farm/distributed-node` rather than flash.

## Sequence of Events

1. Audited the existing distributed-farm implementation and the remaining controller, node, packaging, migration, WebUI, documentation, and acceptance gaps.
2. Completed and reviewed the Elixir controller, Rust protocol/scheduler/node, Linux systemd packaging, Windows service packaging, Unraid container adapter, and operator tooling; merged PR #37.
3. Added repository-pinned Elixir, Erlang, Go, and Rust worktree bootstrap so detached worktrees could build releases reproducibly.
4. Added cache-resident Unraid node management, distributed WebUI projection, acceptance workflows, materialization fixes, timeout/demand durability, JIT leasing, session barriers, and deployment permission hardening through PRs #40-#67.
5. Moved adaptive queue admission and JIT data reclamation into the integration checkout, ran PR, Phoenix, and Lavra reviews, fixed every surfaced issue, and merged PR #68.
6. Qualified native and container execution across all five requested nodes, including Windows SCM restart and cancellation paths, while keeping temporary acceptance scale sets isolated.
7. Fixed live-only failures: local Docker base-image preflight, offer fairness, controller-state-loss re-registration, terminal replay convergence, classic migration inventory boundaries, rollback authorization, distributed-container stop isolation, and generation-aware placement readoption.
8. Updated the Unraid Fleet/Image/Pools WebUI, README, architecture, progress, packaging, and operational documentation to the shipped distributed-only behavior.
9. Retired the classic Tootie containers and registrations, disabled classic boot admission, removed temporary acceptance resources, closed the relevant beads, waited for green final-head CI, and merged PR #69.
10. Ran the save-session maintenance pass, preserved unrelated/active worktrees, and created `crf-o8x` for the unresolved Beads Dolt history divergence.

## Key Findings

- Controller restarts could make a healthy node fatal on heartbeat rejection; `crates/crf-node/src/daemon.rs:266` now reconnects and re-registers on `unknown_node` and `node_not_registered`.
- An observed placement was incorrectly treated as adopted after a node generation changed; `controller/lib/crf_controller/demand_work.ex:189` now requires both state and generation equality before taking the shortcut.
- Classic migration and stop logic could capture distributed containers; `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-migration.sh:407` defines an exact classic-only inventory contract.
- JIT cleanup had to leave scheduler-critical reconciliation promptly; `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh:260` validates and bounds the asynchronous quarantine sweeper.
- Adaptive queue ranking required bounded persisted runtime learning and global top-K selection; `tools/crf-scaleset/internal/session/admission.go:365` implements the bounded ranking path.
- The Unraid UI now projects the external control plane and suppresses incompatible classic controls in distributed mode at `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page:71` and `:154`.
- The Docker error for `docker.io/local/github-runner:ubuntu-resolute` was not an authentication problem: a host-local base image was being resolved as a registry image. Candidate builds now preflight host-local base images before BuildKit resolution.
- The Claude transcript auto-discovered by the skill (`ce483110-e458-4daf-ab68-dbf7075d310c.jsonl`) belonged to an unrelated July UI session. It was inspected but not used as evidence; the active Codex task ID was obtained from the task registry.

## Technical Decisions

- Preserve controller-authoritative terminal tombstones and make node replay acknowledgement idempotent instead of manually editing durable state after restarts.
- Fail closed around migration, session acquisition, negative GitHub statistics, partial acquisition, runtime identity, and cleanup ownership rather than guessing success.
- Keep distributed node binaries, certificates, state, and cache under cache-backed application storage; flash contains only Unraid configuration metadata.
- Use asynchronous, bounded, serialized JIT garbage collection only after atomically detaching runner directories; retire handles and release reservations after safe detach, not after slow recursive deletion.
- Pin the forked scale-set client by immutable commit/pseudo-version and regenerate vendor content instead of retaining hand-edited vendor drift.
- Keep classic and distributed identities disjoint so classic rollback/stop operations cannot terminate distributed or JIT work.
- Use a normal merge commit for PR #69 to match repository history and retain its reviewed commit sequence.

## Files Changed

The exact session range is `00c0c95349db5ff04d15a87525ae4e4d50ae4414..4a78a752d9494cc6dc527e73eeab9a389ef14603`. It contains 204 distinct paths. `A` means created and `M` means modified; there were no final-range renames or deletions.

| status | path/scope | previous path | purpose | evidence |
|---|---|---|---|---|
| created/modified | controller, protocol, scheduler, and node files listed below | — | Distributed control plane, durable placement, transport, TLS, native/container execution, Windows service | PR #37 and follow-up PRs |
| created/modified | packaging, scripts, workflows, and repository toolchain files listed below | — | Reproducible bundles, services, Windows installer, pinned worktrees, acceptance and release gates | PRs #37, #40-#47, #66, #69 |
| created/modified | Unraid plugin pages, lifecycle hooks, adapters, migration/runtime scripts | — | Cache-resident node management, distributed projection, safe migration and execution | PRs #37, #45-#46, #58, #65, #69 |
| created/modified | scale-set helper, vendor pin, queue admission, and JIT cleanup files | — | Deep queue ranking, persistence, exact acquisition, context-aware calls, asynchronous cleanup | PR #68 |
| created/modified | README and distributed-farm documentation listed below | — | Shipped architecture, packaging, operations, acceptance, and cutover state | PRs #37, #58, #68, #69 |

Complete path inventory:

```text
A .gitattributes
A .github/actionlint.yaml
A .github/workflows/distributed-farm-acceptance.yaml
M .github/workflows/lint.yml
M .github/workflows/package-plugins.yml
M .github/workflows/release-please.yml
M .github/workflows/release.yml
M .gitignore
A .mise.toml
A Cargo.lock
A Cargo.toml
M README.md
M build-plg.sh
A controller/.formatter.exs
A controller/lib/crf_controller/application.ex
A controller/lib/crf_controller/capacity_view.ex
A controller/lib/crf_controller/controller_config.ex
A controller/lib/crf_controller/demand_coordinator.ex
A controller/lib/crf_controller/demand_work.ex
A controller/lib/crf_controller/framing.ex
A controller/lib/crf_controller/identifier.ex
A controller/lib/crf_controller/ingress.ex
A controller/lib/crf_controller/node.ex
A controller/lib/crf_controller/node_command.ex
A controller/lib/crf_controller/node_mailbox.ex
A controller/lib/crf_controller/node_registry.ex
A controller/lib/crf_controller/offer.ex
A controller/lib/crf_controller/offer_ledger.ex
A controller/lib/crf_controller/offer_planner.ex
A controller/lib/crf_controller/operator_actions.ex
A controller/lib/crf_controller/operator_projection.ex
A controller/lib/crf_controller/operator_snapshot.ex
A controller/lib/crf_controller/peer_authorizer.ex
A controller/lib/crf_controller/peer_identity.ex
A controller/lib/crf_controller/peer_registry.ex
A controller/lib/crf_controller/placement.ex
A controller/lib/crf_controller/placement_coordinator.ex
A controller/lib/crf_controller/placement_health.ex
A controller/lib/crf_controller/placement_ledger.ex
A controller/lib/crf_controller/placement_state_store.ex
A controller/lib/crf_controller/placement_tombstone.ex
A controller/lib/crf_controller/pool_policy.ex
A controller/lib/crf_controller/resources.ex
A controller/lib/crf_controller/scaleset_client.ex
A controller/lib/crf_controller/scaleset_sequence.ex
A controller/lib/crf_controller/scaleset_sidecar.ex
A controller/lib/crf_controller/scaleset_transport.ex
A controller/lib/crf_controller/scaleset_wire.ex
A controller/lib/crf_controller/scheduler.ex
A controller/lib/crf_controller/scheduler_client.ex
A controller/lib/crf_controller/scheduler_wire.ex
A controller/lib/crf_controller/secret.ex
A controller/lib/crf_controller/tls_connection.ex
A controller/lib/crf_controller/tls_options.ex
A controller/lib/crf_controller/tls_server.ex
A controller/lib/crf_controller/wire.ex
A controller/lib/crf_controller/work_identity.ex
A controller/mix.exs
A controller/test/capacity_view_test.exs
A controller/test/controller_config_test.exs
A controller/test/demand_coordinator_test.exs
A controller/test/ingress_test.exs
A controller/test/node_command_test.exs
A controller/test/node_mailbox_test.exs
A controller/test/node_registry_test.exs
A controller/test/offer_ledger_test.exs
A controller/test/operator_actions_test.exs
A controller/test/operator_snapshot_test.exs
A controller/test/peer_registry_test.exs
A controller/test/placement_coordinator_test.exs
A controller/test/placement_health_test.exs
A controller/test/placement_ledger_test.exs
A controller/test/placement_state_store_test.exs
A controller/test/placement_tombstone_test.exs
A controller/test/pool_policy_test.exs
A controller/test/scaleset_client_test.exs
A controller/test/scaleset_sequence_test.exs
A controller/test/scaleset_sidecar_test.exs
A controller/test/scaleset_transport_test.exs
A controller/test/scaleset_wire_test.exs
A controller/test/scheduler_client_test.exs
A controller/test/scheduler_test.exs
A controller/test/scheduler_wire_test.exs
A controller/test/test_helper.exs
A controller/test/tls_revocation_integration_test.exs
A controller/test/transport_primitives_test.exs
A controller/test/wire_test.exs
A crates/crf-node/Cargo.toml
A crates/crf-node/src/agent.rs
A crates/crf-node/src/command_ledger.rs
A crates/crf-node/src/command_processor.rs
A crates/crf-node/src/config.rs
A crates/crf-node/src/container_adapter.rs
A crates/crf-node/src/container_executor.rs
A crates/crf-node/src/controller_endpoint.rs
A crates/crf-node/src/daemon.rs
A crates/crf-node/src/generation.rs
A crates/crf-node/src/lib.rs
A crates/crf-node/src/main.rs
A crates/crf-node/src/native_executor.rs
A crates/crf-node/src/native_materializer.rs
A crates/crf-node/src/node_executor.rs
A crates/crf-node/src/operator_projection.rs
A crates/crf-node/src/placement_state.rs
A crates/crf-node/src/process_identity.rs
A crates/crf-node/src/process_tree.rs
A crates/crf-node/src/runner_archive.rs
A crates/crf-node/src/runner_manifest.rs
A crates/crf-node/src/runner_package.rs
A crates/crf-node/src/runtime.rs
A crates/crf-node/src/system_probe.rs
A crates/crf-node/src/transport.rs
A crates/crf-node/src/windows_service.rs
A crates/crf-node/tests/container_executor.rs
A crates/crf-node/tests/native_executor.rs
A crates/crf-node/tests/process_tree.rs
A crates/crf-node/tests/runner_package.rs
A crates/crf-protocol/Cargo.toml
A crates/crf-protocol/src/lib.rs
A crates/crf-protocol/src/wire.rs
A crates/crf-scheduler/Cargo.toml
A crates/crf-scheduler/src/lib.rs
A crates/crf-scheduler/src/main.rs
A crates/crf-scheduler/src/service.rs
M deploy.sh
A docs/distributed-runner-farm/README.md
A docs/distributed-runner-farm/architecture.md
A docs/distributed-runner-farm/certificate-lifecycle.md
A docs/distributed-runner-farm/controller-config.example.json
A docs/distributed-runner-farm/controller-config.md
A docs/distributed-runner-farm/implementation-plan.md
A docs/distributed-runner-farm/progress.md
A docs/distributed-runner-farm/protocol-contract.md
A docs/distributed-runner-farm/runner-manifest.example.json
A docs/distributed-runner-farm/runner-packages.md
A docs/distributed-runner-farm/service-packaging.md
A docs/distributed-runner-farm/spec.md
A packaging/distributed/README.md
A packaging/distributed/admin/crf-cert-fingerprint
A packaging/distributed/admin/crf-operator-status
A packaging/distributed/admin/crf-peer-admin
A packaging/distributed/examples/node-env.example
A packaging/distributed/install.sh
A packaging/distributed/systemd/ci-runner-farm-controller.service
A packaging/distributed/systemd/ci-runner-farm-node.service
A packaging/distributed/windows/Install-CrfNodeService.ps1
A packaging/distributed/windows/node-env.example
A scripts/build-distributed-bundle.sh
A scripts/build-distributed-windows-node.ps1
A scripts/verify-distributed-bundle.sh
A scripts/worktree-setup.sh
M src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
M src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page
M src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page
M src/usr/local/emhttp/plugins/ci-runner-farm/event/docker_started
M src/usr/local/emhttp/plugins/ci-runner-farm/event/stopping_docker
M src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php
A src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-container-adapter-parser.php
A src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-container-adapter.sh
A src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-distributed-adapter.sh
M src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
M src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh
M src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-migration.sh
M src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
A src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-runtime.sh
M src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
M tests/backend-migration.sh
M tests/backend-safety.sh
A tests/distributed-container-adapter.sh
A tests/distributed-operator-cli.sh
A tests/distributed-status.sh
M tests/final-release-gate.sh
A tests/fixtures/distributed-controller-command-v1.json
M tests/jit-recovery.sh
M tests/lib/assert.sh
M tests/package-reproducible.sh
M tests/reconcile-stop-lifecycle.sh
M tests/recycle-runtime.sh
M tests/runner-pools.sh
M tests/scale-set-probe.sh
M tests/scale-set-runtime.sh
M tests/secret-handoff.sh
M tests/ui-js.sh
M tools/crf-scaleset/cmd/crf-scaleset/main.go
M tools/crf-scaleset/cmd/crf-scaleset/main_test.go
M tools/crf-scaleset/go.mod
M tools/crf-scaleset/go.sum
M tools/crf-scaleset/internal/controller/controller.go
M tools/crf-scaleset/internal/controller/controller_test.go
M tools/crf-scaleset/internal/github/api.go
M tools/crf-scaleset/internal/github/api_test.go
M tools/crf-scaleset/internal/ownership/ownership_test.go
M tools/crf-scaleset/internal/probe/live_test.go
M tools/crf-scaleset/internal/probe/probe_test.go
M tools/crf-scaleset/internal/protocol/protocol.go
A tools/crf-scaleset/internal/session/admission.go
A tools/crf-scaleset/internal/session/admission_test.go
M tools/crf-scaleset/internal/session/session.go
M tools/crf-scaleset/internal/session/session_test.go
M tools/crf-scaleset/internal/supervisor/supervisor.go
M tools/crf-scaleset/internal/supervisor/supervisor_test.go
M tools/crf-scaleset/vendor/github.com/actions/scaleset/client.go
M tools/crf-scaleset/vendor/github.com/actions/scaleset/types.go
M tools/crf-scaleset/vendor/modules.txt
```

## Beads Activity

| bead | title | action(s) | final status | why it mattered |
|---|---|---|---|---|
| `crf-8ql` | Complete live Windows distributed node acceptance | claimed, worked, closed | closed | Steamy native Windows completed mTLS registration, SCM restart, and job `32552302375`. |
| `crf-q3t` | Make terminal replay reconciliation hands-off | created, claimed, worked, closed | closed | Removed controller-restart terminal conflicts and manual state edits. |
| `crf-eg1` | Complete isolated five-node acceptance and retire classic runners | created, worked, closed | closed | Tracked the five-node proof, temporary resource cleanup, and classic retirement. |
| `crf-wxo` and `.1`-`.14` | Lavra review remediation | created/closed during review waves | closed | Tracked statistics validation, JIT GC, client concurrency, cleanup ownership, tests, and final clean review. |
| `crf-o8x` | Reconcile Beads Dolt remote history divergence | created during maintenance | open | Preserves the remaining tracker-replication problem as explicit follow-up work. |

## Repository Maintenance

### Plans

- Inspected `docs/plans/2026-07-29-cargo-remote-build-server.md`. It is unrelated to this closeout and its completion state was not established, so it was not moved.

### Beads

- Verified `crf-8ql`, `crf-q3t`, and `crf-eg1` are closed with acceptance-specific reasons.
- The prior `bd dolt push` failed because local and remote histories have no common ancestor. No force push or history replacement was attempted; `crf-o8x` was created for safe reconciliation.

### Worktrees and branches

- Inspected every registered worktree, local branch, remote branch, dirty count, and relevant merge ancestry.
- The PR #69 deployment worktree and branch were already absent when cleanup ran, consistent with a concurrent repository cleanup; no further deletion was needed.
- Preserved the locked `worktree-distributed-elixir-rust` worktree even though it is merged, because it is explicitly session-locked.
- Preserved `codex/integrate-pool-queue` because it remains checked out in the primary worktree, and preserved the 20-file-dirty `feat/pool-queue-optimization-20260821` worktree.
- Preserved GraphQL, Kache watchdog, and fixed-drain worktrees because their branches are not ancestors of `origin/main`; their ownership is outside this session.

### Stale documentation

- PRs #58, #68, and #69 updated the README, architecture, implementation plan, progress ledger, service packaging, and Unraid UI documentation to the shipped state. No additional contradicted document was found in the scoped review.

## Tools and Skills Used

- **Shell and file tools.** `rg`, Git, Cargo, Go, Mix, Bash, PHP, PowerShell, Docker, systemd, and repository scripts were used for implementation and verification. File edits used patch-based changes; unrelated dirt was preserved.
- **GitHub CLI/API.** Used for runner inventory, workflow dispatch/status, PR creation/review/checks, temporary scale-set and registration cleanup, and merge verification.
- **Remote host tools.** SSH and dedicated host access were used against Dookie, Tootie, Squirts, Steamy, and Steamy WSL for identity, service, storage, process, and job proof.
- **Skills/plugins.** `vibin:review-pr`, `elixir-phoenix:phx-review`, `lavra:lavra-review`, the Beads workflow, and `vibin:save-to-md` drove review, remediation, tracking, and this artifact.
- **Review agents.** Parallel reviewers covered errors/docs, tests, types, Elixir/Phoenix, architecture, performance, simplicity, and bug reproduction. Their actionable findings were assigned, fixed, retested, and re-reviewed to clean results.
- **Browser/UI testing.** The Unraid WebUI behavior contract was exercised with `tests/scaleset-ui-behavior.js`; source hashes were also compared between the checkout and Tootie deployment.

## Commands Executed

| command | result |
|---|---|
| `cargo test --workspace` | Rust workspace tests passed. |
| `cargo clippy --workspace --all-targets -- -D warnings` | Rust lint passed. |
| `GOWORK=off go test -race ./...` | Scale-set helper race suite passed. |
| `GOWORK=off go vet ./...` | Go static analysis passed. |
| `go mod verify` | Module checksums and pinned fork resolved correctly. |
| `mise exec -- mix test` | Final controller suite passed: 122 tests. |
| `mix format --check-formatted` from `controller/` | Controller formatting passed. |
| `bash tests/final-release-gate.sh` | Final release gate passed. |
| `bash tests/backend-migration.sh` | Migration boundary and rollback tests passed. |
| `bash tests/distributed-container-adapter.sh` | Distributed adapter tests passed. |
| `bash tests/jit-recovery.sh` | JIT quarantine, fairness, FD, retry, and latency tests passed. |
| `bash tests/scale-set-probe.sh` | Scale-set and pinned fork contract tests passed. |
| `node tests/scaleset-ui-behavior.js` | WebUI behavior contract passed. |
| `gh pr checks 69 --watch --interval 10` | Plugin, shell/PHP, Ubuntu, and Windows checks all passed. |
| `gh pr merge 69 --merge` | PR #69 merged as `db46e8a`. |

## Errors Encountered

- A clean Linux build reached the OTP release step without an effective Elixir version in a detached worktree. Repository `.mise.toml` pins plus `scripts/worktree-setup.sh` now install and verify the expected toolchain.
- Candidate image construction tried to resolve `local/github-runner:ubuntu-resolute` through Docker Hub and failed with `insufficient_scope`. The build now checks host-local base images before immutable candidate construction and reports the missing local prerequisite directly.
- Early Windows packaging, reconnect, native spawn, sidecar lifecycle, CLI, and installer review found swallowed errors and partial-state risks. These were fixed with concrete diagnostics, rollback, bounded retries, verified cleanup, and behavioral tests.
- The first root-level `mise exec -- mix format --check-formatted` had no root formatter inputs; the correct controller-local formatting command passed.
- Several live acceptance attempts exposed expected safety boundaries, including an unconfigured temporary local pool and generation changes after controller restart. Configuration was bounded and restored, and generation-aware readoption was implemented.
- `bd dolt push` failed because tracker histories have no common ancestor. It remains open as `crf-o8x`; no destructive reconciliation was attempted.

## Behavior Changes (Before/After)

| area | before | after |
|---|---|---|
| Fleet control | Classic containers were the primary execution model. | Distributed controller/node execution is production-active; classic boot and registrations are retired. |
| Controller restart | Nodes could remain absent or fail on unknown registration state. | Nodes reconnect and re-register while retaining durable execution state. |
| Placement recovery | Observed state could hide a changed node generation. | Placements are re-adopted against the active generation. |
| Queue admission | Visible-message ordering and unbounded/under-tested lookahead limited scheduling quality. | Bounded deep-backlog ranking uses persisted runtime estimates, exact acquisition, and health telemetry. |
| JIT cleanup | Recursive deletion blocked reconcile and could leak state or starve later entries. | Data is safely quarantined and reclaimed asynchronously with bounded, fair retries. |
| Unraid stop/migration | Broad inventory could include distributed/JIT containers. | Exact classic identity ownership excludes distributed and JIT work. |
| WebUI | Classic controls did not accurately represent the external control plane. | Fleet/Image/Pools pages project distributed nodes, placements, readiness, and compatible actions. |
| Worktree builds | Detached worktrees could lack selected BEAM/Go toolchains. | Repository pins and bootstrap verification make worktrees self-preparing. |

## Verification Evidence

| command/evidence | expected | actual | status |
|---|---|---|---|
| PR #69 final checks | All required checks green on final head | Four checks succeeded on `4a78a75` | pass |
| Five-node workflow runs | One native/container proof per requested host | Dookie `32550077732`; Squirts `32550417290`; Steamy WSL `32550464379`; Steamy `32552302375`; Tootie `32555900347` / job `96989833369` | pass |
| Cancellation run | Cooperative cancellation terminalizes cleanly | Dookie run `32552815427` passed | pass |
| Tootie classic inventory | Zero classic containers and registrations | `classic_containers=0`; GitHub prefix count `0` | pass |
| Tootie boot/storage | Classic disabled; distributed node off flash | `START_ON_BOOT="no"`; executable/state under `/mnt/cache/appdata/...` | pass |
| Dookie controller | Service active on clean release | Active at release ending `86aee55ce02e...` with `GIT_DIRTY=false` | pass |
| Compatibility proof | Fresh compatibility record valid | Operation `cb81f476-e292-4fb8-bdd3-a2ce906b4c44`; record `b4f934...`; valid `true` | pass |
| Temporary acceptance cleanup | Temporary scale sets and placement removed | Scale sets 245, 246, 249 removed; acceptance placement terminalized and container removed | pass |
| PR merge | Final reviewed head reachable from `main` | Merge commit `db46e8a5c794c0011a8fbf32a0542ef8e82fc826` | pass |

## Risks and Rollback

- The production controller currently runs the clean `86aee55` release used for live acceptance, while `main` includes the final documentation commit and merge commit. Roll back by repointing `/opt/ci-runner-farm/current` to the prior immutable release and restarting the controller.
- Tootie's distributed node is cache-resident. Its pre-upgrade binary and configuration backups remain the rollback path; classic execution should not be re-enabled without running the migration FSM and compatibility gates.
- The forked scale-set client is commit-pinned and vendored. Reverting requires changing the pseudo-version, regenerating vendor content, and rerunning module and contract gates together.
- Tracker replication is not fully synchronized. Preserve both Dolt histories until `crf-o8x` establishes a non-destructive reconciliation plan.

## Decisions Not Taken

- Did not force-push or bootstrap over the divergent Beads Dolt remote; that could discard tracker history.
- Did not remove dirty, locked, active, or unmerged worktrees during session cleanup.
- Did not retain classic containers as a parallel default after cutover; the documented rollback path remains available through the migration FSM.
- Did not silently pull the host-local runner image from a registry; local-image availability is an explicit candidate-build prerequisite.

## References

- [PR #37: Distributed Elixir/Rust runner farm control plane](https://github.com/dinglebear-ai/ci-runner-farm/pull/37)
- [PR #68: Optimize distributed queue admission and JIT cleanup](https://github.com/dinglebear-ai/ci-runner-farm/pull/68)
- [PR #69: Finish distributed runner farm closeout](https://github.com/dinglebear-ai/ci-runner-farm/pull/69)
- `docs/distributed-runner-farm/README.md`
- `docs/distributed-runner-farm/architecture.md`
- `docs/distributed-runner-farm/progress.md`
- `docs/distributed-runner-farm/service-packaging.md`

## Open Questions

- How should the local and remote Beads Dolt histories be reconciled without losing either lineage? Tracked by `crf-o8x`.
- Several unrelated worktrees remain active or unmerged; their owners must decide disposition independently of this completed distributed-farm work.

## Next Steps

- **Unfinished from this session:** reconcile and push Beads tracker history under `crf-o8x`; no product code remains unfinished.
- **Immediate operational follow-up:** monitor the five distributed nodes and controller after normal workload turnover, including restart/reconnect telemetry and JIT quarantine drain.
- **Release follow-up:** publish the next normal plugin/release artifact from merged `main` so Tootie's manually deployed reviewed source becomes durable through the standard update channel.
- **Repository follow-up:** handle unrelated clean/dirty worktrees only in their owning tasks; do not fold them into this closeout retroactively.
