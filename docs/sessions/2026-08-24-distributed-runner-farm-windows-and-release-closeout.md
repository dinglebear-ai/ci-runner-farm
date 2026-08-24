---
date: 2026-08-24 16:34:29 EDT
repo: git@github.com:dinglebear-ai/ci-runner-farm.git
branch: main
head: fb9ab06cc4a32bbbefbbfe1196cb6b9bbdb61d80
plan: docs/superpowers/plans/2026-08-22-ssh-device-runner-deployment.md
session id: 01a02931-6bc5-7b02-99cd-278da91804fb
transcript: /home/jmagar/.codex/sessions/2026/08/22/rollout-2026-08-22T07-18-19-01a02931-6bc5-7b02-99cd-278da91804fb.jsonl
working directory: /home/jmagar/workspace/ci-runner-farm
worktree: /home/jmagar/workspace/ci-runner-farm
beads: crf-znd, crf-8fr, crf-8fr.1-crf-8fr.16, crf-zg3, crf-ecg, crf-1mu, crf-moi, crf-18e, crf-kbb, crf-6om.1, crf-fcs, crf-133, crf-wtk, crf-ik6, crf-ju3, crf-z81
---

# Distributed runner farm, Windows containers, review, and release closeout

## User Request

Clean stale repository work, plan SSH deployment from the Unraid WebUI, make the distributed runner fleet fully operational across Linux and Windows devices, review and fix the whole repository, land all valuable work on `main`, deploy and test it, and safely clean up anything obsolete.

## Session Overview

The session consolidated active work, designed and engineering-reviewed the SSH deployment feature, completed a whole-repository remediation loop, deployed and debugged the distributed fleet, added hardened portable Linux and Windows Hyper-V container execution, fixed fenced JIT retirement and capacity behavior, merged PRs #80 through #87 as applicable, published v1.12.0, and left the repository clean on `main`. The final maintenance pass found no stale worktrees or branches, preserved the unimplemented SSH WebUI plan, and closed two exact duplicate release beads.

## Sequence of Events

1. **Repository reconciliation.** Inspected branches and worktrees, compared pool-queue work against merged PR #69, preserved unique work, and later removed only worktrees and branches proven merged or superseded.
2. **SSH deployment design.** Wrote the SSH-device deployment specification and implementation plan, then incorporated architecture, security, performance, and simplicity review findings such as dedicated status polling, immutable artifact snapshots, rollback after post-install failures, bounded workers, and authenticated generation proof.
3. **Whole-repository remediation.** Ran repeated Lavra review waves and fixed TLS admission, placement durability, process-tree timeouts, migration fences, bounded adapter I/O, mailbox/scheduler scaling, mutable images, privileged admission, and related test gaps.
4. **Fleet deployment and debugging.** Deployed the distributed controller/node stack, verified Linux nodes, removed Dookie from job execution because it is a VM on Tootie, adjusted device capacity behavior, and diagnosed Docker-dependent PostgreSQL jobs.
5. **Windows execution.** Replaced unsafe native execution with ephemeral Windows Hyper-V containers using containerd/nerdctl, immutable images, resource limits, crash recovery, private readiness projection, service recovery, and bounded lifecycle handling.
6. **PR review and integration.** Reviewed PR #81 repeatedly, fixed JIT wire/fencing, compensation, Windows lifecycle, status, installer, docs, type, and error-handling findings, merged it, then landed follow-up PRs #83-#87.
7. **Release and publication.** Merged release PR #80, verified v1.12.0 plugin assets, added the distributed release publication workflow in PR #85, and repaired its source, checksum, runner-routing, registry, and image-contract gates.
8. **Final maintenance.** Confirmed one clean `main` worktree, no origin topic branches, no open PRs, preserved active plans, closed duplicate beads `crf-ju3` and `crf-z81`, and recorded remaining operational follow-ups.

## Key Findings

