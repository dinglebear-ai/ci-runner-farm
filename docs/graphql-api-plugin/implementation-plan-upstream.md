# Ten-minute tasks: upstream Unraid API plugin installation and discovery

Repository worktree:

`/home/jmagar/workspace/upstream/unraid-api/.worktrees/canonical-api-plugin-install-spec`

These tasks implement `upstream-install-spec-resolution.md`. Every task is a focused code/test increment; run the smallest listed test before moving on.

## U01. Create and verify the feature worktree

Fetch `origin/main`, create `feat/canonical-api-plugin-install-spec`, then record hostname, user, platform, path, branch, and commit. The reviewed baseline was `98034ff8`; implementation uses the freshly fetched commit.

**Done:** clean worktree on current upstream main.

## U02. Add npm structured-result schemas

**Files:** create `api/src/unraid-api/app/npm-install-result.ts` and spec.

Add strict Zod schemas for npm `add`, `change`, and `remove` entries with bounded non-empty name/version/path fields.

**Test:** valid observed fixture, missing arrays defaulted, malformed values rejected.

## U03. Add canonical install result types

**Files:** `dependency.service.ts`.

Add `InstalledPluginIdentity` and `PluginInstallResult` from the specification. No behavior change yet.

**Test:** API TypeScript build.

## U04. Run npm install in JSON mode

**Files:** `dependency.service.ts` and spec.

Add a dedicated method that runs an exact argv equivalent to `npm install --json --save-peer --save-exact <spec...>`. Use the API root cwd, bounded stdout/stderr, no shell, and no inherited stdio. Parse only structured JSON.

**Test:** exact argv/cwd/bounds and malformed output.

## U05. Resolve changed installs

**Files:** create `peer-install-resolution.ts` and spec.

Map npm add/change entries plus before/after peer maps to canonical candidates. Preserve request order and deduplicate names.

**Test:** tarball, scoped package, reverse result order, duplicate name.

## U06. Add safe top-level package paths

Validate canonical npm names, split scoped names into safe segments, and derive only paths beneath the API's top-level `node_modules`. Reject traversal, backslash, NUL, invalid scope/name, and path escape.

**Test:** scoped/unscoped valid paths and escape cases.

## U07. Verify installed manifests

Read a bounded regular non-symlink `package.json` at the exact path from U06. Require matching canonical name and non-empty version.

**Test:** valid, missing, symlink, oversized, malformed, name mismatch.

## U08. Resolve no-op local directories

For an absolute or `file:` directory spec with no npm change entry, read its bounded source manifest, derive the canonical name, then verify the installed top-level manifest and saved peer spec.

## U09. Resolve no-op local tarballs

Read exactly `package/package.json` from a bounded regular non-symlink `.tgz` through a fixed archive command or reviewed library. Never infer identity from the filename.

## U10. Resolve no-op registry specs

For scoped/unscoped registry specs, parse the canonical name, then verify the installed manifest and saved peer spec. Paths must not be parsed as names.

## U11. Reject ambiguous remote and Git no-ops

When npm reports no changed identity and a remote/Git spec cannot be proven uniquely, fail closed rather than guessing.

## U12. Compose installPeerDependencies

Read fresh before/after root peer dependencies from `getPackageJsonPath()` using bounded JSON file reads; do not use cached `getPackageJson()`. Then run structured npm, resolve every request, verify installed manifests, read saved specs, and return results in request order. Reject the whole call if any request is unresolved.

**Test:** changed and no-op mixed batch plus partial-resolution failure.

## U13. Add canonical configured-name validation

Create a pure helper for values read from `api.plugins`. It accepts canonical package names only, never paths, URLs, or versioned install specs.

**Test:** scoped/unscoped names and every raw-spec form.

## U14. Discover directly from top-level manifests

Refactor `PluginService.listPlugins` to iterate the configured canonical allowlist, derive the safe top-level package path, verify its manifest, and return name/version without consulting root dependencies.

**Test:** a restored package loads when absent from root peerDependencies; scoped package; missing package; name mismatch.

## U15. Preserve discovery failure isolation

Ensure one missing/invalid package is logged and notified without preventing other valid packages from loading. Safe mode still returns no plugins without touching manifests.

**Test:** one valid plus one invalid package and safe-mode cases.

## L01. Add the cross-process plugin transaction lock

Create a shared lock service/protocol under a fixed `/var/lock` path. Use atomic directory creation plus owner boot ID, PID, process-start ticks, random token, and timestamp. Add bounded wait, incomplete-owner grace, exact stale-owner recovery, and token-checked release.

**Test:** two processes serialize; live owner is not stolen; PID reuse/start mismatch is stale; boot mismatch is stale; only owner releases; timeout is bounded; direct archive acquires the lock; owner-token archive handoff does not deadlock; wrong token is rejected.

## L02. Put CLI and GraphQL transactions under the lock

Refactor add/remove so the lock spans install/uninstall, fresh manifest reads, archive, canonical config update, and explicit `ApiConfigPersistence.persist()`. GraphQL no longer relies on buffered background persistence. A changed canonical list requires `persist() === true`; `false` is accepted only for a proven no-op, and the observer's equality check must prevent a duplicate flash write. Automatic restart hands lock ownership to the lifecycle path until restart or failure cleanup; `restart:false` releases normally.

**Test:** concurrent CLI/GraphQL operations, persistence failure, restart-delay exclusion, restart failure cleanup, and successful new-process stale-lock recovery.

## U16. Make dependency archive replacement atomic

**Files:** `dependencies.sh` and shell tests.

Write a same-directory temporary archive, verify tar success, set ownership/mode, then rename over the final archive. Failure preserves previous bytes and removes the temp file.

## U17. Install and archive before enablement

Refactor `PluginManagementService.addPlugin` so unbundled specs install/resolve, then archive, then add canonical names to in-memory config. npm or archive failure leaves enablement unchanged. Bundled behavior remains config-only.

**Test:** exact call order and each failure boundary.

## U18. Return canonical metadata to CLI and GraphQL management

Return installed identities from the service. CLI success logs `Installed <spec> as <name>@<version>`. Correct the GraphQL input description if its existing `names` field remains for compatibility.

## U19. Persist and restart only after success

Add CLI tests proving config persistence happens once after service success, never after install/archive failure, and restart occurs once unless `--no-restart` was supplied.

## U20. Verify removal after root-manifest reset

Create a real npm fixture that installs a plugin, removes the root dependency entry while leaving the top-level package, then invokes the removal path. The audit fixture confirmed npm uninstall removes it; assert that behavior and exact absence without adding an unnecessary direct-delete fallback. Rebuild the archive atomically and preserve unrelated packages/plugins.

## U21. Add a package/import verification command

Add or specify `unraid-api plugins verify <canonical-name>` to validate configured name, top-level manifest, and plugin ABI import without requiring a GraphQL API key. If upstream declines a new command, document the exact supported CLI verification alternative.

## U22. Add same-version reboot fixture

Build an archive containing an external top-level package, restore it into a clean packaged API root whose package.json lacks the dependency, and prove direct configured-name discovery loads it.

## U23. Run the upstream phase gate

Run focused Vitest suites for npm parsing, resolution, management, discovery, CLI, and removal; run shell archive tests; then run API build and `git diff --check`.

Also run real local directory/tarball install, no-op reinstall, archive/restore discovery, and post-reset removal fixtures.

**Done:** canonical install, direct discovery, atomic archive, and removal gates all pass.
