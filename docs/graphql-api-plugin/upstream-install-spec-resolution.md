# Upstream Unraid API change: canonical install specs and reboot-safe discovery

## Decision

CI Runner Farm will use the official Unraid API plugin installer after upstream supports local package directories and tarballs without storing raw install specs in API configuration.

The durable design has two independent requirements:

1. Resolve each requested npm install spec to its canonical installed package name before enabling it.
2. Discover enabled plugins from canonical names and restored top-level package manifests, without depending on runtime edits to the API root package manifest.

Until a released Unraid API contains both behaviors, Runner Farm may use a capability-detected compatibility installer and boot reconciler. That bridge is not a second plugin registry.

## Revisions reviewed

- CI Runner Farm: `086274a45ec4f598e8013f9d109cd2983cfce4e4`.
- Unraid API: `98034ff8405d8f1322daca9bd4d7d7dccc262810`.
- Unraid API package version: `4.36.1`.

## Current behavior

At the reviewed revision:

1. `InstallPluginCommand` passes its argument unchanged to `PluginManagementService.addPlugin`.
2. `addPlugin` adds that unchanged string to `api.plugins` before npm succeeds.
3. It runs `npm i --save-peer --save-exact <spec>` in `/usr/local/unraid-api`.
4. It archives only `/usr/local/unraid-api/node_modules` to the boot drive.
5. `PluginService.listPlugins` keeps configured names only when they occur in the API root `package.json` dependencies or peer dependencies.

Relevant files include `plugin.command.ts`, `plugin-management.service.ts`, `plugin.service.ts`, `dependency.service.ts`, `environment.ts`, `utils.ts`, and `dependencies.sh`.

## Confirmed defects

### Raw specs do not match package identities

A local tarball path is not the package name. npm saves the dependency under its canonical name. A DOOKIE fixture confirmed that `npm install --json --save-peer --save-exact /path/plugin.tgz` reports canonical name/version when the tree changes, while a no-op reinstall has empty `add` and `change` arrays.

### Root-manifest edits are not reboot-persistent

The current archive contains only `node_modules`. It does not preserve `/usr/local/unraid-api/package.json` or a runtime-modified lockfile. After a same-version reboot, the package may be restored under `node_modules`, but current discovery ignores it because the packaged root manifest no longer lists it.

### API-version upgrades are a separate lifecycle

The dependency archive is version-specific. An API upgrade can install a new dependency tree without third-party packages. External Unraid plugins must retain their own package source and reconcile after the upgraded API becomes ready. The API archive is a same-version reboot optimization, not the sole source of truth.

## Required invariants

- `api.plugins` contains canonical npm package names only.
- npm installation and archive creation complete before a canonical name is enabled.
- discovery reads enabled canonical names directly from restored top-level package manifests.
- discovery never scans or imports arbitrary undeclared packages.
- installed manifest name exactly matches the configured name.
- install or archive failure leaves enablement unchanged.
- archive replacement is atomic and preserves the old archive on failure.
- one invalid package does not prevent other valid plugins from loading.
- safe mode continues to skip external API plugins.

## Canonical identity model

```ts
export interface InstalledPluginIdentity {
    requestedSpec: string;
    name: string;
    version: string;
    savedSpec: string;
    packageJsonPath: string;
}

export interface PluginInstallResult {
    installed: InstalledPluginIdentity[];
    packageJsonChanged: boolean;
}
```

Only `name` belongs in `api.plugins`.

## Structured npm installation

Add:

```ts
async installPeerDependencies(...requestedSpecs: string[]): Promise<PluginInstallResult>
```

It must bound request count and length, read fresh before/after peer-dependency snapshots directly from the bounded root manifest path returned by `getPackageJsonPath()`, run npm with an argument array and `--json`, cap stdout, resolve every request, verify each top-level installed manifest, and return results in request order. It MUST NOT use `getPackageJson()` for the before/after comparison because that helper loads through Node `require` and is cached within the process. It must not scrape human npm output.

## Resolution rules

1. Prefer npm `add` or `change` entries.
2. Verify the corresponding top-level installed manifest.
3. For a no-op registry spec, parse and verify the canonical package name.
4. For a no-op local directory, read its bounded regular `package.json`, then verify the installed manifest.
5. For a no-op local tarball, read exactly `package/package.json` from a bounded regular non-symlink archive, then verify the installed manifest.
6. For a Git or remote spec without a unique changed entry, fail as ambiguous.
7. Reject traversal, backslashes, control characters, invalid names, manifest mismatch, and conflicting identities.

## Reboot-safe discovery

Replace the root-manifest filter in `PluginService.listPlugins`.

For each canonical name in `api.plugins`:

1. Validate it as a canonical npm package name, not a general install spec.
2. Derive its exact top-level path beneath `/usr/local/unraid-api/node_modules`.
3. Require a bounded regular non-symlink `package.json`.
4. Require `manifest.name === configuredName` and a non-empty version.
5. Return `[name, version]` for import.

Do not scan all of `node_modules`; configuration remains the allowlist.

## Cross-process transaction coordination

