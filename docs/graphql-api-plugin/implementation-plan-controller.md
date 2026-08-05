# Ten-minute tasks: Runner Farm strict controller API, foundation

Repository worktree:

`/home/jmagar/workspace/ci-runner-farm/.claude/worktrees/graphql-api-plugin-design`

Advanced strict verbs continue in `implementation-plan-controller-advanced.md`. Shared PHP tasks are in `implementation-plan-controller-php.md`.

## C01. Add the strict API test harness

**Files:** create `tests/graphql-controller-api.sh`.

**Change:** follow `tests/php-actions.sh` and `tests/backend-safety.sh`. Add helpers that run `runner-farm.sh api <verb>` with temporary config/runtime roots and capture stdout, stderr, and exit separately.

Initial assertion: unknown verb is rejected and stdout is either empty or one valid JSON object.

**Command:** `bash tests/graphql-controller-api.sh`.

**Done:** test fails because the API dispatcher does not exist.

## C02. Create the API shell module

**Files:** create `include/runner-api.sh`; modify `runner-farm.sh`.

**Change:** source the module and add:

```bash
api) runner_api_dispatch "${2:-}" ;;
```

Define:

```bash
RUNNER_API_SCHEMA_VERSION=1
RUNNER_API_MAX_REQUEST_BYTES=1048576
RUNNER_API_MAX_RESPONSE_BYTES=1048576
RUNNER_API_MAX_LOG_BYTES=65536
```

**Test:** unknown verb returns a controlled failure.

**Done:** legacy dispatch remains unchanged.

## C03. Add bounded stdin capture

**Files:** `runner-api.sh`; extend test.

**Change:** implement `runner_api_capture_request` that creates a mode-0600 file under `$RUNDIR/api-requests`, reads at most 1 MiB plus one byte, rejects overflow, and traps cleanup.

Use a fixed bounded read. Never read arbitrary stdin into one shell variable.

**Test:** exactly 1 MiB accepted; one extra byte rejected before controller invocation; no request file remains.

**Done:** request capture is bounded and ephemeral.

## C04. Add PHP request normalization

**Files:** create `include/api-request.php`; create `tests/api-request.php`.

**Change:** implement `validate <verb> <file>` and `fields <verb> <file>`.

Validate regular non-symlink file, size, UTF-8 JSON object, schema version, lowercase UUID, exact operation, known keys, and verb-specific shape.

The trusted Node adapter emits canonical JSON. The PHP validator must still reject malformed JSON, non-object roots, unknown fields, NUL/control characters, wrong types, wrong schema version, wrong operation, and every verb-specific bound. A custom duplicate-key tokenizer is not required for this local privileged boundary unless a later threat model adds untrusted direct callers.

`fields` emits one fixed tab-separated row of base64 values in a verb-specific order. It never emits dynamic key names.

**Command:** `php tests/api-request.php`.

**Done:** unknown fields, NUL, wrong types, and wrong operation fail.

## C05. Consume normalized fields without eval

**Files:** `runner-api.sh`; test.

**Change:** call `/usr/bin/php api-request.php fields <verb> <request-file>`, read the fixed row with a tab-delimited `read`, decode, then validate again with shell patterns.

Do not source output, use `eval`, or create variable names from input.

**Test:** shell metacharacters remain inert data.

**Done:** request parsing has no command-injection path.

## C06. Add response-envelope emission

**Files:** `runner-api.sh`.

**Change:** implement an envelope helper that accepts a bounded result file or stdin stream, not a potentially 1 MiB JSON value in argv. Validate the result through PHP, compute observed revisions with existing functions, and emit exactly one line.

**Test:** valid success/failure; malformed result becomes `backend_unavailable`; stderr never corrupts stdout.

**Done:** every strict verb can share one envelope.

## C07. Add stable error helpers

**Files:** `runner-api.sh`.

**Change:** add helpers for invalid request/revision, stale config/inventory/transition, ownership change, compatibility change, backend unavailable, and oversized output.

Each emits the strict envelope and returns the documented exit code.

**Test:** assert exact stable code and exit for every helper.

**Done:** callers never parse human text.

## S01. Add the strict legacy-status wrapper

Call `cmd_status_json` once, enforce the 1 MiB cap, parse schema version 2, and reject inventory-unavailable output as a backend failure rather than a healthy empty fleet.

**Test:** maximum valid fixture, malformed/oversized JSON, unsupported schema, inventory failure.

## RS01. Add explicit resource availability augmentation

When `resource_snapshot_refresh` fails, add `resources.available=false`, a stable reason such as `resource_state_unavailable`, and zero quantities. On success add `available=true` and null reason. Never expose fail-closed zeros as confirmed capacity.

**Test:** success, cgroup unavailable, malformed host override, unsafe inventory, and no stale quantity reuse.

## S02. Add exact runner resource-limit augmentation

Join the single existing Docker inventory to each runner row and add nullable exact `cpu_milli` and `memory_bytes` without additional per-field Docker calls. Preserve legacy coarse fields for UI parity.

**Test:** fractional CPU, non-GiB memory, uncapped limits, retiring/invalid identity.

## S03. Normalize unsafe identifiers and invalid state

Convert queue/work/remote IDs that may exceed JavaScript's safe range to strings in strict JSON. Preserve `invalid` backend, mode, and auth state instead of coercing a valid enum.

**Test:** >2^53 identifiers and each invalid state.

## S04. Add strict readiness

Wrap `cmd_readiness_json`, validate backend/compatibility/operation shapes, preserve nullable cached `count`, and source the operation summary from the generic durable journal. Do not refresh Docker for readiness.

**Test:** classic, scale-set ready, valid mode-0600 inventory count, missing/symlink/0644 inventory null count, invalid compatibility, interrupted operation.

## S05. Add strict queue read

Wrap `cmd_queued_json`, preserve background refresh semantics and partial/truncated flags, and serialize run/job IDs as strings.

**Test:** unavailable, partial, 40-row cap, unsafe-size IDs.

## S06. Add statistics and cache reads

Wrap `cmd_stats_json` and `cmd_cache_usage_json` separately with their existing sentinel and background-refresh semantics.

**Test:** known zero versus unavailable, stale age, large byte totals.

## S07. Add exact image read

Wrap `cmd_image_info_json` and augment it with full image ID and exact byte size while retaining source, base image, Dockerfile, and in-use count.

**Test:** missing image, built-in image, remote image, exact byte value.

**Done:** every read has one bounded authoritative controller call and one focused fixture.
