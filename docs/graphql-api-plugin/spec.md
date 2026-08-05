# Specification: CI Runner Farm Unraid GraphQL API plugin

## 1. Product definition

CI Runner Farm remains a native Unraid plugin that owns its WebGUI, shell controller, Docker lifecycle, configuration, and persistent state. This project adds an official Unraid API extension package named:

`unraid-api-plugin-ci-runner-farm`

The package extends the host GraphQL schema with typed Runner Farm queries, mutations, and subscriptions. It uses the host's authentication, API keys, permissions, schema generation, WebSocket transport, logs, and plugin lifecycle.

The package does not replace Runner Farm and does not expose a second network listener.

## 2. Goals

The implementation will:

1. Expose the complete operational Runner Farm model through authenticated GraphQL.
2. Preserve every existing controller safety property and transaction boundary.
3. Allow trusted API clients to inspect and control the fleet without WebGUI CSRF coupling.
4. Provide a typed source API for the existing Unraid MCP server.
5. Install, update, persist across reboot, and uninstall as part of the Runner Farm Unraid package.
6. Contribute upstream canonical install resolution, reboot-safe direct package discovery, and atomic archive replacement.
7. Keep a removable compatibility installer and bounded boot/API-upgrade reconciler until that complete upstream capability is available in the minimum supported Unraid API release.

## 3. Non-goals

V1 will not:

- rewrite the controller in TypeScript;
- move configuration out of the existing flash file;
- replace the WebGUI;
- expose arbitrary shell execution;
- expose arbitrary filesystem reads;
- create a second authentication system;
- create a custom TCP port or reverse proxy;
- expose registration tokens, GitHub credentials, registry credentials, JIT descriptors, or private keys;
- make pool labels into authorization boundaries;
- dynamically turn every GraphQL field into an MCP tool;
- expose secret-setting mutations through MCP by default;
- bypass Unraid API safe mode.

## 4. Components

### 4.1 Existing Unraid plugin

The existing `.plg` remains the outer product package. It installs:

- WebGUI pages;
- shell modules;
- PHP adapters;
- the scale-set helper binary;
- event scripts;
- Dockerfile defaults;
- the compiled API plugin tarball;
- API-package install and removal helpers.

### 4.2 Strict controller API

`runner-farm.sh` gains an `api` dispatcher with explicit verbs. It validates a versioned request envelope, applies existing locks and functions, and emits one versioned response envelope.

This dispatcher is the security boundary for non-secret GraphQL actions. It also augments legacy schema-v2 status with exact millicore, byte, identifier, and image fields that the UI's coarse model does not preserve. Existing legacy dispatch remains compatible.

### 4.3 Shared PHP CLIs

Configuration, Dockerfile, and secret behavior currently concentrated in `exec.php` is extracted into reusable PHP modules and two CLIs:

- `config-cli.php`
- `secret-cli.php`

The WebGUI endpoint delegates to the same functions. This prevents GraphQL and the WebGUI from developing different validation or durability semantics.

A new shell operation module stores low-frequency generic operation metadata under `$CFGDIR/operations`, keeps high-volume output off flash, and reconciles interrupted work after boot.

### 4.4 NestJS API package

The package contains:

```text
packages/unraid-api-plugin-ci-runner-farm/
├── package.json
├── tsconfig.json
├── tsconfig.build.json
├── src/
│   ├── index.ts
│   ├── runner-farm.module.ts
│   ├── contracts/
│   │   ├── raw.ts
│   │   ├── commands.ts
│   │   └── schemas.ts
│   ├── models/
│   │   ├── enums.ts
│   │   ├── common.models.ts
│   │   ├── fleet.models.ts
│   │   ├── configuration.models.ts
│   │   ├── auxiliary.models.ts
│   │   └── input.models.ts
│   ├── services/
│   │   ├── process-runner.service.ts
│   │   ├── controller-client.service.ts
│   │   ├── status-normalizer.service.ts
│   │   ├── configuration.service.ts
│   │   ├── secret.service.ts
│   │   ├── operation.service.ts
│   │   └── subscription.service.ts
│   └── resolvers/
│       ├── status.resolver.ts
│       ├── configuration.resolver.ts
│       ├── control.resolver.ts
│       ├── operation.resolver.ts
│       ├── logs.resolver.ts
│       └── subscriptions.resolver.ts
└── test/
```

