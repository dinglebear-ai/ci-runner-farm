# CI Runner Farm GraphQL runtime, security, and lifecycle contract

This document continues `contract.md`.

## 11. Operations

Compatibility testing, image build, and provisioning validation are asynchronous. A start mutation returns after a durable operation record has been atomically created and a worker has been launched or queued.

Operation truth is the low-frequency metadata journal under `$CFGDIR/operations`, not a tmpfs PID, lock, build log, or the current scale-set compatibility-operation directory. High-volume output remains on tmpfs or the configured cache dataset and is referenced by a fixed output kind and operation ID, never an arbitrary path. The metadata record retains only a small sanitized terminal summary so post-reboot operation queries remain useful when volatile logs are gone.

Every record includes an immutable UUID, kind, state, stable code, sanitized message, configuration revision, created/updated/finished times, and bounded output metadata. Terminal states are `SUCCEEDED`, `FAILED`, or `CANCELLED`.

At boot, the controller reconciles non-terminal records. An operation without a recoverable worker becomes `FAILED` with `operation_interrupted`. Terminal records are pruned by bounded age and count without deleting compatibility evidence or JIT diagnostics governed by their own contracts.

Backend migration continues to use its existing durable transition state machine. Its GraphQL result references current transition state but does not duplicate migration truth in the generic operation journal.

## 12. Subscriptions

Subscriptions use Unraid API's `graphql-ws` endpoint and inherit authentication and field permissions.

### 12.1 Status updates

`runnerFarmStatusUpdates` shares one producer across subscribers. The producer starts with the first subscriber, stops with the last, polls no faster than once per second, defaults to five seconds, and publishes only when the normalized authority tuple or visible state changes.

The authority tuple includes configuration, inventory, transition, ownership, compatibility-record, and operation state identities. Superseded snapshots are dropped rather than queued without bound.

### 12.2 Operation updates

`runnerFarmOperationUpdates(operationId)` watches one exact durable record. It emits only changed state/output, emits a terminal state once, completes, and releases its timer/iterator. Unknown IDs fail before an iterator is returned.

### 12.3 Logs

Full log streaming is deferred. V1 provides bounded authenticated snapshots. This avoids unbounded PubSub queues and accidental replication of private build output.

## 13. Error mapping

Domain failures normally return typed action results with `ok: false`. Authentication, authorization, GraphQL validation, and malformed transport requests use GraphQL errors.

Stable domain codes include revision conflicts, invalid config/pool/runner, backend-transition and readiness failures, resource-state-unavailable and resource-capacity blocks, operation not found/running/interrupted, secret validation/write failures, unsupported schema, backend unavailable, timeout, and output too large.

Adapter-generated GraphQL errors include a safe extension code and request ID. They never expose raw stack traces, shell commands, GitHub bodies, npm authorization, environment dumps, secret input, or unbounded stderr.

## 14. Limits

GraphQL applies client-facing validation; shell/PHP remains the security boundary.

| Item | Bound or rule |
|---|---|
| Fleet/manual target | 0-64, with existing pool-mode zero restrictions |
| Pool count | 8 |
| Serialized pool configuration | 16 KiB |
| Pool ID | existing lowercase 1-24 grammar |
| Label | existing 63-byte grammar and reserved-label rules |
| PAT | 255 bytes |
| GitHub App private key | 32 KiB |
| Registry token | 4096 bytes |
| Dockerfile | 1 MiB |
| General strict stdin/stdout | 1 MiB |
| Log content | 64 KiB |
| Requested log lines | 1-500 adapter bound |
| Image auto-update interval | 300-86400 seconds |
| Image drain timeout | 0 or 60-86400 seconds |
| Scale-set frame | existing 1 MiB protocol bound |
| Projected reservation CPU | 1-256000 millicores |
| Projected reservation memory | 1-1099511627776 bytes |
| Projected reservation phase | `reserved`, `offered`, `assigned`, `acting`, `observed`, `failed`, or `expired` |
| Status/readiness state files | regular, non-symlink, mode 0600, command-specific byte cap |

There is no invented count cap for repositories or additional labels; their existing per-item grammar and total serialized byte limits apply. Autoscale interval, idle grace, and PIDs limits use current controller nonnegative-integer semantics unless the controller is deliberately tightened in a separate change.

Numeric identifiers that may exceed JavaScript's safe integer range are strings in the strict JSON/GraphQL boundary. Public byte and millicore quantities use GraphQL `BigInt`.

## 15. Logging and privacy

The adapter logs resolver name, generated request ID, operation ID where applicable, duration, success or stable failure code, and transport-bound failures.

It never logs secret GraphQL variables. Logger and exception filters redact fields named value, token, privateKey, authorization, credential, or secret.

Authenticated status may contain private repository and job context. Log queries call fixed verbs and never accept paths. Existing name validation, symlink checks, file-size limits, and redaction remain mandatory.

Persisted operation output is sanitized before commit. GitHub tokens, authorization headers, PEM content, registration tokens, JIT descriptors, registry passwords, and Docker login material are redacted or omitted.

## 16. Availability and failure isolation

Runner Farm installation, WebGUI use, and fleet operation continue when Unraid API is absent, stopped, in safe mode, or unable to load the API package.

