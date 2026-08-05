# Ten-minute tasks: NestJS package and read-only GraphQL surface

Continue after strict controller reads pass. Exact host versions reviewed at Unraid API 4.36.1 are used below.

## G01. Refresh generator and host compatibility evidence

Before writing the manifest, read the current official plugin generator, API package, `@unraid/shared`, and resolved framework versions. Record the tested matrix in a fixture. The reviewed generator emitted `unraidVersion.min=^6.12.15` and `max=~7.1.0`; use current generated values and verify them against target hosts rather than copying them blindly.

## G02. Create the package manifest

**Files:** create `packages/unraid-api-plugin-ci-runner-farm/package.json`.

The manifest includes ESM `main/types/exports`, compiled-only files, Apache-2.0 license, current `unraidVersion` metadata, and build/test/pack scripts.

Framework singletons are compatible peer ranges that include the reviewed API 4.36.1 versions: NestJS, GraphQL, RxJS, class-transformer, class-validator, `graphql-scalars`, and `@unraid/shared`. Execa and Zod are normal package dependencies because the plugin owns their instances. Exact reviewed framework/tool versions are devDependencies for reproducible tests. Do not add an incompatible `reflect-metadata` peer merely because the reviewed generator and API root currently disagree; verify whether the package imports it before declaring a requirement.

**Test:** validate peer ranges against the recorded host fixture, build metadata, license, and `npm pack --dry-run`.

**Done:** package identity, compatibility metadata, and dependency ownership are explicit.

## G03. Add TypeScript and Vitest configuration

**Files:** `tsconfig.json`, `tsconfig.build.json`, `vitest.config.ts` inside the package.

**Change:** use NodeNext, ES2022, strict mode, decorators, metadata, declaration/source maps, rootDir `src`, outDir `dist`, and skipLibCheck.

**Test:** an empty `src/index.ts` compiles.

**Done:** build emits ESM declarations and JavaScript.

## G04. Add package entry and module shell

**Files:** `src/index.ts`, `src/runner-farm.module.ts`.

**Code:**

```ts
import { Module } from '@nestjs/common';

export const adapter = 'nestjs';

@Module({})
export class RunnerFarmPluginModule {}

export const ApiModule = RunnerFarmPluginModule;
```

Place exports in `index.ts`; keep the class in its module file.

**Test:** build and dynamic-import `dist/index.js`; assert adapter and class exports.

**Done:** package satisfies the upstream plugin schema.

## T01. Add state and selection enums

Create and register the valid-input enums separately from read-state enums that include `INVALID`. Add GitHub scope, workspace mode, pool-autoscale mode, and memory-swap mode.

**Test:** generated enum names and INVALID mapping.

## T02. Add reason, revision, backend, and compatibility models

Implement public-name-bound object types for reasons, observed revision sets, invalid-capable backend state, and compatibility evidence. Test missing optional evidence and every revision field.

## T03. Add durable operation and credential-presence models

Implement operation kind/state/timestamps/output plus credential presence and opaque credential revision. Test running, interrupted, terminal, and credential revision serialization.

## T04. Add resource, reservation, and recent-activity models

Implement exact BigInt resource quantities, reservation deadlines/phases, and recent activity with string work handles and conclusion enums.

## T05. Add pool output model

Implement every configured/effective/desired/admitted/advertised, freshness, session, ownership, tombstone, and orphan field with exact nullability.

## T06. Add runner output model

Implement identity/job context, nullable exact CPU millicores and memory bytes, nullable live usage, completed/stale/retiring fields, and string unsafe IDs.

## T07. Add queue, statistics, cache, image, Dockerfile, and log models

Implement each auxiliary output group separately in one file, explicitly bind public SDL names, and test full image identity/exact bytes plus bounded log metadata.

## T08. Add configuration output and snapshot models

Implement sentinel-preserving GitHub, runner/pool, resource, storage, image, Docker, autoscale, image-update, raw effective settings, validity/issues, nullable typed config, and credential-presence fields.

## T09. Add revision and control input models

Implement config-only, fleet, credential, transition, scale, prewarm, recycle, maintenance, queue-cancel, log, operation, and operation-start inputs with exact validators.

## T10. Add configuration, secret, and Dockerfile input models

