# CI Runner Farm as an Unraid GraphQL API plugin

## What this package defines

This directory is the researched implementation package for turning CI Runner Farm into a first-class extension of the official Unraid GraphQL API while keeping the current Unraid plugin and controller intact.

The central design is:

```text
Authenticated client or MCP
          │
          ▼
Unraid API GraphQL endpoint
          │
          ▼
unraid-api-plugin-ci-runner-farm
  typed models, validation, permissions,
  normalization, operations, subscriptions
          │
          ▼
strict local process contracts
  runner-farm.sh api <verb>
  config-cli.php
  secret-cli.php
          │
          ▼
existing Runner Farm controller
  locks, revisions, Docker, GitHub, pools,
  scale sets, JIT, reservations, migration
```

The GraphQL package is a lens and a control adapter. It is not a replacement engine.

## Worktree and research basis

The design was produced in:

`/home/jmagar/workspace/ci-runner-farm/.claude/worktrees/graphql-api-plugin-design`

on branch:

`worktree-graphql-api-plugin-design`

Runner Farm base revision:

`086274a45ec4f598e8013f9d109cd2983cfce4e4`

Unraid API revision reviewed:

`98034ff8405d8f1322daca9bd4d7d7dccc262810`

The evidence and reviewed files are recorded in `research.md`.

## Documents

| File | Purpose |
|---|---|
| `audit-2026-08-05.md` | Full accuracy audit, corrected issues, evidence, validation, and remaining live gates. |
| `research.md` | Code and runtime evidence used to make every design decision. |
| `spec.md` | Product and architecture specification. |
| `schema.graphql` | Target public GraphQL schema and schema-diff fixture. |
| `contract.md` | Core adapter, process, revision, configuration, and secret contract. |
| `runtime-contract.md` | Operations, subscriptions, security, packaging, MCP, tests, and release contract. |
| `upstream-install-spec-resolution.md` | Exact Unraid API patch for canonical local tarball and directory plugin installation. |
| `mcp-tools.md` | Static Unraid MCP actions, scopes, fields, code locations, and tests. |
| `implementation-plan.md` | Ordered execution map and gates. |
| `implementation-plan-upstream.md` | Ten-minute tasks for the Unraid API upstream patch. |
| `implementation-plan-controller.md` | Ten-minute tasks for strict controller envelopes and read APIs. |
| `implementation-plan-controller-advanced.md` | Ten-minute tasks for guarded lifecycle, capacity, migration, and operations. |
| `implementation-plan-controller-php.md` | Ten-minute tasks for shared configuration, Dockerfile, and secret CLIs. |
| `implementation-plan-graphql.md` | Ten-minute tasks for the NestJS package and read queries. |
| `implementation-plan-graphql-mutations.md` | Ten-minute tasks for configuration, secrets, controls, operations, and subscriptions. |
| `implementation-plan-packaging.md` | Ten-minute tasks for deterministic packaging, install, upgrade, reboot, and removal. |
| `implementation-plan-mcp.md` | Ten-minute tasks for static Rust MCP actions and Labby verification. |
| `reference/types.ts` | Raw shell types and internal interfaces. |
| `reference/enums.ts` | Code-first enum definitions. |
| `reference/common.models.ts` | Shared output models. |
| `reference/fleet.models.ts` | Fleet, pool, runner, and readiness models. |
| `reference/configuration.models.ts` | Typed configuration output models. |
| `reference/auxiliary.models.ts` | Queue, statistics, cache, image, Dockerfile, and log models. |
| `reference/input.models.ts` | Validated code-first GraphQL inputs. |
| `reference/contracts.ts` | Fixed commands, bounds, permissions, and stable domain errors. |

## Why this architecture

### The shell controller already has the hard parts

Runner Farm already implements:

- fleet and per-pool locking;
- deterministic configuration revisions;
- atomic mode-0600 configuration commits;
- exact pool grammar and resource claims;
- bounded Docker inventory snapshots;
- protected credentials and one-time JIT handoff;
- resource reservation files;
- scale-set request sequencing and replay safety;
- compatibility evidence;
- durable ownership state;
- backend migration and rollback;
- current image-build and compatibility runtime state, plus the need for a new reboot-durable generic operation journal;
- broad regression and release gates.

Rebuilding those behaviors in the API package would create two authorities and invite drift. The adapter therefore invokes strict controller verbs and maps results.

### The WebGUI endpoint is not a reusable API

`exec.php` is correctly protected for the WebGUI. It expects POST, uses Unraid's global CSRF prepend, parses form fields, and then runs controller commands. API-key-authenticated GraphQL requests do not have that CSRF context.

The solution is not to weaken `exec.php`. The solution is to extract its reusable configuration, Dockerfile, and secret functions into CLIs with explicit stdin contracts. Both adapters use the same core logic.

### Unraid API already provides the platform

The upstream API has a genuine plugin ABI:

```ts
export const adapter = 'nestjs';
export const ApiModule = RunnerFarmPluginModule;
```

Loaded modules participate in code-first schema generation, global authentication, authorization, API keys, subscriptions, logging, lifecycle services, and shared scalars.

