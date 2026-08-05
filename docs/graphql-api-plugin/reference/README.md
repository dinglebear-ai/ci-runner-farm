# Reference code

These TypeScript files are implementation-ready design references for the future package:

`packages/unraid-api-plugin-ci-runner-farm`

They are not compiled by CI Runner Farm yet. The implementation plan copies and adapts them into the package after the strict controller API exists.

## Files

- `types.ts`: branded identifiers, raw controller/status structures, and internal service interfaces.
- `enums.ts`: code-first GraphQL enums.
- `common.models.ts`: shared reasons, revisions, compatibility, operations, resources, and action results.
- `fleet.models.ts`: fleet, pool, runner, and readiness outputs.
- `configuration.models.ts`: typed configuration outputs without credential values.
- `auxiliary.models.ts`: queue, run statistics, cache, image, Dockerfile, and logs.
- `input.models.ts`: validated mutation/query inputs.
- `contracts.ts`: exact executable paths, process limits, field permissions, and stable error codes.

## Source-of-truth order

1. Existing Runner Farm controller behavior.
2. Normative `contract.md` and `runtime-contract.md`.
3. Public `schema.graphql`.
4. These reference files.

When a reference conflicts with existing controller behavior, update the design and tests before implementation. Do not silently change the controller contract in TypeScript.
