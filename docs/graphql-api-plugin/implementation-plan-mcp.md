# Ten-minute tasks: static Unraid MCP actions for Runner Farm

Start only after a live Unraid API instance exposes the stable read schema.

Repository:

`/home/jmagar/workspace/unraid-mcp`

## R01. Create the MCP feature worktree

**Steps:**

```bash
git -C /home/jmagar/workspace/unraid-mcp fetch origin --prune
git -C /home/jmagar/workspace/unraid-mcp worktree add   -b feat/runner-farm-graphql-actions   /home/jmagar/workspace/unraid-mcp/.worktrees/runner-farm-graphql-actions   origin/main
cd /home/jmagar/workspace/unraid-mcp/.worktrees/runner-farm-graphql-actions
git status --short --branch
```

**Done:** clean worktree identity is recorded.

## R02. Refresh the vendored GraphQL SDL

**Files:** `unraid-rs/schema/unraid-schema.graphql`.

**Change:** obtain the schema from the approved Unraid host with Runner Farm API package loaded. Replace the vendored SDL through the repository's schema-update workflow. Confirm existing core fields are unchanged except expected upstream drift.

**Test:**

`cargo test --manifest-path unraid-rs/Cargo.toml --test schema_contract`.

**Done:** SDL contains every target `runnerFarm*` field.

## R03. Add Runner Farm scalar aliases and enums

**Files:** `unraid-rs/src/gql_typed.rs`.

**Change:** add Cynic enums matching valid selection enums and read-state enums with INVALID, plus GitHub scope, workspace mode, pool-autoscale mode, memory swap, image source, network isolation, operation kind/state, conclusion, and maintenance mode.

Map GraphQL BigInt and any unsafe numeric identifier to string-backed newtypes that serialize without truncation.

**Test:** compile and serde round-trip a value above 2^53.

**Done:** large bytes and IDs are lossless.

## X01. Add reason and observed-revision fragments

Define reason, complete observed revisions, and nullable credential revision. Compile against the vendored SDL and serialize one fixture.

## X02. Add backend and compatibility fragments

Define invalid-capable requested/effective backend, transition authorities, and nullable compatibility evidence.

## X03. Add durable-operation fragment

Define exact UUID, kind/state/code, timestamps, sanitized output, and interrupted state.

## X04. Add resource, reservation, and recent-activity fragments

Use string-backed BigInt/ID scalars, preserve resource availability/reason, enforce the bounded seven-phase reservation projection and deadlines, preserve conclusions, and test maximum values.

## X05. Add credential-presence fragment

Include opaque credential revision and three booleans without exposing values or fingerprints.

## X06. Add pool fragment

Include every capacity, freshness, ownership, session, tombstone, orphan, and exact resource field. Test fixed/automatic/scale-set variants.

## X07. Add runner fragment

Include job context, nullable exact limits/use, stale/retiring/completed, and string unsafe IDs. Test the maximum runner fixture.

## X08. Add status query and client/service method

Define `RunnerFarmStatusQuery`, one client method, one service forwarding method, and maximum-fixture JSON projection tests.

## X09. Add readiness query and client/service method

Define the readiness query separately with backend/compatibility/operation projection, nullable cached count, and missing/unsafe inventory tests.

## R07. Add status/readiness action specs

**Files:** `src/mcp/schemas.rs`, `src/mcp/tools.rs`, dispatch tests.

**Change:** add `runner_farm_status` and `runner_farm_readiness` with read scope and no arguments. Add exact dispatch arms.

**Test:** actions appear once, read token succeeds, unauthenticated and wrong host behavior follow existing conventions.

**Done:** Labby can discover two actions after deployment.

## X10. Add configuration snapshot fragments and method

Include validity/issues, nullable typed config, canonical effective settings, opaque credential revision, and presence booleans.

## X11. Add queue fragments and method

Preserve partial/truncated/detail-complete and string IDs; apply caller limit no higher than the controller's 40 rows.

## X12. Add statistics and cache methods

Add separate typed queries/methods preserving unavailable versus zero and BigInt bytes.

## X13. Add image method

Include full image ID, exact bytes, source/base/Dockerfile/in-use fields.

## X14. Add operation method

Add exact UUID variables and durable operation projection.

## X15. Add runner/history/controller log methods

Use separate typed queries and enforce requested lines plus 64 KiB service projection bounds.

## X16. Add configuration and queue action specs/dispatch

Add read-scoped actions plus queue limit validation.

## X17. Add statistics, cache, and image action specs/dispatch

Add argument-free read actions and exact service dispatch.

## X18. Add operation action spec/dispatch

Require canonical UUID and fail before GraphQL on invalid input.

## X19. Add runner/history/controller log action specs/dispatch