The package exports `adapter = 'nestjs'` and `ApiModule`.

### 4.5 Upstream Unraid API patch

Unraid API serializes CLI, GraphQL, and third-party plugin-tree mutations through one cross-process transaction lock; resolves local directories, tarballs, registry specs, and Git specs into canonical names after npm succeeds; explicitly persists canonical config; atomically archives the installed tree before enablement; and discovers configured packages directly from exact top-level manifests. It no longer depends on runtime root-manifest edits that are not archived.

The patch is specified in `upstream-install-spec-resolution.md`.

### 4.6 Unraid MCP extension

The Rust `unraid-mcp` project adds static typed Runner Farm actions. Cynic fragments compile against the extended GraphQL schema. Existing `unRAID::unraid` action dispatch gains explicit Runner Farm cases.

## 5. GraphQL API

The target schema is `schema.graphql`. Runtime implementation is code-first NestJS.

### 5.1 Queries

V1 queries cover:

- full fleet status;
- backend readiness with nullable cached fleet count;
- a configuration snapshot containing revision, validity/issues, nullable typed configuration, canonical effective allowlisted strings, and credential presence;
- queued work;
- recent run statistics;
- cache usage;
- runner image metadata;
- saved and default Dockerfile;
- operation status;
- runner logs;
- history logs;
- controller logs.

A query that cannot obtain authoritative controller data returns an error. It must not synthesize a healthy empty object.

### 5.2 Mutations

V1 mutations cover:

- start, stop, and restart;
- scale and prewarm;
- recycle;
- maintenance begin and resume;
- typed configuration validation and apply;
- PAT, GitHub App private key, and registry token set or clear;
- Dockerfile save;
- asynchronous image build;
- asynchronous provisioning validation;
- asynchronous scale-set compatibility test;
- backend migration and rollback with four-revision preconditions;
- queued run cancellation;
- package-cache clear.

Fleet mutations require both configuration and inventory revisions. Partial configuration validation/apply, secret set/clear, prewarm, maintenance, cache clear, provisioning validation, and compatibility start require the current configuration revision. Migration requires all four authorities. Dockerfile save requires the previously read Dockerfile hash.

### 5.3 Subscriptions

V1 subscriptions cover:

- normalized fleet status changes;
- one operation's progress and terminal state.

Full log streaming is intentionally deferred.

## 6. Data model

### 6.1 Fleet snapshot

The fleet snapshot validates the existing schema-version-2 controller model and adds strict non-lossy fields where the UI model is coarse or fail-closed state needs explicit availability metadata.

It includes:

- configuration and inventory revisions;
- requested and effective backend;
- transition phase, ID, and revision;
- ownership revision;
- compatibility evidence and record identity;
- current operation;
- maintenance state;
- resource availability/reason plus CPU and memory budget, reserve, reserved, and admissible values;
- reservations and recent JIT activity;
- global autoscaling and image-update state;
- warnings and security warnings;
- pools and runners.

### 6.2 Pool model

The pool model keeps:

- routing and additional labels;
- exact resource claims;
- configured and effective targets;
- count, up, busy, idle, starting, error, completed, stale, retiring, and pending values;
- min, max, automatic max, and idle buffer;
- assigned jobs and demand freshness;
- desired, admitted, and advertised scale-set capacity;
- session health and lease age;
- ownership state, remote scale-set ID, tombstone, and orphan flags.

### 6.3 Runner model

