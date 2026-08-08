# Research record: CI Runner Farm as an Unraid GraphQL API plugin

## Purpose

This record identifies the source code reviewed, the behavior confirmed, the gaps found, and the design conclusions used by the schema, contracts, specification, and implementation plan in this directory.

No proposed behavior in this package depends on an assumed undocumented remote service. Every controller requirement is derived from the checked-out Runner Farm code. Every Unraid API integration requirement is derived from the checked-out Unraid API code at the revision below. The local-tarball installer behavior was verified with npm on DEVHOST.

## Repository state

### CI Runner Farm

- Repository: `/home/jmagar/workspace/ci-runner-farm`
- Design worktree: `/home/jmagar/workspace/ci-runner-farm/.claude/worktrees/graphql-api-plugin-design`
- Branch: `worktree-graphql-api-plugin-design`
- Audited commit: `086274a45ec4f598e8013f9d109cd2983cfce4e4`

### Unraid API

- Repository: `/home/jmagar/workspace/upstream/unraid-api`
- Reviewed detached worktree: `/tmp/unraid-api-doc-audit`
- Revision: `98034ff8405d8f1322daca9bd4d7d7dccc262810`
- Commit date: 2026-08-03
- API package version: `4.36.1`

## Runner Farm code reviewed

### Packaging and installation

- `ci-runner-farm.plg`
- `build-plg.sh`
- `deploy.sh`
- `src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg`

Findings:

- Runner Farm is a native Unraid `.plg` package installed beneath `/usr/local/emhttp/plugins/ci-runner-farm`.
- Durable user configuration is under `/boot/config/plugins/ci-runner-farm`.
- The plugin currently preserves configuration and credentials on uninstall.
- Installation starts boot-autostart asynchronously and does not depend on Unraid API.
- An API package can be added without replacing the existing Unraid plugin.

### WebGUI adapter

- `include/exec.php`
- `include/crf-core.php`
- all `RunnerFarm*.page` files
- `tests/php-actions.sh`
- `tests/settings-endpoint.php`
- `tests/backend-safety.sh`

Findings:

- `exec.php` is POST-only and relies on Unraid's global PHP prepend for CSRF validation.
- It validates every action and input length, then invokes the shell controller.
- JSON-returning commands keep stderr out of stdout to prevent corrupt response bodies.
- Secret writes and Dockerfile writes have more behavior than the shell controller currently exposes. Secret files are outside `config_revision`, so the GraphQL contract needs a separate opaque credential revision to prevent concurrent last-writer races.
- GraphQL must not invoke this endpoint because API-key authentication is not the same as WebGUI CSRF authentication.
- Configuration and secret code should be extracted into reusable PHP helpers or CLIs so WebGUI and GraphQL use identical durable behavior.

### Main controller and status

- `include/runner-farm.sh`
- `include/runner-status.sh`
- `tests/performance-contracts.sh`
- `tests/pool-status.sh`
- `tests/runner-runtime.sh`
- `tests/recycle-runtime.sh`

Findings:

- `runner-farm.sh` is the authoritative controller and dispatches all lifecycle, status, migration, build, cache, autoscaling, scheduler, and scale-set operations.
- Fleet mutations use locks.
- `status-json` returns schema version 2 and includes config and inventory revisions, backend and compatibility state, operation state, maintenance, resources, reservations, recent activity, pools, and runners.
- `readiness-json` now includes a nullable cached fleet count. It reads only a bounded regular mode-0600 inventory cache and never refreshes Docker; missing, symlinked, oversized, or unsafe-mode inventory yields null.
- Status preserves separate requested/effective backend and separate configured/effective/desired/admitted/advertised capacity. The latest hardening also validates mode-0600 regular scale-set snapshots, ownership, plans, compatibility records, and operation records before projection.
- Runner details include active repository, pull request, branch, run ID, CPU, memory, stale state, and retirement state.
- The legacy schema-v2 runner row reports whole CPU cores and whole GiB limits, so fractional CPU and exact byte limits are lossy; the strict API must add exact nullable `cpu_milli` and `memory_bytes` fields.
- Unknown live usage is currently represented with negative sentinels; GraphQL normalizes those values to null.
- Queue run/job IDs are JSON numbers today; the strict API serializes them as strings before they cross a JavaScript boundary.
- Image metadata currently exposes a shortened ID and integer MiB size; the strict API adds a full image ID and exact byte count.
- Invalid migration, mode, or auth configuration can produce `invalid` state, so read models use explicit state enums with an `INVALID` value.
- The aggregate Nchan dashboard payload intentionally omits private build information because that channel is not protected by the WebGUI login.
- The authenticated GraphQL field may expose the full status under `DOCKER` read permission, but it must never republish it to Nchan.