Validate runner name and lines independently, then dispatch exact methods.

**Done:** every read action has one scope/schema/dispatch test.

## R10. Add revision input helpers

**Files:** `tools.rs` or a new `mcp/runner_farm_args.rs`; tests.

**Change:** parse exact lowercase SHA-256 values into separate config-only, fleet, Dockerfile, and four-authority transition structs. Fleet structs require inventory revision; do not silently omit any required authority.

**Test:** missing, uppercase, short, non-hex, valid.

**Done:** all controls share one validator.

## Y01. Add start mutation/client/service method

Use fleet revision variables and typed action result.

## Y02. Add stop mutation/client/service method

Use fleet revisions and forced-teardown result.

## Y03. Add restart mutation/client/service method

Use fleet revisions and partial-failure result.

## Y04. Add scale mutation/client/service method

Use optional pool, target, and fleet revisions.

## Y05. Add prewarm mutation/client/service method

Use pool, target, and config revision.

## Y06. Add recycle mutation/client/service method

Use runner and fleet revisions.

## Y07. Add maintenance mutation/client/service method

Use mode and config revision.

## Y08. Add queue-cancel mutation/client/service method

Use repository and run ID.

## Y09. Add cache-clear mutation/client/service method

Use config revision and typed deletion result.

Each method uses Cynic variables, never formatted GraphQL strings.

## Y10. Add lifecycle action specs and dispatch

Add start/stop/restart write scopes and required fleet revisions.

## Y11. Add capacity action specs and dispatch

Add scale/prewarm target and pool validation with their distinct revision requirements.

## Y12. Add recycle/maintenance action specs and dispatch

Validate runner/mode and exact revisions.

## Y13. Add queue-cancel/cache-clear specs and dispatch

Validate repository/run ID versus config revision and deletion scope.

**Test:** read scope rejects every write action and missing authorities fail before service calls.

## Y14. Add configuration-validation action

Add typed patch model, expected config revision, bounded shape validation, client/service method, action schema, dispatch, and dry-run result tests.

## Y15. Add configuration-apply action

Reuse the patch type, require revision, and test success/stale/invalid/commit-failure propagation independently.

## Y16. Add image-build start action

Require saved Dockerfile SHA and return a durable operation ID.

## Y17. Add provisioning-validation start action

Require config revision and return a durable operation ID.

## Y18. Add compatibility-test start action

Require config revision and return a durable operation ID.

## Y19. Add begin-migration action

Require all four authorities and no simple backend enum.

## Y20. Add rollback action

Require the persisted four-authority set and reverse result mapping.

## R15. Exclude secret and Dockerfile-content actions

**Files:** `tests/schema_contract.rs`, `tests/dispatch.rs` or a new audit test.

**Change:** assert the action list does not contain PAT, private key, registry token, or raw Dockerfile save actions.

**Test:** exact forbidden-name set.

**Done:** default MCP cannot ingest credential content.

## R16. Update help and CLI dispatch

**Files:** `src/mcp/schemas.rs` help text, `src/cli/dispatch.rs`, `tests/cli_help.rs`.

**Change:** add a Runner Farm section explaining scopes, fetch-before-mutate revisions, no blind retry on stale state, four-authority migration, and intentional secret omission.

**Test:** help snapshot and CLI action dispatch.

**Done:** operators understand the concurrency model.

## MX01. Add healthy classic scenario

Cover status, readiness, configuration, queue, image, and logs for a classic fleet.

## MX02. Add healthy scale-set scenario

Cover pool capacity/freshness/ownership, exact resources, reservations, and JIT activity.

## MX03. Add conflict and unavailable scenarios

Cover stale config/inventory, transition in progress, permission error, and backend unavailable.

## MX04. Add non-lossy and invalid-config scenarios

Cover large bytes, exact millicores, unsafe-size ID strings, invalid configuration with issues/effective settings, and sentinel preservation.

## MX05. Add durable-operation and bounded-log scenarios

Cover running/interrupted/terminal operations plus current/history/controller log caps.

## R18. Run Rust and live Labby gates

**Commands:**

```bash
cargo fmt --check --manifest-path unraid-rs/Cargo.toml
cargo clippy --all-targets --all-features --manifest-path unraid-rs/Cargo.toml -- -D warnings
cargo test --all-targets --all-features --manifest-path unraid-rs/Cargo.toml
git diff --check
```

Deploy the MCP server, reconnect it through Labby, verify discovered action count, then invoke:

1. status;
2. readiness;
3. configuration fetch, then validation with its exact revision and a harmless patch;
4. one stale-revision mutation that must fail without side effects.

**Done:** Gate G is satisfied with concrete Labby evidence.