That gives Runner Farm one official endpoint instead of another daemon.

## Installation strategy

### Durable route

The Runner Farm package ships a compiled npm tarball. Its installer calls:

```bash
unraid-api plugins install   /boot/config/plugins/ci-runner-farm/api/unraid-api-plugin-ci-runner-farm-<version>.tgz   --no-restart
```

Unraid API must serialize plugin-tree mutations through a cross-process lock, resolve the tarball to the canonical package name, explicitly persist canonical config, atomically archive the installed dependency tree before enablement, discover enabled packages directly from exact top-level manifests, and restart once.

The reviewed upstream stores the raw path in `api.plugins` and later filters discovery through a root manifest that is not included in the archive. The required general fix covers both defects.

### Interim route

Until the complete upstream capability exists in the minimum supported release, Runner Farm includes one capability-detected installer and bounded boot/API-upgrade reconciler. It performs structured install, exact manifest verification, one atomic archive rebuild, canonical registration, and one restart only when state changed. GraphQL verification requires an explicitly supplied test/admin API key.

The helper is intentionally removable and must not become a second permanent registry.

## GraphQL surface

### Read model

The API exposes the complete authenticated fleet model, including private job context, through `runnerFarmStatus`.

It separately exposes readiness with a nullable cached fleet count, resource availability/reason, configuration, queue, run statistics, cache usage, image metadata, Dockerfile state, operations, and bounded logs.

### Mutations

Mutations do not trust stale UI state. They require the same authorities the controller already uses:

- configuration plus inventory revision for lifecycle, scale, and recycle;
- configuration revision for partial config validation/apply, credentials, prewarm, maintenance, cache clear, provisioning validation, and compatibility start;
- transition revision, ownership revision, compatibility record, and configuration revision for backend migration;
- previously read Dockerfile SHA for Dockerfile save.

Configuration changes are typed patches but still commit through the existing staged atomic transaction.

### Operations

Compatibility tests, provisioning validation, and image builds create durable low-frequency metadata records under `$CFGDIR/operations`, keep high-volume output off flash, and return exact IDs. Boot reconciliation marks abandoned non-terminal work interrupted; clients query or subscribe to those records.

### Subscriptions

Status subscriptions share one bounded polling producer and emit only when authority revisions change. Operation subscriptions complete after a terminal state. V1 does not stream complete build logs.

## Permission model

Unraid API currently validates permission resources against a fixed enum, so an external plugin cannot define `CI_RUNNER_FARM` yet.

V1 maps fields to:

- `DOCKER` for fleet state and control;
- `CONFIG` for settings, credentials, compatibility, migration, and Dockerfiles;
- `LOGS` for log content.

This is explicit in the schema and reference contract. A later upstream permission-resource extension can replace the mapping without changing controller behavior.

## Secret model

GraphQL has credential mutations for direct trusted clients, but secrets move only through stdin to a fixed PHP CLI. The configuration snapshot includes an opaque credential revision, and every set/clear supplies both config and credential revisions. They never appear in command arguments, environment variables, logs, operation output, PubSub, models, or error extensions.

The default MCP tool intentionally excludes credential mutation actions.

## MCP path

The current Rust Unraid MCP server is static. It has a fixed action enum, Cynic fragments, client methods, and dispatch arms. New GraphQL fields will not appear by introspection.

The design adds explicit Runner Farm actions in phases:

1. status and readiness;
2. queue, statistics, cache, image, operations, and logs;
3. lifecycle and capacity control;
4. configuration validation and apply;
5. long operations and migration.

Each action preserves `unraid:read` or `unraid:admin` scope requirements.

## Cross-repository delivery

The work spans three repositories:

### Unraid API

- fix canonical install-spec resolution;
- discover configured packages directly from exact top-level manifests;
- make archive replacement atomic;
- add install, reboot, removal, and failure-isolation tests;
- release the complete capability.

### CI Runner Farm

- add strict non-lossy controller API verbs and a durable generic operation journal;
- extract shared config and secret logic;
- add the NestJS package;
- package and install it;
- add GraphQL and live Unraid tests;
- retain existing release gates.

### Unraid MCP

- refresh schema;
- add Cynic models and operations;
- add service methods and static actions;
- test scopes, inputs, bounds, and help;
- verify through Labby.

## Definition of done

The implementation is done when a supported Unraid host can:

1. install Runner Farm and its local API package;
2. restart Unraid API and discover the module;
3. query full typed status with an authorized read-only API key;
4. reject that key on mutations;
5. validate and apply configuration with an admin key and exact revision;
6. reject stale mutations with zero side effects;
7. run and durably observe image, validation, and compatibility operations by ID, including interrupted-boot recovery;
8. perform backend migration only with all four exact authorities;
9. complete a same-version offline reboot without relying on a modified root manifest;
10. reattach the flash-cached package after an API-version upgrade;
11. invoke static Runner Farm MCP actions through Labby;
12. uninstall the API module while retaining Runner Farm configuration and credentials.

The implementation plan in this directory decomposes that result into short, testable increments.
