# Ten-minute tasks: GraphQL configuration, controls, operations, and subscriptions

Continue after `implementation-plan-graphql.md` and the shared PHP gate.

## M01. Add typed configuration raw schema

**Files:** create `src/contracts/configuration.schema.ts`; tests.

**Change:** define strict Zod schemas for the configuration snapshot and validation response. Enforce the existing eight-pool and 16 KiB serialized pool limits, per-item grammars, and controller numeric semantics. Do not invent repository or additional-label count caps. Preserve invalid snapshots, canonical effective allowlisted values, all sentinel modes, credential-presence booleans, and the opaque credential revision.

**Test:** full valid configuration, manually invalid current config, every sentinel round-trip, unknown/secret-like output field, eight-pool maximum, ninth-pool rejection.

**Done:** configuration query output is independently validated.

## M02. Implement configuration query

**Files:** `configuration.resolver.ts`, create `configuration.service.ts`; tests.

**Change:** invoke the strict configuration-read CLI/controller operation, validate, and map to code-first output. Decorate `READ_ANY/CONFIG`.

**Test:** valid typed output, invalid snapshot with issues/effective settings, opaque credential revision plus three presence booleans, no secret values or fingerprints, backend unavailable.

**Done:** clients can fetch an exact base revision before patching.

## M03. Implement configuration validation mutation

**Files:** `configuration.resolver.ts`, `configuration.service.ts`; tests.

**Change:** add `runnerFarmValidateConfiguration`, require expected config revision because the partial patch merges with current values, decorate `UPDATE_ANY/CONFIG`, serialize to the config CLI, and normalize typed issues.

**Test:** valid patch, invalid cross-field patch, unknown field blocked by GraphQL, no side effects.

**Done:** direct clients and MCP can dry-run changes.

## M04. Implement configuration apply mutation

**Files:** same resolver/service; tests.

**Change:** add `runnerFarmApplyConfiguration` with expected config revision and typed patch. Pass through the controller's stable action result and observed revisions.

**Test:** success, stale config, invalid config, commit failure, no retry in service.

**Done:** apply preserves optimistic concurrency.

## M05. Add secret process method

**Files:** `process-runner.service.ts`, create `secret.service.ts`; tests.

**Change:** add a dedicated method that accepts one fixed secret command and serializes expected config revision, expected opaque credential revision, and the field-specific value into bounded stdin JSON. It MUST disable variable logging, use PAT 255/App-key 32768/registry 4096 limits, cap output, and clear local references after completion.

**Test:** marker absent from invocation metadata, logs, errors, stdout, and stderr capture.

**Done:** generic controller client never accepts secret payloads.

## M06. Implement GitHub PAT mutations

**Files:** `configuration.resolver.ts`, `secret.service.ts`; tests.

**Change:** add set/clear PAT fields with `UPDATE_ANY/CONFIG`. Both require expected config and credential revisions and pass only bounded stdin JSON to `secret-cli.php`; clear omits a value but not the revision.

**Test:** validated login metadata, rejected PAT, write failure, old credential preserved, no marker leakage.

**Done:** GraphQL has parity with WebGUI PAT behavior.

## M07. Implement GitHub App key mutations

**Files:** same; tests.

**Change:** add config-plus-credential-revision-guarded set/clear private-key fields. Never include key content in a model or error. Preserve session-cache invalidation response only as a generic success.

**Test:** valid PEM, invalid PEM, oversized value, stale credential, storage failure, no leakage.

**Done:** key material never crosses the service return boundary.

## M08. Implement registry-token mutations

**Files:** same; tests.

**Change:** add config-plus-credential-revision-guarded set/clear token fields with the same secret runner and the current 4096-byte registry-token limit.

**Test:** maximum bound, NUL, stale credential, write failure, clear, no leakage.

**Done:** all credential operations share one path.

## M09. Implement Dockerfile save mutation

**Files:** `configuration.resolver.ts`; tests.

**Change:** add `runnerFarmSaveDockerfile`, require the SHA-256 of the content previously read, decorate `UPDATE_ANY/CONFIG`, call config CLI, and return the new SHA-256. Map concurrent edits to `stale_dockerfile`.

**Test:** valid content, empty, oversized, atomic failure, exact hash.

**Done:** build requests can bind to immutable content identity.

## W01. Add config-only and fleet revision mappers

Serialize exact snake_case config-only and config-plus-required-inventory expectations; reject empty/uppercase/malformed hashes before the controller call.

## W02. Add credential revision mapper

Serialize config plus opaque credential revision for every set/clear action. Test exact fields and stale-credential result mapping.

## W03. Add transition and Dockerfile revision mappers

Serialize the four transition authorities and the expected/current Dockerfile SHA independently. Test that no authority is omitted or renamed incorrectly.

## W04. Implement start mutation

Add `runnerFarmStart` with fleet revisions, `UPDATE_ANY/DOCKER`, fixed operation selection, and focused success/stale/transition tests.

## W05. Implement stop mutation

Add `runnerFarmStop` with fleet revisions and forced-teardown result mapping.

## W06. Implement restart mutation

Add `runnerFarmRestart` with fleet revisions and exact partial-failure mapping.