### Configuration

- `default.cfg`
- `runner-farm.sh` configuration parser, validator, `config_json`, and `cmd_apply_config`
- `runner-pools.sh`
- `tests/config-parity.sh`
- `tests/config-fingerprint.sh`
- `tests/flash-write-paths.sh`
- `tests/runner-pools.sh`

Findings:

- Configuration is loaded through an allowlisted parser, not sourced or evaluated.
- The configuration revision is SHA-256 over ordered values separated by NUL bytes.
- Apply refreshes configuration after acquiring the fleet lock, compares the exact expected revision, validates the staged file, preserves a mode-0600 backup, atomically commits, and reconciles runtime state.
- The controller has 48 canonical allowlisted keys.
- Pool mode has a maximum of eight pools and a 16 KiB serialized record limit.
- V2 pool records carry exact resource claims, require fixed capacity 1-64, and support `max=auto`.
- Empty `RUNNER_CPUS`/`RUNNER_MEMORY`, `WORK_TMPFS_SIZE`, `POOL_AUTOSCALE=inherit`, and resource-budget `auto` are meaningful sentinels that a typed API must round-trip without collapsing.
- `RESOURCE_MEMORY_SWAP` accepts only `none` or `double`. Registry-token input is currently bounded at 4096 bytes.
- Scale-set mode requires organization scope and V2 pool records.
- A configuration read must remain useful when the current file is invalid, so GraphQL returns revision, validity/issues, nullable typed configuration, canonical effective allowlisted strings, and credential-presence booleans.
- GraphQL configuration must continue to commit through the existing transaction.

### Resources and scheduling

- `runner-resources.sh`
- `runner-scheduler.sh`
- `tests/resource-admission.sh`
- `tests/resource-runtime.sh`
- `tests/scheduler.sh`

Findings:

- Resource snapshots separate budget, reserve, reserved, and admissible amounts. The latest status code resets these quantities to zero when refresh fails, so the strict API must add explicit availability/reason metadata rather than treating fail-closed zeros as confirmed capacity.
- Reservations are durable mode-0600 files and include schema version, operation ID, boot ID, PID, deadline, config revision, pool, runner, CPU, memory, spec hash, and phase. Status projection now rejects symlinks/unsafe modes and preserves only phases `reserved`, `offered`, `assigned`, `acting`, `observed`, `failed`, or `expired`, with CPU 1-256000 millicores, memory 1-1099511627776 bytes, and a positive deadline.
- Reservation phases are meaningful and must not be collapsed into a boolean.
- Scheduler decisions are deterministic and already bounded by pool and global resource rules.
- The GraphQL plugin should expose state and invoke existing scheduling actions, not calculate admissions itself.

### Scale sets, JIT, and migration

- `runner-scalesets.sh`
- `runner-jit.sh`
- `runner-migration.sh`
- `tests/scale-set-control.sh`
- `tests/scale-set-runtime.sh`
- `tests/scale-set-autoscale.sh`
- `tests/scale-set-supervisor.sh`
- `tests/jit-recovery.sh`
- `tests/secret-handoff.sh`
- `tests/backend-migration.sh`

Findings:

- Scale-set controller requests and snapshots are versioned and bounded.
- Ownership, compatibility evidence, runtime session health, capacity leases, and migration state are separate authorities.
- Backend migration and rollback require four exact revisions: configuration, ownership, compatibility record, and transition.
- Migration uses durable transition phases and recovery logic.
- JIT state uses a defined phase machine and protected secret handoff.
- The GraphQL schema must retain every authority and precondition rather than exposing a generic backend toggle.
- Secret descriptors, tokens, and registration material may never appear in GraphQL output or adapter logs.

### Long-running operations

- compatibility operation functions in `runner-scalesets.sh`
- image build functions in `runner-farm.sh`
- provisioning validation in `runner-farm.sh`
- operation-related tests in scale-set and UI suites

Findings:

- Compatibility records currently live beneath the scale-set runtime directory on tmpfs; image-build state is also runtime-local. Those records are not a reboot-durable generic operation journal.
- Provisioning validation is synchronous at the shell boundary and may be lengthy.
- GraphQL operations therefore require a new low-frequency mode-0600 metadata journal under `$CFGDIR/operations`, bounded output references, atomic state transitions, high-volume logs off flash, and boot reconciliation that marks abandoned running operations interrupted.
- Compatibility, build, and provisioning validation start calls become asynchronous and return exact operation IDs.

### Release and regression gates

- `tests/final-release-gate.sh`
- `tests/package-reproducible.sh`
- all other test files enumerated in the worktree

Findings:

- The repository already enforces strict bounds, deterministic packaging, executable modes, safe paths, lock ordering, migration invariants, and optional live gates.
- New API work must extend the gate without weakening existing checks.
- The API package itself needs deterministic npm packing and schema-diff tests.

## Unraid API code reviewed

### Plugin loading

- `api/src/unraid-api/plugin/plugin.interface.ts`
- `plugin.service.ts`
- `plugin.module.ts`
- `global-deps.module.ts`
- `plugin.resolver.ts`
- `plugin-management.service.ts`

Findings:

- External packages export `adapter = 'nestjs'` and an `ApiModule` class.
- Enabled packages are imported dynamically and their Nest modules are included in GraphQL schema generation.
- Invalid packages are logged and generate an Unraid notification; other plugins continue loading.
- Unraid safe mode skips API plugin discovery entirely.
- Global dependencies include PubSub, lifecycle, API-key, internal GraphQL clients, cookies, Nginx, and shared scalar support.

### GraphQL and authentication

- `app/app.module.ts`
- `graph/graph.module.ts`
- `auth/authentication.guard.ts`
- `@unraid/shared/use-permissions.directive.ts`
- `@unraid/shared/graphql-enums.ts`

Findings:

- Authentication and authorization are global application guards.
- Code-first GraphQL schema generation includes plugin modules.
- WebSocket subscriptions use `graphql-ws` on `/graphql`.
- `fieldResolverEnhancers: ['guards']` applies guards to fields.
- `UsePermissions` validates against a fixed Resource enum. Plugins cannot define a new resource today.
- V1 therefore uses `DOCKER`, `CONFIG`, and `LOGS`.

### Model conventions

- Docker, Unraid plugin, and log models under `api/src/unraid-api/graph/resolvers`
- `@unraid/shared` package exports

Findings:

- Inputs use class-validator and class-transformer.
- Time fields use `GraphQLISODateTime`.
- Large numeric quantities use `GraphQLBigInt` from `graphql-scalars`.
- Enum registration is code-first.
- Runner Farm reference models follow these conventions.

### Persistence and lifecycle

- `api-config.module.ts`
- `@unraid/shared/services/config-file.ts`
- `plugin/source/.../rc.unraid-api`
- `dependencies.sh`
- `api_utils.sh`
- `cli/restart.command.ts`
- `app/lifecycle.service.ts`

Findings:

- Enabled API plugins are persisted in `/boot/config/plugins/dynamix.my.servers/configs/api.json`.
- Runtime dependencies live at `/usr/local/unraid-api/node_modules`.
- The versioned boot archive restores only `node_modules`; it does not preserve runtime edits to the API root `package.json`.
- Current discovery filters configured plugins through root dependencies, so a restored external package can be ignored after reboot.
- CLI, GraphQL, and third-party reconcilers can mutate the same npm tree/archive/config from separate processes; current code has no shared cross-process transaction lock.
- GraphQL add/remove does not explicitly await `ApiConfigPersistence.persist()` before scheduling the 300 ms restart. The persister returns false for both unchanged data and failure, so the transaction must interpret that result using whether the canonical list actually changed; equality suppression avoids a duplicate observer write. Reboot-safe discovery must read each enabled canonical package's exact top-level manifest directly.
- The archive is a same-version reboot optimization. API-version upgrades require third-party package reconciliation from their own cached source.
- CLI plugin installation explicitly persists config and restarts the API by default. GraphQL plugin mutations currently rely on buffered background persistence and schedule a delayed restart, so the corrected design must await persistence and share a cross-process transaction/restart lock.
- The shared lifecycle token can restart the API from a plugin, but Runner Farm package installation should use the CLI/service script outside the running process.

### Plugin generator

- `packages/unraid-api-plugin-generator`
- commit `1e7ae566` in upstream history

Findings:

- The reviewed generator creates an independently installable, buildable, pack-valid scaffold and emits `unraidVersion` metadata plus a GPL default license.
- Runner Farm retains its repository's Apache-2.0 license.
- Framework singleton packages use compatible peer ranges tested against API 4.36.1; plugin-owned utilities such as Execa and Zod are normal dependencies rather than accidental peers.
- The implementation task must re-read the generator and host versions at build time instead of assuming the reviewed metadata remains current.

## Confirmed upstream installer gap

The current service adds the raw install argument to `api.plugins` before npm runs. Discovery later matches configured names against root dependency keys. A local tarball path is enabled under the wrong identity, and even a corrected canonical entry can fail after reboot because the modified root manifest is not archived.

A DEVHOST fixture proved:

- npm saves a local tarball under its canonical package name in `peerDependencies`;
- `npm install --json` reports canonical name and version for a changed install;
- a no-op reinstall has empty change arrays, so manifest-based fallback is required;
- a separate fixture confirmed `npm uninstall <canonical-name>` removes a restored top-level package even after its root dependency entry is removed.

The exact upstream patch and interim helper are specified in `upstream-install-spec-resolution.md`.

## MCP code reviewed

The current Unraid MCP implementation was traced under:

`/home/jmagar/workspace/unraid-mcp/unraid-rs`

Relevant files:

- `src/mcp/schemas.rs`
- `src/mcp/tools.rs`
- `src/graphql.rs`
- `src/gql_typed.rs`
- `src/app.rs`
- `src/cli/dispatch.rs`

Findings:

- The MCP tool uses a static action enum and static dispatch.
- GraphQL operations are typed with Cynic.
- New plugin schema fields do not appear automatically as MCP actions.
- Runner Farm actions require explicit additions to schema, typed fragments, client methods, service methods, dispatch, help, tests, and fixtures.
- Secret-setting actions should remain absent from the default MCP surface.

## Design conclusions

1. Keep the existing Unraid plugin and shell controller.
2. Add an independently packaged NestJS API module, not a TypeScript controller rewrite.
3. Add a strict local JSON boundary for the adapter.
4. Extract shared PHP config and secret operations from the WebGUI endpoint.
5. Require exact revisions for every conflicting mutation.
6. Preserve migration, ownership, compatibility, session, capacity, and reservation distinctions.
7. Use existing Unraid authentication and fixed permissions.
8. Make compatibility, build, and validation operations asynchronous.
9. Upstream canonical install resolution, direct top-level package discovery, and atomic archive replacement are the long-term installer requirements.
10. Retain a capability-detected interim installer and bounded boot/API-upgrade reconciler until that complete upstream capability is the minimum supported version.
11. Store generic GraphQL-visible operations durably on the configured cache dataset and reconcile interrupted state after boot.
12. Extend `unraid-mcp` explicitly with static typed actions.
13. Do not expose secret-setting actions through MCP by default.