- Existing operation polling could not see SSH deployment records because the proposed files and the scale-set operation store differed; the plan now uses a dedicated namespaced SSH status contract.
- The Windows adapter required explicit crash recovery between container creation and durable state publication; deterministic-name adoption now validates exact placement and command labels before recovery ([WindowsContainerAdapter.ps1](/home/jmagar/workspace/ci-runner-farm/packaging/distributed/windows/WindowsContainerAdapter.ps1:127)).
- Retired JIT proofs must make the associated placement terminal before offer release and proof confirmation, or a transient ledger failure can create duplicate capacity ([demand_work.ex](/home/jmagar/workspace/ci-runner-farm/controller/lib/crf_controller/demand_work.ex:122)).
- A normal GitHub runner process is not inherently containerized, but this farm deliberately requires isolated adapters; Linux uses the portable container adapter and Windows uses fresh Hyper-V-isolated Windows containers.
- The distributed release workflow is least-privilege at the workflow level, binds source to an immutable stable tag, publishes a multi-architecture image by digest, and verifies runtime contracts before attaching receipts ([publish-distributed-release.yml](/home/jmagar/workspace/ci-runner-farm/.github/workflows/publish-distributed-release.yml:1)).

## Technical Decisions

- Reject `native_process` in deployed node configuration and require an explicit container backend so untrusted workflow code cannot execute directly on a host.
- Treat CPU and memory claims as both scheduler admission inputs and runtime limits; allow jobs to use smaller elastic allocations instead of requiring oversized fixed CPU requests.
- Use current authenticated ownership for requests while preserving the historical durable proof revision for JIT retirement and confirmation.
- Keep Dookie out of the worker fleet because it is a VM hosted by Tootie; avoid double-counting the same physical capacity.
- Preserve the SSH WebUI feature as an active, security-first plan rather than prematurely marking it complete.

## Files Changed

The complete landed change range after PR #69 is `db46e8a5c794c0011a8fbf32a0542ef8e82fc826..fb9ab06cc4a32bbbefbbfe1196cb6b9bbdb61d80`: 193 paths (65 created, 128 modified, no deletions or renames).