Implement configuration patch groups, expected-revision validation/apply, specific secret inputs with config plus credential revisions, and Dockerfile expected/current SHA inputs.

**Done:** each model group has one focused schema-shape test, and every output class explicitly binds its public SDL name.

## G06. Add raw Zod schemas for envelopes

**Files:** create `src/contracts/envelope.schema.ts` and tests.

**Change:** define strict Zod schemas for:

- controller response envelope schema version 1;
- observed revision set;
- stable domain code string;
- read result wrapper.

Use `.strict()` for the envelope. Cap message and code lengths.

**Test:** valid success/failure, unknown field, wrong version, malformed revisions, oversized message.

**Done:** no resolver consumes unvalidated process JSON.

## Z01. Add legacy status envelope and global authority schema

Validate schema version, config/inventory revisions, backend, compatibility, maintenance, mode, counts, warnings, and array presence. Reject unsupported required versions.

## Z02. Add resource, reservation, and recent-activity schemas

Validate resource availability/reason plus exact quantities; reservation CPU 1-256000, memory 1-1099511627776, positive deadline, current seven-phase set, array bounds, timestamps, and recent-activity file limits.

## Z03. Add pool schema

Validate at most eight pools, every capacity/freshness/ownership field, `max=auto`, and nullable unknown scale-set data.

## Z04. Add runner schema

Validate at most 64 runners, legacy coarse metrics, strict exact augmentations, job context, nullable unknown use, and string unsafe identifiers.

## Z05. Add readiness and invalid-state schemas

Validate invalid-capable backend/auth/mode values, compatibility details, durable operation summary, and nullable cached fleet count.

## Z06. Add queue, statistics, cache, and image schemas

Validate the 40-row queue cap, partial/truncated flags, unsafe-size ID strings, statistics/cache sentinels, full image ID, and exact image bytes.

## Z07. Add Dockerfile and log schemas

Validate effective/default Dockerfile content and SHA, plus bounded log source/content/truncation results.

## Z08. Add durable operation record/result schemas

Validate journal metadata, fixed output source, sanitized summary, timestamps, config revision, interrupted state, and bounded output arrays.

## G08. Implement the bounded process runner

**Files:** create `src/services/process-runner.service.ts` and test.

**Change:** inject a small process factory for tests. Invoke fixed executable and args with:

- `shell: false`;
- `reject: false`;
- timeout from command spec;
- bounded stdout/stderr collection;
- process-tree termination on timeout;
- no inherited stdio.

Return exit code, stdout, stderr, timeout flag, and duration.

**Test:** exact argv, stdin, timeout child, oversized stdout, oversized stderr, nonzero exit.

**Done:** process behavior satisfies `reference/contracts.ts`.

## G09. Implement ControllerClientService

**Files:** create `src/services/controller-client.service.ts` and tests.

**Change:** map named operations to fixed command specs, generate lowercase UUID request IDs, serialize strict requests, invoke process runner, parse one JSON envelope, validate with Zod, and map transport failures to typed service errors.

It must accept no arbitrary executable, verb, or raw argv from resolvers.

**Test:** read without stdin, mutation with exact envelope, malformed stdout, two JSON objects, timeout, nonzero valid envelope.

**Done:** resolvers have one safe controller client.

## G10. Add normalization primitives

**Files:** create `src/services/normalization.ts` and tests.

**Change:** pure functions for:

- epoch/RFC3339 to Date;
- empty string to null;
- bounded decimal string or safe integer to bigint, rejecting unsafe JSON numbers;
- legacy GiB/MiB fallbacks plus exact strict byte/millicore fields;
- label string to array;
- valid selection enums versus read-state enums with INVALID;
- reason string to code/message;
- unknown conclusion to UNKNOWN.

**Test:** boundaries, invalid dates, negative sentinels, large byte values.

**Done:** no resolver repeats conversions.

## N01. Normalize backend, mode, auth, and revision state

Map valid and INVALID read states without coercion; preserve requested/effective backend and all observed revisions, including optional credential revision.

## N02. Normalize compatibility evidence

Map reason, record identity, RFC3339 timestamps, digest/version/group fields, and nullable missing evidence independently.

## N03. Normalize durable operations

Map exact UUID, kind/state/code, non-null createdAt, updated/finished times, sanitized summary/output, and interrupted terminal state.

## N04. Normalize resource quantities