The runner model keeps identity, pool, route, scope target, lifecycle state, job context, nullable exact CPU millicores and memory-limit bytes, nullable live usage, completed state, stale state, and retirement state. Potentially unsafe numeric IDs cross the JSON boundary as strings.

### 6.4 Configuration model

The configuration API groups existing keys into:

- GitHub identity and authentication mode;
- runner mode, backend, pool records, limits, and runtime identity;
- resource budget and policy;
- storage and cache mounts;
- image source and registry identity;
- Docker and network policy;
- autoscaling;
- image updates;
- dashboard widget setting.

The read response remains usable when the current file is invalid. It preserves empty uncapped CPU/memory values, resource-budget `auto`, workspace cache-bind versus tmpfs, `POOL_AUTOSCALE=inherit` versus an explicit set, and nullable strings used to clear fields. Credentials expose presence booleans plus one opaque credential revision; no secret value or fingerprint is returned.

## 7. Controller integration

### 7.1 Reads

Strict read verbs call existing bounded controller functions and wrap their output. Initial verbs are:

- `status`
- `readiness`
- `configuration-read` through `config-cli.php read`
- `queue`
- `statistics`
- `cache-usage`
- `image-info`
- `dockerfile-read`
- `operation-read`
- `runner-log`
- `history-log`
- `controller-log`

### 7.2 Mutations

Strict mutation verbs adapt to existing functions under existing locks. They do not bypass migration guards, resource admission, stale-runner rules, or secret-handoff rules.

Every mutation returns observed revisions, even on a domain failure.

### 7.3 Shared config logic

The typed config patch is translated to the existing exact key grammar in PHP. The shell validates the staged complete configuration and performs the commit. Neither TypeScript nor GraphQL becomes the source of truth for configuration rules.

### 7.4 Shared secret logic

The Node service passes the secret on stdin to a fixed PHP CLI command. The PHP helper owns validation and atomic writes. Secret buffers are excluded from logs and errors.

## 8. Security

### 8.1 Host trust

Self-hosted runners execute repository-controlled code. The GraphQL plugin does not change the trust model. Existing warnings for public repositories, privileged Docker-in-Docker, Docker socket sharing, and runner-group access remain visible.

### 8.2 Authorization

Unraid API permissions are enforced per field. V1 uses fixed core resources because custom plugin resources are not supported.

### 8.3 Injection resistance

No resolver constructs a shell command. Inputs are validated in GraphQL and again in the controller. Fixed executables and argument arrays are used. Secret bytes travel only on stdin.

### 8.4 Information disclosure

Private job context is authenticated. Logs are bounded and redacted. Arbitrary paths are not accepted. Errors are sanitized. No secret values appear in models, operation output, logs, or subscriptions.

### 8.5 Failure isolation

The package does not start controllers or daemons. If it fails, the WebGUI and existing farm remain functional. Safe mode disables the extension as designed.

## 9. Packaging lifecycle

### 9.1 Build

The Runner Farm build process:

1. builds the TypeScript API package;
2. runs package unit and schema tests;
3. creates a deterministic npm tarball;
4. records its SHA-256 and package version;
5. includes it under the Unraid package payload;
6. generates install metadata in the `.plg`.

### 9.2 Install

If Unraid API exists:

1. detect canonical install-spec capability;
2. use `unraid-api plugins install <tarball> --no-restart`, or use the interim helper;
3. let the official path perform its own atomic archive rebuild, while the interim path performs exactly one rebuild;
4. restart Unraid API once only when state changed;
5. verify exact package identity/import, and run GraphQL verification only with an explicitly supplied test/admin API key.

If Unraid API does not exist, Runner Farm installation succeeds and reports that GraphQL integration is inactive. A later repair/install action can attach the API package.

### 9.3 Upgrade

Upgrade is transactional at the package level. The new tarball remains on flash before install. Failure preserves the prior dependency and archive. Success removes superseded cached API tarballs.