| status | path | purpose and evidence |
|---|---|---|
| modified | `.github/actionlint.yaml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `.github/workflows/distributed-farm-acceptance.yaml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `.github/workflows/lint.yml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `.github/workflows/publish-distributed-release.yml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `.mise.toml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `.release-please-manifest.json` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `CHANGELOG.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `Cargo.lock` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `Cargo.toml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `README.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `VERSION` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `build-plg.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `ci-runner-farm.plg` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `community-applications/DESCRIPTION.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `community-applications/README.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `community-applications/ca_profile.xml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `community-applications/ci-runner-farm.xml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/application.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/controller_config.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/demand_coordinator.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/demand_work.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/ingress.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/node_mailbox.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/node_registry.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/operator_projection.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/operator_snapshot.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/placement_ledger.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/placement_state_store.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/placement_tombstone.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/pool_policy.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/scaleset_client.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `controller/lib/crf_controller/scaleset_eligibility.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/scaleset_sidecar.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/scaleset_wire.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/scheduler_client.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/scheduler_wire.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/tls_connection.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/lib/crf_controller/tls_server.ex` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/controller_config_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/demand_coordinator_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/node_mailbox_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/node_registry_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `controller/test/operator_projection_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/operator_snapshot_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/placement_state_store_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/scaleset_client_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `controller/test/scaleset_eligibility_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/scaleset_sidecar_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/scaleset_wire_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/scheduler_client_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/scheduler_wire_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `controller/test/tls_revocation_integration_test.exs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `crates/crf-container-adapter/Cargo.toml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `crates/crf-container-adapter/src/main.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/Cargo.toml` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/agent.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/config.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/container_adapter.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/container_executor.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/daemon.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/generation.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/lib.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/native_executor.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/native_materializer.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/node_executor.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `crates/crf-node/src/node_status.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/placement_state.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/process_tree.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/runner_package.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/src/transport.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-node/tests/container_executor.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-protocol/src/lib.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-scheduler/src/lib.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `crates/crf-scheduler/src/service.rs` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `deployments/distributed/runner-image-contract.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `deployments/distributed/runner.Dockerfile` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/architecture.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/controller-config.example.json` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/controller-config.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/implementation-plan.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/progress.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/runner-packages.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `docs/distributed-runner-farm/scaleset-native-plugin-contract.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/service-packaging.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/distributed-runner-farm/spec.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `docs/distributed-runner-farm/ssh-device-deployment-spec.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `docs/graphql-api-plugin/reference/types.ts` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `docs/native-plugin-payloads.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `docs/sessions/2026-08-22-distributed-runner-farm-closeout.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `docs/superpowers/plans/2026-08-22-ssh-device-runner-deployment.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `packaging/distributed/README.md` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `packaging/distributed/examples/node-env.example` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `packaging/distributed/install.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `packaging/distributed/systemd/ci-runner-farm-node.service` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `packaging/distributed/windows/Install-CrfNodeService.ps1` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `packaging/distributed/windows/Prepare-WindowsRunnerContext.ps1` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `packaging/distributed/windows/WindowsContainerAdapter.ps1` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `packaging/distributed/windows/WindowsRunner.Dockerfile` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `packaging/distributed/windows/WindowsRunnerEntrypoint.ps1` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `packaging/distributed/windows/crf-container-adapter.cmd` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `packaging/distributed/windows/node-env.example` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `scripts/build-distributed-bundle.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `scripts/build-distributed-windows-node.ps1` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `scripts/build-native-plugin-payload.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `scripts/distributed-beam-memory-check.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `scripts/resolve-distributed-image.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `scripts/verify-distributed-bundle.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `scripts/verify-distributed-release-source.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `scripts/worktree-setup.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/api-auxiliary.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/api-log.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/api-request.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/api-response.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/api-status.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/operation-record.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-migration.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-operation-workers.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-operations.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-status.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/api-auxiliary.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/api-log.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/api-request.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/api-status.php` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/backend-migration.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/backend-safety.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/compatibility-operations.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/distributed-beam-acceptance.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/distributed-container-adapter.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/distributed-publication-workflow.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/distributed-runner-image-contract.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/final-release-gate.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/fixed-drain-quiesce.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/graphql-auxiliary-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/graphql-controller-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/graphql-log-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/graphql-mutation-dispatch.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/graphql-status-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/image-build-operations.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/jit-recovery.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/kache-supervisor-health.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/kache-supervisor-watchdog.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/lifecycle-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/native-plugin-payload.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/operation-api.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/operation-worker-timeouts.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/operations.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/pool-status.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/portable-container-adapter.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/provisioning-operations.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/real-docker-container-adapter.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/reconcile-stop-lifecycle.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/revision-guards.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/runner-pools.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/secret-handoff.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/security-review-contracts.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tests/stalled-credential-handoff.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/windows-container-adapter.ps1` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/windows-service-recovery.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tests/worktree-toolchain.sh` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/cmd/crf-scaleset/main.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/cmd/crf-scaleset/main_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tools/crf-scaleset/cmd/crf-scaleset/testdata/runtime-config-v1.json` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/controller/controller.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/controller/controller_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tools/crf-scaleset/internal/durable/replace.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/github/api.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/ipc/client_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/ipc/server.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/journal/journal.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/journal/journal_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/ownership/ownership.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/ownership/ownership_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/probe/live.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/probe/live_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/probe/probe.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/protocol/protocol.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/protocol/protocol_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/session/admission.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tools/crf-scaleset/internal/session/admission_simulation_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/session/admission_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tools/crf-scaleset/internal/session/fast_lane.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| created | `tools/crf-scaleset/internal/session/fast_lane_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/session/session.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/session/session_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/supervisor/supervisor.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |
| modified | `tools/crf-scaleset/internal/supervisor/supervisor_test.go` | Change present in `db46e8a..fb9ab06`; purpose follows its subsystem and landed PR. |