Map explicit availability/reason, convert safe numeric/string values to BigInt, reject unsafe JSON numbers, preserve budget/reserve/reserved/admissible distinctions, and never interpret unavailable zero fallbacks as real capacity.

## N05. Normalize reservations and recent activity

Map deadlines/timestamps, phases, string work handles, conclusions, and unknown values without phase collapse.

## N06. Normalize pools

Map labels, automatic max, assigned unknown, desired/admitted/advertised, demand/session freshness, ownership, tombstone, and orphan fields.

## N07. Normalize runners

Map job context, nullable exact limits/use, legacy fallbacks, string IDs, completed/stale/retiring, and invalid optional timestamps.

## N08. Add the maximum normalized status fixture

Use eight pools and 64 runners with fractional CPU, non-GiB memory, unknown use, large ID strings, invalid states, migration, compatibility, reservations, activity, and warnings; assert bounded runtime/memory and critical field snapshots.

## G16. Register services in the module

**Files:** `runner-farm.module.ts`.

**Change:** register process runner, controller client, and normalizer as providers and export only services needed by resolver modules.

**Test:** Nest testing module resolves all services.

**Done:** dependency graph has no direct process calls in resolvers.

## Q01. Implement status query

Add `runnerFarmStatus` with `READ_ANY/DOCKER`, one controller call, normalization, and focused success/backend-error/permission tests.

## Q02. Implement readiness query

Add `runnerFarmReadiness` with its own strict result schema, nullable cached count, operation summary, permission metadata, and tests proving no Docker refresh.

## Q03. Implement queue query

Add `runnerFarmQueue`, preserving partial/truncated/detail-complete semantics and string IDs.

## Q04. Implement run-statistics query

Add `runnerFarmRunStatistics`, preserving unavailable versus real zero and age.

## Q05. Implement cache-usage query

Add `runnerFarmCacheUsage`, preserving null total, package bytes, and age.

## Q06. Implement image query

Add `runnerFarmImage` with full image ID, exact bytes, source/base/Dockerfile/in-use fields, and missing-image behavior.

**Done:** each auxiliary query has one controller method and one focused resolver suite.

## G19. Implement Dockerfile query

**Files:** create `src/resolvers/configuration.resolver.ts`; tests.

**Change:** add read-only `runnerFarmDockerfile` using the config CLI command and `READ_ANY/CONFIG`.

**Test:** saved/default content and SHA-256, output bound, permission metadata.

**Done:** Dockerfile content uses shared PHP behavior.

## Q07. Implement operation query

Add exact UUID `runnerFarmOperation` with `READ_ANY/DOCKER`; test running, interrupted, terminal, pruned/not-found, and permission metadata.

## Q08. Implement runner-log query

Add current runner log with validated runner name, 1-500 lines, 64 KiB cap, and no arbitrary path.

## Q09. Implement history-log query

Add retained JIT history log with the same input/bounds and empty-history behavior.

## Q10. Implement controller-log query

Add fixed-source controller/farm log with line/byte bounds, filtering, and `READ_ANY/LOGS`.

**Done:** every log/operation query has a separate resolver test.

## G21. Add request-scoped read caching

**Files:** create `src/services/request-cache.service.ts`; resolver tests.

**Change:** within one GraphQL request, identical status/readiness controller calls share one promise. Cache lifetime ends with the request and never crosses users.

**Test:** two field resolutions cause one process invocation; next request invokes again.

**Done:** field selection cannot multiply Docker calls.

## G22. Add schema generation and diff test

**Files:** create `test/schema.spec.ts` and schema-normalization helper.

**Change:** build a Nest testing application with the plugin module, print schema, normalize descriptions/directive ordering, and compare the Runner Farm extension against `docs/graphql-api-plugin/schema.graphql`.

**Test:** intentional field removal fails snapshot/diff.

**Done:** schema contract is executable.

## G23. Run the read-only package gate

**Commands:**

```bash
pnpm --dir packages/unraid-api-plugin-ci-runner-farm test
pnpm --dir packages/unraid-api-plugin-ci-runner-farm build
npm pack --dry-run --prefix packages/unraid-api-plugin-ci-runner-farm
git diff --check
```

**Done:** package is ESM, pack-valid, schema-compatible, and all read resolvers are permissioned.
