# CI Runner Farm GraphQL plugin contract

## Status

This document is normative for `unraid-api-plugin-ci-runner-farm`. The public contract is `schema.graphql`; implementation references are indexed in `reference/README.md`; lifecycle and release requirements continue in `runtime-contract.md`.

MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative terms.

## 1. Architectural boundary

The GraphQL package is an adapter, not a second fleet controller.

The existing Runner Farm shell modules remain authoritative for Docker lifecycle, runner registration, protected credential handoff, pools, resource admission, scale sets, JIT recovery, migration, ownership, compatibility evidence, cache safety, and reconciliation.

The adapter calls fixed local entry points and normalizes versioned results. It MUST NOT reproduce those state machines in TypeScript, call arbitrary shell commands, or invoke `exec.php`. The WebGUI endpoint remains coupled to Unraid's POST/CSRF path.

## 2. Runtime components

The implementation contains:

1. `unraid-api-plugin-ci-runner-farm`, an ESM NestJS module loaded by Unraid API.
2. `runner-farm.sh api <verb>` for strict non-secret controller reads and mutations.
3. `config-cli.php` for configuration and Dockerfile reads/writes.
4. `secret-cli.php` for stdin-only credential changes.
5. a generic durable operation-metadata journal under `$CFGDIR/operations`; high-volume logs remain on tmpfs or the configured cache dataset.

The WebGUI and GraphQL adapters share PHP configuration, Dockerfile, and secret helpers. Existing legacy controller verbs remain compatible while GraphQL uses only the strict interfaces.

## 3. Plugin ABI and package compatibility

The package entry point exports:

```ts
export const adapter = 'nestjs';
export const ApiModule = RunnerFarmPluginModule;
```

The package is ESM and publishes compiled `main`, `types`, and `exports` entries.

It includes `unraidVersion` metadata generated from the current official plugin generator and verified against supported hosts at implementation time. The reviewed generator emitted `min: ^6.12.15` and `max: ~7.1.0`; those values are evidence, not a timeless constant.

NestJS, GraphQL, RxJS, class-transformer, class-validator, `graphql-scalars`, and `@unraid/shared` are framework peer dependencies with ranges that include the reviewed API 4.36.1 versions. Plugin-owned utilities such as Execa and Zod are normal dependencies. Runner Farm's package license remains Apache-2.0.

The package MUST NOT require install-time lifecycle scripts to become runnable; the release tarball already contains compiled output.

## 4. Authentication and permissions

Unraid API's global authentication and `AuthZGuard` apply to plugin fields. Every resolver uses `UsePermissions` from `@unraid/shared/use-permissions.directive.js`.

Until upstream supports plugin-defined resources, v1 maps:

| Capability | Action | Resource |
|---|---:|---:|
| Fleet, readiness, queue, image, cache, operations | `READ_ANY` | `DOCKER` |
| Lifecycle, scale, prewarm, recycle, queue cancellation | `UPDATE_ANY` | `DOCKER` |
| Package-cache clear | `DELETE_ANY` | `DOCKER` |
| Configuration and Dockerfile reads | `READ_ANY` | `CONFIG` |
| Configuration, credentials, compatibility, migration, Dockerfile writes | `UPDATE_ANY` | `CONFIG` |
| Runner, history, controller, and build logs | `READ_ANY` | `LOGS` |

Resolvers do not assume a WebGUI session. API keys, authenticated local sessions, server headers, cookies, and authenticated GraphQL WebSockets are governed by the host API.

## 5. Fixed process boundary

Resolvers select a named operation from `reference/contracts.ts`. They cannot submit an executable, path, verb, timeout, environment variable, or arbitrary argument vector.

Invocation uses an argument array with `shell: false`. Submitted values travel only in a bounded stdin body. Secrets use the dedicated secret CLI and never use the general request envelope.

### 5.1 General request envelope

Mutations and parameterized reads receive one JSON object no larger than 1 MiB:

```json
{
  "schema_version": 1,
  "request_id": "7bb90867-3378-4ae3-81bb-74ce20fd3274",
  "operation": "scale",
  "expected": {
    "config_revision": "64 lowercase hex",
    "inventory_revision": "64 lowercase hex"
  },
  "input": {}
}
```

The trusted GraphQL adapter serializes this object. The controller still validates JSON type, schema version, request ID, exact operation, required fields, unknown fields, bounds, control characters, and verb-specific invariants before mutation. Direct local callers are privileged but receive the same validation.

Large nested data is exchanged through stdin or bounded mode-0600 files. It MUST NOT be embedded in command-line arguments.

### 5.2 Response envelope

A strict operation emits exactly one JSON object to stdout:

```json
{
  "schema_version": 1,
  "request_id": "7bb90867-3378-4ae3-81bb-74ce20fd3274",
  "ok": true,
  "code": "ok",
  "message": "fleet scaled",
  "result": {},
  "observed": {
    "config_revision": "...",
    "inventory_revision": "...",
    "transition_revision": "...",
    "ownership_revision": "...",
    "compatibility_record_id": "...",
    "credential_revision": null
  }
}
```

stdout contains only the envelope. Diagnostics go to bounded stderr or controller-owned logs. General stdout is capped at 1 MiB and log content at 64 KiB. Result JSON is validated from stdin or a file, not interpolated through shell argv.

### 5.3 Exit codes

| Exit | Meaning |
|---:|---|
| 0 | A valid envelope was produced; inspect `ok` and `code`. |
| 2 | Request parsing or shape failed before a trusted operation. |
| 3 | Optimistic-concurrency conflict. |
| 4 | Domain validation failure. |
| 5 | Durable local commit or I/O failure. |
| 124 | A timeout wrapper expired. |
| other | Unexpected controller failure. |

The adapter parses a valid envelope even with nonzero exit. Missing, multiple, malformed, unsupported, or oversized JSON becomes a sanitized backend error.

## 6. Optimistic concurrency

### 6.1 Fleet revisions

Start, stop, restart, scale, and recycle require both `configRevision` and `inventoryRevision`. The controller acquires the fleet lock, reloads configuration, refreshes inventory, compares both, and performs no mutation on mismatch.

Inventory revision is not optional for those operations.

### 6.2 Configuration revision

Configuration validation/apply, secret set/clear, prewarm, maintenance, cache clear, provisioning validation, and compatibility-test start require `expectedConfigRevision` whenever their meaning depends on current configuration.

Configuration validation requires a revision because a partial patch is merged with current values.

### 6.3 Backend transition authorities

Migration and rollback require all four existing authorities:

- configuration revision;
- ownership revision;
- compatibility record ID;
- transition revision.

Each is compared under the appropriate controller lock. Any mismatch fails closed with a distinct stable code.

### 6.4 Dockerfile identity

Dockerfile save requires the SHA-256 of the content the caller read. Image build requires the SHA-256 returned by the successful save. Concurrent editor changes return `stale_dockerfile`.

### 6.5 Operations

Operation lookup and subscriptions require one exact canonical operation UUID. They never fall back to the latest operation.

## 7. Status and readiness

The legacy controller status remains schema version 2. The strict status operation validates it and adds exact, non-lossy fields where the existing UI model is intentionally coarse.

Required strict behavior:

- whole-core `cpus` is supplemented by nullable exact `cpu_milli`;
- whole-GiB `mem_gb` is supplemented by nullable exact `memory_bytes`;
- negative unknown usage sentinels normalize to null;
- workflow run, job, work-handle, remote scale-set, and other potentially unsafe numeric identifiers serialize as strings before JavaScript parsing;
- image metadata includes a full image ID and exact byte size;
- invalid backend, mode, and auth states remain representable as `INVALID`, not coerced to a valid enum;
- resource state includes `available` plus a stable reason; zeroed fail-closed quantities are never presented as confirmed capacity;
- readiness includes a nullable cached fleet count and never refreshes Docker solely to answer the query;
- optional pool fields remain nullable for unknown or retiring identities.