**Done:** each lifecycle resolver contains no controller logic and has its own test suite.

## W07. Implement scale mutation

Add `runnerFarmScale` with optional pool, target 0-64, required fleet revisions, and exact single/pool/autoscale/resource-domain results.

## W08. Implement prewarm mutation

Add `runnerFarmPrewarm` with required pool, target 0-64, config revision, and backend/config conflict mapping.

## W09. Implement recycle mutation

Add `runnerFarmRecycle` with validated runner name and fleet revisions; test invalid name before process call plus busy/retiring/replacement failures.

## W10. Implement maintenance mutation

Add BEGIN/RESUME with config revision and exact resulting maintenance state.

## W11. Implement queued-run cancellation mutation

Add repository/run-ID input, `UPDATE_ANY/DOCKER`, and focused malformed/stale-queue/GitHub-result tests.

## W12. Implement package-cache clear mutation

Add config revision, `DELETE_ANY/DOCKER`, and focused unsafe-root/partial/success tests.

## W13. Implement begin-migration mutation

Add all four authorities, `UPDATE_ANY/CONFIG`, exact request mapping, and one focused failure per authority/phase.

## W14. Implement rollback mutation

Add the same persisted authority input, reverse-state result mapping, and no simple backend enum path.

## M16. Implement operation service

**Files:** create `src/services/operation.service.ts`; tests.

**Change:** methods start and read the durable generic operation journal. Compatibility and provisioning starts require expected config revision; image build requires saved Dockerfile SHA. Normalize running, interrupted, and terminal states.

**Test:** running, terminal success, terminal failure, unknown ID, bounded output.

**Done:** long-operation semantics are shared by resolvers and subscriptions.

## W15. Implement image-build start mutation

Require saved Dockerfile SHA, use `UPDATE_ANY/DOCKER`, and test invalid/stale hash, already running, and durable operation ID.

## W16. Implement provisioning-validation start mutation

Require config revision, use `UPDATE_ANY/DOCKER`, and test stale config, launch failure, and durable operation ID.

## W17. Implement compatibility-test start mutation

Require config revision, use `UPDATE_ANY/CONFIG`, and test stale config, duplicate-running policy, probe start failure, and durable operation ID.

## M18. Add shared subscription producer

**Files:** create `src/services/subscription.service.ts`; tests.

**Change:** inject `GRAPHQL_PUBSUB_TOKEN`. Maintain one status polling timer while subscriber count is nonzero. Poll every five seconds, hash the authority tuple, and publish only changes.

Stop timer when the final subscriber leaves. Use `unref` when available.

**Test:** one timer for two subscribers, change-only publish, final unsubscribe stops timer, errors do not kill future polls.

**Done:** subscriptions do not create per-client process storms.

## M19. Implement status subscription resolver

**Files:** create `subscriptions.resolver.ts`; update module; tests.

**Change:** add `runnerFarmStatusUpdates` with `READ_ANY/DOCKER`. Register/unregister with the shared producer and return PubSub iterator.

**Test:** permission metadata, initial/change behavior, cleanup on iterator return.

**Done:** authenticated WebSocket clients receive bounded typed status.

## M20. Implement operation subscription

**Files:** `subscriptions.resolver.ts`, `subscription.service.ts`; tests.

**Change:** exact operation ID subscription polls the durable journal at most once per second or listens to shared operation publications. Emit only changed state/output and complete after terminal state.

**Test:** unknown ID rejected, running to success, running to failure, terminal emitted once, timer cleanup.

**Done:** operation watchers cannot leak indefinitely.

## M21. Add resolver permission audit test

**Files:** create `test/permissions.spec.ts`.

**Change:** enumerate every `runnerFarm*` schema field, extract the `@usePermissions` directive, and compare with `RUNNER_FARM_PERMISSIONS` from the reference contract.

**Test:** missing directive or wrong resource/action fails.

**Done:** every public field is authorization-documented.

## M22. Add secret-surface audit test

**Files:** create `test/secret-surface.spec.ts`.

**Change:** inspect generated schema and serialized model fixtures. Fail if output types contain token, privateKey, secret, authorization, credential value, or PEM content fields. Permit credential-presence booleans.

Capture logger, PubSub, controller response, and thrown errors during a marker secret test.

**Done:** no public or diagnostic surface retains the marker.

## W18. Build the integration test application

Create the Nest GraphQL test app with mock authentication subject, permission engine, PubSub, and process/controller services. Prove schema boot and cleanup.

## W19. Add read-only permission integration cases

Prove a read role can query permitted status/config/log fields and is denied every mutation.

## W20. Add admin and malformed-input integration cases

Prove admin validation/control calls reach exact services, while malformed GraphQL inputs never invoke the process runner.

## M24. Run the complete GraphQL gate

**Commands:**

```bash
pnpm --dir packages/unraid-api-plugin-ci-runner-farm test
pnpm --dir packages/unraid-api-plugin-ci-runner-farm build
npm pack --dry-run --prefix packages/unraid-api-plugin-ci-runner-farm
git diff --check
```

**Done:** Gate E is satisfied and generated schema matches `schema.graphql`.
