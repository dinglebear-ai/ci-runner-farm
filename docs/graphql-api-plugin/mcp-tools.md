# MCP tools built on the Runner Farm GraphQL schema

## Decision

Runner Farm GraphQL fields do not automatically become MCP tools. The current Rust `unraid-mcp` server uses a static action enum, static dispatch, explicit service methods, and Cynic query fragments.

V1 adds explicit Runner Farm actions to the existing `unRAID::unraid` tool. This preserves reviewable input schemas and API-key scope mapping.

Secret-setting GraphQL mutations are intentionally omitted from the default MCP surface. Tool calls, chat traces, gateway logs, and debugging envelopes may retain arguments. Credential changes remain available in the WebGUI and to direct trusted GraphQL clients.

## Source files to modify

Repository:

`/home/jmagar/workspace/unraid-mcp/unraid-rs`

Files:

- `src/mcp/schemas.rs`
- `src/mcp/tools.rs`
- `src/graphql.rs`
- `src/gql_typed.rs`
- `src/app.rs`
- `src/cli/dispatch.rs`
- action/help tests and healthy/error fixtures

The GraphQL schema snapshot used by Cynic must include the installed Runner Farm extension fields.

## Read actions

| MCP action | GraphQL field | Scope | Required arguments |
|---|---|---|---|
| `runner_farm_status` | `runnerFarmStatus` | `unraid:read` | none |
| `runner_farm_readiness` | `runnerFarmReadiness` | `unraid:read` | none; count may be null when the private inventory cache is unavailable or unsafe |
| `runner_farm_configuration` | `runnerFarmConfiguration` | `unraid:read` | none; returns validity/issues plus nullable typed config |
| `runner_farm_queue` | `runnerFarmQueue` | `unraid:read` | optional limit in MCP projection |
| `runner_farm_statistics` | `runnerFarmRunStatistics` | `unraid:read` | none |
| `runner_farm_cache_usage` | `runnerFarmCacheUsage` | `unraid:read` | none |
| `runner_farm_image` | `runnerFarmImage` | `unraid:read` | none |
| `runner_farm_operation` | `runnerFarmOperation` | `unraid:read` | `operation_id` |
| `runner_farm_runner_log` | `runnerFarmRunnerLog` | `unraid:read` | `runner_name`, optional `lines` |
| `runner_farm_history_log` | `runnerFarmHistoryLog` | `unraid:read` | `runner_name`, optional `lines` |
| `runner_farm_controller_log` | `runnerFarmControllerLog` | `unraid:read` | optional `lines` |

The MCP projection SHOULD default to:

- at most 64 runners;
- at most 8 pools;
- at most the controller's current 40 queued-job detail rows, or a lower caller limit;
- at most 150 log lines;
- at most 64 KiB log content.

## Control actions

| MCP action | GraphQL mutation | Scope | Required arguments |
|---|---|---|---|
| `runner_farm_start` | `runnerFarmStart` | `unraid:admin` | `config_revision` and `inventory_revision` |
| `runner_farm_stop` | `runnerFarmStop` | `unraid:admin` | config and inventory revisions |
| `runner_farm_restart` | `runnerFarmRestart` | `unraid:admin` | config and inventory revisions |
| `runner_farm_scale` | `runnerFarmScale` | `unraid:admin` | target, config and inventory revisions, optional pool ID |
| `runner_farm_prewarm` | `runnerFarmPrewarm` | `unraid:admin` | pool ID, target, config revision |
| `runner_farm_recycle` | `runnerFarmRecycle` | `unraid:admin` | runner name, config and inventory revisions |
| `runner_farm_maintenance` | `runnerFarmSetMaintenance` | `unraid:admin` | BEGIN or RESUME, config revision |
| `runner_farm_cancel_queued_run` | `runnerFarmCancelQueuedRun` | `unraid:admin` | repository and run ID |
| `runner_farm_clear_package_caches` | `runnerFarmClearPackageCaches` | `unraid:admin` | config revision |

## Configuration and operation actions