CLI commands, GraphQL mutations, and third-party compatibility reconcilers can run in separate processes. All plugin-tree mutations therefore share one bounded cross-process transaction lock, for example an atomic directory under `/var/lock` with owner boot ID, PID, process-start ticks, random token, and creation time.

Acquisition waits boundedly. Stale recovery verifies boot ID and exact live process start before atomically quarantining an abandoned lock. Release verifies the random owner token. A newly created lock without complete owner metadata receives a short grace period rather than being immediately stolen.

The lock spans fresh manifest read, npm install/uninstall, manifest verification, atomic archive replacement, canonical config update, and explicit config persistence. The public `archive-dependencies` entry point acquires this lock when called directly. A transaction that already owns the lock passes its random owner token to the archive helper; the helper verifies the current owner and skips nested acquisition, avoiding deadlock without allowing an unrelated caller to bypass serialization.

GraphQL add/remove currently mutates ConfigService, relies on buffered background persistence, and schedules restart after 300 ms. The corrected transaction explicitly awaits `ApiConfigPersistence.persist()`. When the canonical plugin list changed, the result must be `true`; `false` is acceptable only for a proven no-op because `ConfigFileHandler` uses `false` for both unchanged data and write failure. The subsequent buffered observer sees equal disk state and skips an additional flash write. When automatic restart is requested, lock ownership is handed to the restart lifecycle so no second process enters during the delay; startup or an explicit failure callback recovers/releases the handoff.

## Installation ordering

For unbundled packages, `addPlugin` should:

1. install and resolve requested specs;
2. atomically rebuild the dependency archive;
3. add resolved canonical names to in-memory configuration;
4. return resolved metadata.

Persistence and restart happen only after this method succeeds. If persistence later fails, the package is installed but disabled, which is safer than enabled-but-not-durable state.

Bundled packages remain config-only.

## Atomic archive

`dependencies.sh archive` must create a same-directory temporary archive, finish and verify it, set ownership/mode, and atomically rename it over the final path. Failure removes the temporary file and preserves the previous archive.

## Removal

Removal accepts canonical package names only. It removes enablement, runs npm uninstall, rebuilds the archive, persists, and restarts once. Cover the post-reboot case where the package is restored but absent from the root manifest. A DOOKIE npm fixture confirmed `npm uninstall <canonical-name>` removes that extraneous top-level package even after the root dependency entry is removed; preserve that behavior with a regression test and verify exact absence afterward.

## CLI and GraphQL management

The CLI remains:

```bash
unraid-api plugins install /absolute/path/plugin.tgz
```

Success should report both requested and canonical identities. `--no-restart` remains available.

The current GraphQL management input is named `names`, though unbundled entries are specs. Upstream may correct its description compatibly or introduce `specs` in a later breaking schema. Runner Farm installation uses the CLI.

A future `plugins verify <canonical-name>` CLI command is recommended so package installers can verify presence and import without a GraphQL API credential. Current `plugins list` does not prove `hasApiModule`.

## Same-version reboot versus API upgrade

### Same-version reboot

The version-specific archive restores top-level `node_modules`. Canonical direct discovery loads enabled packages from restored package manifests.

### API-version upgrade

A third-party Unraid plugin retains its npm tarball on flash and runs bounded reconciliation after the new API service is ready. Reconciliation installs into the new dependency tree, rebuilds that version's archive, confirms canonical enablement, and restarts once only if a change was required. Runner Farm must tolerate either plugin installation order during boot.

## Required tests

### Install resolution

- changed and no-op local tarball;
- changed and no-op local directory;
- scoped and unscoped registry specs;
- request/result order mismatch;
- deduplication;
- ambiguous Git no-op rejection;
- invalid archive and manifest mismatch;
- npm failure leaves configuration unchanged.

### Discovery

- restored top-level package loads with no root dependency entry;
- scoped package;
- missing package and manifest mismatch are independently rejected;
- raw path in `api.plugins` is rejected;
- safe mode skips discovery;
- one invalid package does not block valid packages.

### Archive and removal

- atomic replacement and old-archive preservation;
- temporary cleanup;
- same-version restore plus direct discovery;
- normal and restored-extraneous removal;
- unrelated package/plugin preservation.

### CLI

- resolved identity output;
- no persistence/restart after install or archive failure;
- one persistence and optional one restart after success;
- `--no-restart` behavior.

## Runner Farm interim path

Until upstream ships the complete capability, Runner Farm may:

1. wait boundedly for a complete API installation;
2. install its cached local tarball with structured npm output;
3. resolve and verify the canonical top-level identity;
4. atomically rebuild the current version's archive;
5. atomically add the canonical name to `api.json`;
6. restart once only when state changed;
7. verify package import through an available CLI path;
8. perform GraphQL verification only when an explicit test/admin API key is supplied.

The helper must not claim success from configuration alone and is removed after the minimum supported API contains canonical resolution, direct discovery, and atomic archive replacement.

## Acceptance criteria

- Local tarballs are enabled under canonical names.
- `api.json` never contains a local path.
- Same-version reboot loads the package without a modified root manifest.
- Archive failure preserves the old archive and does not enable the package.
- Invalid packages fail independently.
- API upgrades can be reconciled from the third-party plugin's cached source.
- Removal works before and after a root-manifest reset.
