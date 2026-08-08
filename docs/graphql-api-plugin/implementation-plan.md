# Implementation plan: CI Runner Farm GraphQL API plugin

## How to use this plan

Every numbered task is intended to fit approximately one focused ten-minute implementation interval. Some build or live-test commands can run longer, but the code change itself stays narrow.

Complete tasks in order unless a task explicitly says it may run in parallel. Do not combine unrelated tasks into one large patch. Run the listed test after each task. Keep all existing tests green.

The plan is split into:

1. `implementation-plan-upstream.md`: canonical install resolution, direct package discovery, atomic archive, and removal.
2. `implementation-plan-controller.md`: strict controller envelope and read foundation.
3. `implementation-plan-controller-advanced.md`: guarded lifecycle, capacity, migration, and long operations.
4. `implementation-plan-controller-php.md`: shared configuration, Dockerfile, and secret CLIs.
5. `implementation-plan-graphql.md`: package scaffold, raw validation, normalization, and read queries.
6. `implementation-plan-graphql-mutations.md`: configuration, secrets, controls, operations, and subscriptions.
7. `implementation-plan-packaging.md`: deterministic package build, install, upgrade, reboot, and removal.
8. `implementation-plan-mcp.md`: static Rust MCP actions and Labby verification.

## Required worktrees

Use separate worktrees so upstream and product changes stay isolated.

### Runner Farm

Existing design worktree:

`/home/jmagar/workspace/ci-runner-farm/.claude/worktrees/graphql-api-plugin-design`

Implementation SHOULD use a new branch or continue this branch only after the documentation package is committed.

### Unraid API

Create a worktree from current `origin/main`:

```bash
git -C /home/jmagar/workspace/upstream/unraid-api fetch origin --prune
git -C /home/jmagar/workspace/upstream/unraid-api worktree add   -b feat/canonical-api-plugin-install-spec   /home/jmagar/workspace/upstream/unraid-api/.worktrees/canonical-api-plugin-install-spec   origin/main
```

### Unraid MCP

Create a worktree from its current main branch after GraphQL read fields are live.

## Phase gates

### Gate A: upstream installer

Required before declaring local tarball installation supported:

- local tarball resolves to canonical package name;
- no-op reinstall resolves correctly;
- concurrent CLI/GraphQL/reconciler operations serialize under one cross-process lock;
- GraphQL mutation persistence is awaited and restart handoff blocks a second transaction;
- npm failure does not enable a plugin;
- archive replacement is atomic and failure leaves enablement unchanged;
- direct configured-name discovery loads a restored package without a root dependency entry;
- same-version restore and post-reset removal pass;
- API restart loads the package;
- tests pass.

Runner Farm may continue with the interim helper while the upstream PR is pending.

### Gate B: strict read boundary

Required before writing GraphQL resolvers:

- strict envelope helper exists;
- status/readiness add exact millicore, byte, identifier-string, full-image, and INVALID-state data without breaking legacy schema-v2 parity;
- queue, stats, cache, image, operation, and logs return one bounded JSON envelope;
- malformed/oversized requests and responses fail closed;
- legacy commands remain unchanged;
- controller tests pass.

### Gate C: read-only GraphQL slice

Required before mutations:

- package builds and packs;
- module loads in Unraid API;
- `runnerFarmStatus` and `runnerFarmReadiness` work;
- read-only permissions are verified;
- schema fixture matches.

### Gate D: shared config and secret logic

Required before exposing config or credential mutations:

- WebGUI delegates to shared helpers;
- PHP behavior tests remain green;
- config validation/apply CLIs work through stdin;
- secret CLIs leak no values;
- all 48 allowlisted keys and sentinel round-trips are covered;
- field-specific secret limits, stale revisions, Dockerfile SHA conflicts, and atomic-write tests pass.

### Gate E: complete GraphQL surface

Required before packaging release:

- all fields in `schema.graphql` are implemented or explicitly removed from both schema and spec;
- every field has permission metadata;
- long operations use the durable low-frequency operation-metadata journal, reconcile interrupted boot state, and have terminal states;
- subscriptions stop when unused;
- full package tests pass.

### Gate F: installation and reboot

Required before release:

- API tarball is included deterministically;
- install works with official and interim paths without duplicate archive rebuilds;
- module loads after API restart;
- same-version offline reboot restores through direct discovery;
- API-version upgrade reattaches from Runner Farm's flash-cached tarball despite uncertain plugin boot order;
- uninstall removes the API extension and preserves Runner Farm config.

### Gate G: MCP

Required before advertising MCP support:

- static actions compile against the installed schema;
- read and admin scopes are correct;
- revisions are mandatory for controls;
- logs and arrays are bounded;
- secret actions are absent;
- Labby smoke calls pass.

## Definition of each task

A task is complete only when:

1. the specified file change exists;
2. the focused test passes;
3. formatting or syntax checks pass for touched files;
4. `git diff --check` passes;
5. no unrelated file is modified;
6. the task's done condition is observable.

## Full validation commands

### Runner Farm

```bash
bash tests/final-release-gate.sh
```

During development, run the smallest relevant test first, then the full gate at phase boundaries.

### Unraid API

From the upstream worktree:

```bash
pnpm --dir api test --run
pnpm --dir api build
pnpm --dir packages/unraid-api-plugin-generator test
```

Use focused Vitest paths during individual tasks.

### API package

```bash
pnpm --dir packages/unraid-api-plugin-ci-runner-farm test
pnpm --dir packages/unraid-api-plugin-ci-runner-farm build
npm pack --dry-run --prefix packages/unraid-api-plugin-ci-runner-farm
```

### Unraid MCP

```bash
cargo fmt --check --manifest-path unraid-rs/Cargo.toml
cargo clippy --all-targets --all-features --manifest-path unraid-rs/Cargo.toml -- -D warnings
cargo test --all-targets --all-features --manifest-path unraid-rs/Cargo.toml
```

## Commit strategy

Commit at phase gates, not after every ten-minute task. Suggested commits:

1. `fix(api-plugins): make external plugin install and discovery reboot-safe`
2. `feat(api): add strict non-lossy runner farm contract and durable operations`
3. `refactor(api): share config and credential operations`
4. `feat(graphql): add runner farm read models and queries`
5. `feat(graphql): add runner farm mutations and operations`
6. `feat(plugin): package and install runner farm api module`
7. `feat(mcp): expose runner farm graphql actions`

Each commit must be independently testable and must not mix repositories.