GraphQL child fields resolve from one validated snapshot. They MUST NOT rerun Docker or GitHub work per field.

Private repository, branch, pull-request, workflow-run, and job context is authenticated `DOCKER` data and is never republished to the unauthenticated Nchan dashboard channel.

## 8. Configuration contract

The durable source remains:

`/boot/config/plugins/ci-runner-farm/ci-runner-farm.cfg`

The Node adapter does not parse or write it directly.

`config-cli.php read` returns a configuration snapshot containing:

- current revision;
- validity and typed issues;
- nullable typed configuration;
- canonical effective string values for all 48 allowlisted keys;
- one opaque credential revision plus credential-presence booleans; no secret fingerprint is returned.

This remains useful even when manual edits have made the configuration invalid.

Typed mapping preserves all controller sentinels:

- null default CPU/memory means an empty uncapped value;
- resource-budget null means `auto`;
- `workspaceMode=CACHE_BIND` means empty `WORK_TMPFS_SIZE`;
- pool autoscale mode distinguishes `inherit` from an explicit empty set;
- nullable strings intentionally clear fields such as runner group, app IDs, image, and registry identity;
- memory swap accepts only `NONE` or `DOUBLE`.

Apply and validation:

1. read one bounded typed patch from stdin;
2. reject unknown fields;
3. map to exact allowlisted keys;
4. merge with the revision-guarded current snapshot;
5. enforce existing controller semantics and byte limits;
6. stage mode 0600 in the configuration directory;
7. call the existing `apply-config` transaction for commit;
8. delete staging files on every path.

Validation uses the same mapping and semantic checks but performs no flash commit, daemon restart, scale override, or reconciliation.

## 9. Secret contract

Secret mutations invoke `secret-cli.php`; secret bytes travel only on stdin.

Limits match current WebGUI behavior:

- GitHub PAT: 255 bytes plus existing shape and live-auth checks;
- GitHub App private key: 32 KiB and exactly one accepted PEM key;
- registry token: 4096 bytes.

The configuration snapshot exposes one opaque credential revision in addition to presence booleans. Every set or clear operation requires both the expected configuration revision and expected credential revision. The configuration revision guards auth mode and IDs; the credential revision guards concurrent out-of-band or API secret changes.

A private mode-0600 credential-state file beneath `$CFGDIR` stores a random public revision and private fingerprints of the three secret files. It is never returned. Secret reads and mutations share a lock. If state is missing or fingerprints do not match because of a legacy/manual/crash change, the helper reconciles the private state to a new random revision before comparing expectations. A crash between secret replacement and state replacement is therefore detected and repaired rather than accepting the old revision.

Secret values and private fingerprints never appear in argv, environment, stdout, stderr, GraphQL errors, Pino logs, operation output, PubSub payloads, filenames, or configuration results. Writes are same-directory atomic mode-0600 replacements. Failed validation or write preserves the previous value. Relevant cached GitHub App sessions are invalidated after successful key changes.

## 10. Durable operation contract

Compatibility, image-build, and provisioning-validation operations use one generic controller-owned journal beneath:

`$CFGDIR/operations`

Each record is a bounded regular mode-0600 JSON file with schema version, operation ID, kind, state, stable code, sanitized message, timestamps, configuration revision, a fixed output-source enum plus operation identity, a small sanitized terminal output summary, and worker identity where applicable. It never stores a caller-controlled absolute path; controller code resolves output only beneath approved tmpfs/cache roots.

State changes are atomic. Boot reconciliation marks a `QUEUED` or `RUNNING` record `FAILED` with `operation_interrupted` when no recoverable worker exists. Terminal records are retained under bounded count and age rules. Runtime tmpfs PID and lock files are not operation truth.

See `runtime-contract.md` for subscriptions, packaging, installation reconciliation, tests, and release gates.
