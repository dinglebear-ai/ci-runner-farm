# Ten-minute tasks: Runner Farm strict controller API, mutations and operations

Continue after `implementation-plan-controller.md`.

## A04. Add exact operation-read request parsing

Validate one canonical UUID and route only to the durable operation journal. Test invalid/missing IDs and absent/pruned records.

## A05. Add runner and history log reads

Validate one existing runner-name grammar, line count 1-500, existing symlink/size/redaction rules, and a 64 KiB response cap for current and retained JIT logs.

## A06. Add controller-log read

Select only the existing farm/boot log sources through a fixed verb, apply existing filtering, line/byte caps, and no caller path.

**Done:** no client-supplied filesystem path is accepted.

## C11. Add revision guard helpers

**Files:** `runner-api.sh`; tests.

**Change:** provide two guard helpers: config-only and fleet. The fleet guard requires both config and inventory revisions after acquiring the fleet lock and refreshing both authorities. Return current observed revisions on mismatch.

**Test:** alter config or inventory after request creation and assert zero side effects.

**Done:** lifecycle verbs can reuse one race-safe guard.

## C12. Codify existing lock ownership

**Files:** `runner-farm.sh`; existing lifecycle and lock tests.

**Change:** the reviewed `cmd_start`, `cmd_stop`, and `cmd_restart` functions are already unlocked; dispatch owns `with_fleet_lock`. Add comments/tests that preserve that boundary and route strict mutations through the same single lock owner. Do not create unnecessary duplicate `*_unlocked` functions.

**Test:** legacy and strict dispatch each acquire one fleet lock; no double lock or unlocked mutation path.

**Done:** lock ownership is explicit and regression-protected.

## F01. Add strict start

Acquire one fleet lock, refresh config/inventory, require both revisions, call `cmd_start`, and emit observed revisions. Test credentials, transition block, stale authorities, partial-capacity result, and no deadlock.

## F02. Add strict stop

Use the same guard/lock boundary, call `cmd_stop`, and preserve forced operator teardown semantics. Test stale authorities, scale-set ineligibility warning, empty fleet, and complete cleanup.

## F03. Add strict restart

Under one fleet lock, guard once and call the existing restart sequence without nested locking. Test stale authorities, stop failure, start partial failure, and exact result mapping.

**Done:** each lifecycle control has an independent focused test.

## C14. Add strict scale

**Files:** `runner-api.sh`; tests.

**Change:** validate target 0 to 64 and optional pool ID. Require config and inventory revisions. Preserve pool-mode no-zero and current backend admission rules.

**Test:** 65, malformed pool, pool zero, stale revisions, resource block, success.

**Done:** scale behavior matches the current controller.

## C15. Add strict prewarm

**Files:** `runner-api.sh`; tests.

**Change:** require pool ID, target, and config revision. Call the existing prewarm path only after backend admission and revision validation.

**Test:** invalid pool, stale config, backend not ready, successful reservation.

**Done:** prewarm cannot act on stale pool configuration.

## F04. Add strict recycle

Validate exact runner identity plus config/inventory revisions, then call the existing forced recycle under one fleet lock. Test busy/error/retiring/removed-not-recreated and stale identity.

## F05. Add strict maintenance

Accept only BEGIN or RESUME plus config revision, map to existing begin/resume behavior, and return the resulting boolean state. Test idempotent begin/resume and stale config.

**Done:** no arbitrary container name reaches Docker.

## F06. Add queued-run cancellation

Validate configured `owner/repo`, decimal/string run ID, current queue membership, live GitHub queued state, and existing HTTP result mapping. Test stale queue and no-token cases.

## F07. Add package-cache clear

Require config revision and call only the existing safe package-cache removal. Test unsafe root, protected work/docker directories, partial failure, and success.

**Done:** cancellation and deletion have separate focused safety tests.

## F08. Add begin-migration mutation

Require all four authorities, validate requested scaleset state, and invoke the existing forward state machine. Test each mismatch, missing compatibility evidence, resume from each forward phase, and success.

## F09. Add rollback mutation

Require the persisted four-authority set and invoke the existing reverse state machine. Test every reverse phase, assigned-JIT drain block, exact-owned deletion, and classic restoration.

**Done:** forward and reverse transitions have independent authority tests.

## O01. Add a generic durable operation module

**Files:** create `runner-operations.sh` and operation tests.

**Change:** store low-frequency bounded mode-0600 JSON metadata under `$CFGDIR/operations` with schema version, UUID, kind, state, stable code/message, config revision, timestamps, worker identity, and a fixed output-source enum, operation identity, and a small sanitized terminal summary. Writes are same-directory atomic; high-volume logs remain under existing tmpfs/cache locations and are resolved only beneath approved roots.

**Test:** create/read/update, invalid ID, symlink, oversized record, atomic failure.

## O02. Add operation retention

Prune terminal records by explicit age/count bounds without touching compatibility evidence or JIT diagnostic directories.

**Test:** newest retained, non-terminal retained, unrelated files untouched.

## O03. Add boot interruption reconciliation

At boot/maintenance, inspect QUEUED/RUNNING records. If no recoverable worker exists, atomically mark FAILED with `operation_interrupted`; never silently report success.

**Test:** live worker, missing worker, reboot boot-ID mismatch, terminal no-op.

## O04. Adapt compatibility-test worker

Require config revision, create the durable record before launch, preserve existing compatibility evidence behavior, and update terminal code/summary. Test stale config, duplicate-running policy, probe failure, and success.

## O05. Adapt provisioning-validation worker

Move the existing synchronous validation body behind a durable worker and operation ID. Test launch failure, Docker validation failure, cleanup, and success.

## O06. Adapt image-build worker

Bind to saved Dockerfile SHA, retain existing build lock/log mechanics as runtime coordination, and write durable terminal metadata/summary. Test stale SHA, already running, build failure, and success.

## O07. Publish generic operation state in status/readiness

Replace the old scale-set tmpfs latest-operation lookup with the generic journal summary and test running/interrupted/terminal parity.

## O08. Add exact operation read verb

`operation-read` resolves only one UUID from the durable journal and returns not found for absent/pruned records.

**Done:** GraphQL requests do not remain open for workers and operation truth survives reboot.

## C20. Run the strict shell gate

**Commands:**

```bash
bash tests/graphql-controller-api.sh
bash tests/backend-safety.sh
bash tests/config-parity.sh
bash tests/backend-migration.sh
bash tests/scale-set-control.sh
bash tests/jit-recovery.sh
bash -n src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-api.sh
git diff --check
```

**Done:** strict reads and mutations are bounded and legacy controller behavior remains green.