## Beads Activity

| bead | title | action | final status | why it mattered |
|---|---|---|---|---|
| `crf-znd` | Deploy distributed runner nodes from Unraid SSH config | Claimed; specification and review comments added | in progress | Governs the planned WebUI SSH deployment feature; implementation remains outstanding. |
| `crf-8fr`, `crf-8fr.1`–`crf-8fr.16`, `crf-zg3`, `crf-ecg`, `crf-1mu`, `crf-moi`, `crf-18e`, `crf-kbb` | Exhaustive full-repository review and findings | Findings created/implemented/closed | closed | Tracks the repo-wide architecture, security, performance, durability, and simplicity remediation. |
| `crf-6om.1` | Ship a portable hardened Docker execution adapter for Linux nodes | Implemented and closed | closed | Supplied the supported isolated Linux execution backend. |
| `crf-fcs` | Avoid durable placement checkpoint for no-op generation prune | Implemented, deployed, and closed | closed | Removed a production controller ingress stall. |
| `crf-133` | Harden CRF OTP compatibility and Elixir coverage capacity | Implemented and closed | closed | Made image/userspace and memory capacity contracts truthful. |
| `crf-wtk` | Make placement WAL contract deterministic on Windows | Implemented and closed | closed | Removed a hosted-runner timing false failure while preserving durability coverage. |
| `crf-ik6` | Add PHP CLI to distributed runner image | Implemented and closed | closed | Repaired the exact distributed image contract exposed by main CI. |
| `crf-ju3` | Verify published release artifact bytes and integrity | Closed as exact duplicate of completed `crf-27c` | closed | Removed stale duplicate tracker state during this maintenance pass. |
| `crf-z81` | Least-privilege release publication audit | Closed as exact duplicate of completed `crf-167` | closed | Removed stale duplicate tracker state during this maintenance pass. |

## Repository Maintenance

- **Plans:** inspected `docs/plans/`, `docs/superpowers/plans/`, and `.claude/current-plan`. The Cargo remote-build plan remains proposed, and the SSH device deployment plan remains active through `crf-znd`; neither was moved to `docs/plans/complete/`.
- **Beads:** read the recent issue list and interaction log. Closed only `crf-ju3` and `crf-z81` after proving that their titles and descriptions exactly matched already completed `crf-27c` and `crf-167`. Left `crf-znd` in progress.
- **Worktrees and branches:** `git worktree list --porcelain` shows only `/home/jmagar/workspace/ci-runner-farm` on `main`; local branches contain only `main`; `origin` contains only `origin/main` and `origin/HEAD`. No further deletion was needed or safe.
- **Stale docs:** reviewed the distributed architecture, runner package, service packaging, Windows node example, SSH specification, and release-publication contract touched by the session. They reflect the landed container, resource, status, and publication behavior; no additional stale-doc edit was identified.
- **Transparency:** upstream topic branches were not touched because they belong to the upstream remote, not this repository's origin. Exact-main Release Please was queued at the final refresh and is recorded below rather than presented as complete.

## Tools and Skills Used

- **Shell, Git, and GitHub CLI:** repository ancestry, worktree/branch cleanup, commits, pushes, PR creation/merge, release assets, Actions runs, logs, and exact-head status. One accidental no-commit cherry-pick conflict was restored path-by-path without disturbing unrelated work.
- **File tools and patching:** read source/spec/test files and applied focused changes while preserving dirty user work; generated this session artifact through the required path-limited workflow.
- **Skills/plugins:** `vibin:repo-status`, `superpowers:writing-plans`, `lavra:lavra-eng-review`, `lavra:lavra-work`, `lavra:lavra-review`, `superpowers:systematic-debugging`, `vibin:review-pr`, verification-before-completion practices, and `vibin:save-to-md`.
- **Review agents:** architecture, security, performance, simplicity, tests, types, comments/docs, silent-failure, and error-handling reviewers were used in multiple waves; findings were re-reviewed until the exact tree was clean.
- **Device/runtime tools:** SSH and Windows PowerShell were used against Tootie, Linux nodes, and Windows hosts; Docker/containerd/nerdctl, systemd/SCM, GitHub runner diagnostics, and live logs supported deployment and end-to-end checks. Windows-only tests were sometimes unavailable from Linux and were run or inspected on the native Agent OS path.