| MCP action | GraphQL mutation | Scope | Notes |
|---|---|---|---|
| `runner_farm_validate_configuration` | `runnerFarmValidateConfiguration` | `unraid:admin` | Expected config revision plus patch; safe dry run |
| `runner_farm_apply_configuration` | `runnerFarmApplyConfiguration` | `unraid:admin` | Typed patch plus expected revision |
| `runner_farm_start_image_build` | `runnerFarmStartImageBuild` | `unraid:admin` | Requires previously saved Dockerfile hash |
| `runner_farm_start_provisioning_validation` | `runnerFarmStartProvisioningValidation` | `unraid:admin` | Expected config revision; returns durable operation |
| `runner_farm_start_compatibility_test` | `runnerFarmStartCompatibilityTest` | `unraid:admin` | Expected config revision; returns durable operation |
| `runner_farm_begin_backend_migration` | `runnerFarmBeginBackendMigration` | `unraid:admin` | Requires four exact revisions |
| `runner_farm_rollback_backend` | `runnerFarmRollbackBackend` | `unraid:admin` | Requires four exact revisions |

Dockerfile content write is omitted from the initial MCP surface. A later action may accept a local file attachment or explicit content with stronger trace controls. The image-build action only accepts the hash of a Dockerfile already saved through the WebGUI or direct GraphQL.

## Static action schema additions

`src/mcp/schemas.rs` adds each action to `ACTION_SPECS` with read or write scope.

The top-level input schema adds optional fields:

```rust
"config_revision": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
"inventory_revision": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
"transition_revision": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
"ownership_revision": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
"compatibility_record_id": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
"operation_id": { "type": "string", "format": "uuid" },
"runner_name": { "type": "string" },
"pool_id": { "type": "string" },
"target": { "type": "integer", "minimum": 0, "maximum": 64 },
"maintenance_mode": { "enum": ["BEGIN", "RESUME"] },
"configuration_patch": { "type": "object" }
```

Action-specific validation remains in `tools.rs`; the shared tool schema cannot express conditional requirements completely.

## Cynic types

`gql_typed.rs` adds fragments for the public models. BigInt quantities and potentially unsafe numeric identifiers deserialize into string-backed newtypes so Rust and JSON projections cannot truncate them.

Workflow run IDs and job IDs remain strings.

The generated Rust response should preserve:

- backend requested and effective values;
- nullable readiness fleet count;
- resource availability/reason plus exact quantities;
- every revision;
- pool capacity distinctions;
- session and demand freshness;
- runner job context and nullable exact millicore/byte metrics;
- configuration validity/issues and sentinel-preserving fields;
- durable operation state and code.

## GraphQL client methods

`graphql.rs` adds one method per action. Example:

```rust
pub async fn runner_farm_status(&self) -> Result<Value> {
    use cynic::QueryBuilder;
    self.run_typed(crate::gql_typed::RunnerFarmStatusQuery::build(()))
        .await
}
```

Mutations build typed variable structs and never construct GraphQL strings from user input.

## Dispatch

`mcp/tools.rs` adds exact match arms. Example:

```rust
"runner_farm_status" => svc!(state.service.runner_farm_status()),
"runner_farm_scale" => {
    let target = required_u64(args, "target", 0, 64)?;
    let pool_id = string_arg(args, "pool_id");
    let expected = runner_farm_fleet_revision_args(args)?;
    svc!(state.service.runner_farm_scale(pool_id.as_deref(), target, expected))
}
```

The dispatch MUST reject missing revision arguments before calling GraphQL.

## Help text

`action=help` groups Runner Farm actions separately and explains:

- read actions require `unraid:read`;
- mutations require `unraid:admin`;
- fetch status before fleet mutations and configuration before config-dependent mutations to obtain required revisions;
- `stale_config` or `stale_inventory` means refetch and reconsider, not blind retry;
- migration needs all four revisions;
- credentials are intentionally not managed by MCP.

## Testing

Add Rust tests for:

1. Every action appears once with the correct scope.
2. Read-only scope rejects every write action.
3. Missing revisions fail before a service call.
4. Invalid pool ID, runner name, target, UUID, and SHA-256 values fail validation.
5. Status fixture preserves large byte values, exact millicores, and identifier strings without truncation.
6. Queue and log projections honor limits.
7. Domain failure responses are returned as structured data rather than transport panics.
8. GraphQL authentication and permission errors map to existing MCP error conventions.
9. Secret-setting actions are absent.
10. Help output documents refetch-on-conflict behavior.

## Rollout

MCP work starts after a deployed GraphQL read query is stable. Recommended order:

1. status and readiness;
2. queue, stats, cache, image, operation, and logs;
3. lifecycle and scale controls;
4. configuration validation and apply;
5. durable long operations and migration;
6. live Labby smoke tests.