### 9.4 Remove

Removal unregisters and uninstalls the API package when possible, rebuilds dependencies, and restarts Unraid API once. Runner Farm config and credentials remain unless explicitly purged.

### 9.5 Reboot and API upgrade

For a same-version reboot, the versioned archive restores `node_modules` and direct canonical discovery loads configured top-level packages without a modified root manifest. Runner Farm still runs bounded reconciliation because plugin install order is not guaranteed.

For an API-version upgrade, Runner Farm reattaches its flash-cached tarball to the new API dependency tree and builds that version's archive. The old archive is not the upgrade source of truth.

## 10. Upstream dependency strategy

The long-term supported route requires all three upstream pieces: canonical spec resolution, direct top-level package discovery, and atomic archive replacement. Runner Farm will not permanently own an alternate API plugin registry.

The interim helper:

- is capability-detected;
- is isolated in one install script;
- follows the same canonical-name transaction;
- has its own tests;
- is removed when the minimum supported Unraid API version includes the upstream fix.

## 11. MCP integration

The static Rust client adds typed actions after the GraphQL package is functional.

Read actions are first. Safe control actions follow with revision arguments. Configuration apply follows after typed input support. Secret setters are omitted from the default tool schema.

Every MCP action maps to one GraphQL operation and uses existing `unraid:read` or `unraid:admin` scopes. It bounds logs and list results before returning through Labby.

## 12. Testing strategy

### 12.1 Controller contracts

Shell and PHP tests cover envelopes, unknown fields, bounds, exact fixed commands, non-lossy status augmentation, revision conflicts, locking, atomic writes, durable operation recovery, secret leakage, sentinel round-trips, and parity with legacy actions.

### 12.2 Package unit tests

Vitest tests cover raw schemas, normalization, model mapping, process execution, timeouts, error mapping, operation state, subscriptions, and permission decorators.

### 12.3 Schema tests

A generated schema is normalized and compared with `schema.graphql`. Breaking changes fail CI.

### 12.4 Packaging tests

Tests build twice and compare tarball hashes, inspect package contents, validate peer dependencies, and run npm pack dry-run.

### 12.5 Live Unraid tests

A disposable or approved Unraid host proves install, restart, API-key authorization, safe read query, stale mutation rejection, API reload, reboot restore, and uninstall.

### 12.6 MCP tests

Rust unit and fixture tests prove action schemas, Cynic operations, dispatch, scopes, argument validation, bounded output, and representative read/control calls.

## 13. Delivery sequence

1. Land upstream canonical resolution, direct discovery, and atomic archive changes.
2. Add strict read-only controller APIs.
3. Scaffold and load a read-only API package.
4. Implement typed status, readiness, and auxiliary queries.
5. Extract configuration and secret helpers.
6. Implement configuration and secret GraphQL fields.
7. Implement lifecycle and capacity mutations with revisions.
8. Implement the durable generic operation journal, operations, and subscriptions.
9. Add packaging and interim install support.
10. Add MCP actions.
11. Run live restart, same-version reboot, and API-version upgrade reconciliation gates.
12. Remove the interim installer after the supported upstream release boundary advances.

## 14. Acceptance criteria

The feature is complete when:

- the Runner Farm WebGUI and controller pass all existing tests;
- the API package builds and packs deterministically;
- Unraid API loads the package with the target schema;
- read-only API keys can inspect allowed state and cannot mutate;
- admin keys can perform safe mutations;
- stale revisions cause zero side effects;
- migration requires all four authorities;
- credentials are never exposed;
- long operations are durably observable by ID and interrupted work is reconciled after boot;
- status subscriptions stop when unused;
- local tarball install persists under the canonical package name;
- same-version offline reboot restores the package without a modified root manifest;
- API-version upgrades reattach the package from Runner Farm's flash cache;
- static MCP actions work through Labby;
- uninstall removes the API extension while retaining Runner Farm configuration.