## Commands Executed

| command | result |
|---|---|
| `git worktree list --porcelain; git branch -vv; git branch -r -vv` | Final state: one clean `main` worktree, one local branch, no origin topic branches. |
| `gh pr view/list/checks/merge …` | Reviewed and merged PRs #80, #81, and #83-#87; no open PRs remained. |
| `cargo test -p crf-node`; `cargo clippy -p crf-node --all-targets -- -D warnings`; `cargo fmt --all -- --check` | Rust node/adapter tests and static gates passed in the reported exact trees. |
| `cd controller && mix test` | Controller suites passed after placement, TLS, mailbox, snapshot, JIT, and scheduling fixes. |
| `cd tools/crf-scaleset && go test ./...` | Go sidecar/controller/session tests passed after fencing and retirement changes. |
| `actionlint`; `tests/final-release-gate.sh`; focused shell/PowerShell contracts | Publication, packaging, API, operation, Windows, and runner-routing contracts passed after remediation. |
| `gh release view v1.12.0 --json …` | Stable release exists with plugin TGZ and PLG assets and recorded SHA-256 digests. |
| `bd show/close …` | Proved and closed two stale duplicate release beads; active SSH bead preserved. |

## Errors Encountered

- An accidental `git cherry-pick -n 09e9385` ran in the root checkout and conflicted. Because `-n` created no cherry-pick state, `git cherry-pick --abort` could not help; affected paths were restored explicitly and the unrelated `node-env` edit was preserved until its replacement landed.
- Initial publication CI failed runner-pool routing assertions. The special four-platform publication workflow was excluded from fleet-count assumptions and gained explicit hosted-runner assertions.
- The publication checksum initially embedded a build path, and the image resolver overwrote `BASH_REMATCH` before using the captured repository. Both bugs received focused contract fixes.
- Windows PowerShell/UAC prompts and unavailable native PowerShell on Linux complicated live verification. The Windows service was made persistent with recovery behavior, and Windows-specific acceptance was routed through the native Windows host.
- PostgreSQL service jobs failed when scheduled to runners without Docker access. The fleet moved toward explicit isolated container backends and capability-aware placement rather than treating all hosts as interchangeable.

## Behavior Changes (Before/After)

| area | before | after |
|---|---|---|
| Linux node execution | Native execution could be configured or no portable backend was shipped. | Deployed nodes require a hardened container backend; the portable adapter is packaged and tested. |
| Windows jobs | Windows capacity lacked a supported isolated ephemeral runner path. | Jobs run in fresh Hyper-V-isolated Windows containers through containerd/nerdctl with immutable image and resource limits. |
| Scheduling | Large fixed CPU requests excluded usable hosts and capacity could be double-counted. | Elastic resource-aware admission uses device reserves/claims; Dookie is excluded as a Tootie VM. |
| JIT cleanup | Ownership revisions and crash windows could strand issued or retired records. | Issue, retire, and confirm operations are fenced, durable, idempotent, and compensation-aware. |
| Release delivery | Distributed bundles/images lacked a dedicated immutable publication path. | A stable-tag-bound multi-platform publication workflow validates source, image contract, checksums, and receipts. |
| Repository state | Multiple active/stale lanes and dirty worktrees required investigation. | All valuable work is on `main`; one clean worktree and no origin feature branches remain. |

## Verification Evidence