The GraphQL module fails closed when the Runner Farm controller is missing, not executable, or returns an unsupported schema. It returns backend unavailable rather than inventing an empty healthy fleet.

The module starts no autoscaler, scheduler, Docker event listener, scale-set supervisor, or reconciliation daemon. It observes and invokes the existing controller only.

Safe mode intentionally skips external API modules; Runner Farm does not bypass it.

## 17. API package installation and persistence

The compiled npm tarball is cached on flash beneath:

`/boot/config/plugins/ci-runner-farm/api/`

The canonical package name is `unraid-api-plugin-ci-runner-farm`.

### 17.1 Official path

After upstream implements canonical install resolution, direct top-level discovery, atomic archive replacement, explicit GraphQL persistence, and the shared cross-process transaction lock, Runner Farm calls the official CLI with its absolute tarball and `--no-restart`. The official service already rebuilds the archive; the outer installer MUST NOT rebuild it a second time.

### 17.2 Interim path

Older APIs use the compatibility installer specified in `upstream-install-spec-resolution.md`. It performs structured npm install, exact manifest verification, one atomic archive rebuild, canonical config registration, and one restart only when state changed.

### 17.3 Same-version reboot

The API's version-specific archive restores `node_modules`. Reboot-safe upstream discovery loads enabled canonical packages directly from restored top-level manifests. Runner Farm also runs bounded reconciliation because plugin install order is not guaranteed.

### 17.4 API-version upgrade

The old version's archive is not the new version's source of truth. Runner Farm retains its tarball on flash and reattaches it after the upgraded API becomes ready, then builds that version's archive and restarts only if required.

### 17.5 Verification

Install-time verification distinguishes:

- package presence and exact manifest identity;
- import/plugin-ABI verification through a CLI verification path;
- authenticated GraphQL schema and resolver verification, which requires an explicitly supplied test/admin API key.

Current `plugins list` alone does not prove `hasApiModule`.

### 17.6 Upgrade and removal

Upgrade retains the previous tarball and state until install, archive, restart, and verification succeed. Removal unregisters the canonical name, removes the exact package, atomically rebuilds the archive, restarts once, and preserves Runner Farm configuration and credentials by default.

## 18. Version compatibility

Three version axes are independent:

1. GraphQL package semantic version;
2. strict local envelope schema version;
3. existing status, migration, ownership, JIT, and scale-set protocol versions.

The adapter declares supported versions and returns an unsupported-schema error for unknown required versions. Adding nullable fields is compatible; removing fields, tightening nullability, or changing enum/domain-code meaning requires an appropriate major version.

The package's `unraidVersion` metadata is regenerated and verified against the current official generator and tested host matrix at implementation/release time.

## 19. MCP contract

GraphQL is the source API. The Rust Unraid MCP remains statically typed and requires explicit Cynic fragments, client methods, action schema entries, dispatch, help, and tests.

MCP v1 exposes the read and safe-control actions listed in `mcp-tools.md`. Fleet controls require both configuration and inventory revisions. Configuration validation/apply, maintenance, cache clear, provisioning validation, compatibility testing, and credential-independent actions require their documented configuration revision. Migration requires all four authorities.

Credential setters and raw Dockerfile-content writes are omitted from the default MCP surface because conversational and gateway traces may retain inputs.

## 20. Test contract

Every query suite proves raw-schema validation, non-lossy normalization, invalid-state handling, unsupported-version rejection, output bounds, timeout behavior, permission metadata, and parity with controller fixtures.

Every mutation suite proves GraphQL validation, controller revalidation, exact fixed command selection, no shell invocation, required revision conflicts, lock ordering, stable error mapping, timeout cleanup, and zero mutation on failure.

Configuration tests cover all 48 allowlisted keys and sentinel round-trips. Secret tests prove config-plus-credential revision conflicts, legacy/crash state reconciliation, field-specific limits, stdin-only transport, no leakage, atomic mode-0600 writes, old-value preservation, and session invalidation.

Operation tests prove durable record creation, atomic transitions, exact lookup, boot interruption reconciliation, bounded retention, and subscription completion.

Packaging tests prove deterministic tarballs, compiled ESM, compatible peer ranges, current `unraidVersion` metadata, official/interim installation, same-version reboot, API-version upgrade reconciliation, rollback, and removal.

## 21. Performance contract

The current full fleet snapshot has a deterministic 256 KiB controller budget. One GraphQL request obtains one normalized snapshot; child fields do not repeat controller work.

Status subscribers share one polling source. Queue, statistics, and cache queries preserve the controller's background-refresh behavior rather than synchronously fanning out to GitHub on each request.

## 22. Release gates

Release requires:

- all existing Runner Farm release gates;
- strict controller and shared PHP tests;
- API package test/build/pack and schema diff;
- permission and secret-surface audits;
- read-only key allowed only on read fields;
- admin key safe mutation smoke tests;
- stale revision tests with zero side effects;
- four-authority migration checks;
- durable operation interruption recovery;
- official or interim canonical installation;
- same-version offline reboot restore;
- API-version upgrade reattachment;
- static MCP read/control smoke tests through Labby;
- uninstall that removes the API module while retaining Runner Farm configuration.