| command | expected | actual | status |
|---|---|---|---|
| `git status --short` before this note | No pre-existing dirt | Empty output | pass |
| `git worktree list --porcelain` | Only primary worktree | One `main` worktree at `fb9ab06` | pass |
| `gh pr list --state open` | No unlanded origin PR | `[]` | pass |
| Exact-main Lint run 32769083816 | Green | completed/success | pass |
| Exact-main Build Plugin run 32769083839 | Green | completed/success | pass |
| Exact-main Release Please run 32769084021 | Terminal | queued at refresh | warn |
| `gh release view v1.12.0` | Published stable assets | Stable release with TGZ and PLG assets and digests | pass |
| PR #81 focused controller/Go/Rust/Windows contracts | Findings closed | Review agents reported exact-tree clean; focused suites passed | pass |
| `bd show crf-ju3 crf-z81` after close | Duplicate beads closed | Both closed with explicit duplicate reasons | pass |

## Risks and Rollback

- Revert the relevant merge commit to roll back a code path; disable `.github/workflows/publish-distributed-release.yml` before reverting publication behavior if it is unsafe.
- Do not retag an immutable published release or overwrite a version image tag. Publish a corrective version and keep the commit-digest identity.
- Windows container execution depends on compatible Windows host/image builds plus functioning containerd/nerdctl; service recovery should not be confused with proof that every future image starts.
- Fleet capacity changes should be rolled back by restoring the previous node configuration and restarting the node service, then verifying authenticated generation and placement cleanup.

## Decisions Not Taken

- Did not keep native-process execution as a compatibility mode because untrusted GitHub workflow code would run directly on the device.
- Did not keep Dookie as a worker because it shares Tootie's physical resources and would make capacity accounting misleading.
- Did not mark the SSH WebUI plan complete; only its specification and reviewed plan landed.
- Did not delete upstream remote branches or ambiguous active plans.
- Did not manually dispatch the new distributed publication workflow for v1.12.0 during this save operation.

## References

- [PR #69: distributed runner farm closeout](https://github.com/dinglebear-ai/ci-runner-farm/pull/69)
- [PR #80: v1.12.0 release](https://github.com/dinglebear-ai/ci-runner-farm/pull/80)
- [PR #81: Windows Hyper-V containers](https://github.com/dinglebear-ai/ci-runner-farm/pull/81)
- [PR #83: BEAM runner image and memory contract](https://github.com/dinglebear-ai/ci-runner-farm/pull/83)
- [PR #84: adapter failure containment and JIT retirement](https://github.com/dinglebear-ai/ci-runner-farm/pull/84)
- [PR #85: distributed release publication](https://github.com/dinglebear-ai/ci-runner-farm/pull/85)
- [PR #86: deterministic placement WAL contract](https://github.com/dinglebear-ai/ci-runner-farm/pull/86)
- [PR #87: PHP CLI runner contract](https://github.com/dinglebear-ai/ci-runner-farm/pull/87)
- [Release v1.12.0](https://github.com/dinglebear-ai/ci-runner-farm/releases/tag/v1.12.0)

## Open Questions

- When should `crf-znd` be resumed to implement the reviewed SSH deployment plan in the Unraid WebUI?
- Should the new `Publish Distributed Release` workflow be manually dispatched against existing v1.12.0, or first exercised by the next stable release?
- The final exact-main Release Please run was queued during the status refresh; its terminal result was not yet observed.
- The latest `main` follow-ups (#86 and #87) were not redeployed to the live fleet during this save operation.

## Next Steps

- **Unfinished from this session:** implement `crf-znd` from `docs/superpowers/plans/2026-08-22-ssh-device-runner-deployment.md`, including dedicated status polling, rollback, bounded SSH operations, and WebUI tests.
- **Immediate operational follow-up:** decide whether to dispatch `gh workflow run "Publish Distributed Release" -f release_tag=v1.12.0`, then verify GHCR digest/platforms and attached release receipts.
- **Deployment follow-up:** package and deploy the current exact `main` head if #86/#87 behavior is required live, then run Linux and Windows end-to-end jobs plus Docker/PostgreSQL service jobs.
- **CI follow-up:** wait for exact-main Release Please run 32769084021 to reach a terminal state and record any generated release PR.

