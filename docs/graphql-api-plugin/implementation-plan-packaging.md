# Ten-minute tasks: API package build, installation, reconciliation, and removal

Continue after the complete GraphQL gate.

## P01. Build and validate with npm pack

Build the package, run `npm pack --json --pack-destination`, and use npm's produced tarball rather than constructing a second package format manually. Record canonical filename, version, integrity, size, and SHA-256.

**Test:** two clean builds at the same source revision produce identical bytes; `npm pack --dry-run` lists only intended files.

## P02. Validate package metadata and contents

Require canonical name/version, Apache-2.0 license, compiled ESM and declarations, current reviewed/tested `unraidVersion`, compatible peer ranges, plugin-owned dependencies, and no source/tests/node_modules/lockfiles/credentials/absolute paths.

## P03. Integrate the npm tarball into build-plg.sh

Copy exactly one API tarball into the Runner Farm payload beneath `api/`; record filename and SHA-256 in generated installer metadata. The Runner Farm release version controls the embedded module version.

## P04. Cache package source on flash

On install/upgrade, atomically copy the verified tarball to `/boot/config/plugins/ci-runner-farm/api/`. Retain the previous verified tarball until the new module passes reconciliation and live gates.

## P05. Add fixed API integration paths

Create `api-plugin-install.sh` with fixed canonical name, flash cache, API root, top-level node_modules, API config, service script, npm, and CLI paths. No user input controls a path.

## P06. Classify API availability

Return `available`, `absent`, or `broken` from exact checks for the CLI/binary, root manifest, npm, config path, service script, and runtime directory. Core Runner Farm install succeeds when API is absent; broken attachment is reported without deleting the farm.

## P07. Detect the complete upstream capability

Compare installed API version against a constant introduced only after a release contains all three requirements: canonical spec resolution, direct configured-name discovery, and atomic archive replacement. Before that release, use the interim path. Test older/equal/newer/prerelease/malformed versions.

## P08. Add official CLI reconciliation

Acquire the upstream shared cross-process plugin transaction lock, then for a capable API run an exact argv equivalent to `unraid-api plugins install <absolute-tarball> --no-restart` only when exact package/config state differs. The official service performs the archive rebuild; the outer installer MUST NOT call `archive-dependencies` again.

Verify canonical `api.json` entry and exact top-level installed manifest. Do not require a root peer-dependency entry.

## P09. Add interim structured npm install

For older APIs, implement the same shared lock protocol before touching the API tree. Under that lock run structured npm install, verify tarball and top-level manifests, resolve the canonical name, and handle no-op reinstall without filename guessing. Pass the verified owner token to the archive helper so it does not reacquire the same lock. Do not parse human output.

## P10. Add interim atomic archive-before-enable

After interim install, run exactly one atomic archive rebuild while enablement is still unchanged. Only after archive success atomically add the canonical name to `api.json`. Failure preserves prior config and archive.

## P11. Add interim canonical api.json registration

Load the bounded boot config, preserve unrelated fields/plugins, and atomically add the canonical package name after archive success. Reject symlink/malformed config. No raw path or versioned spec enters the list.

## P12. Add reconciliation state and change detection

Persist a small mode-0600 Runner Farm integration record containing API version, module version, tarball SHA-256, canonical name, and last successful verification. Reconcile against live API state rather than trusting this record alone.

A no-change run performs no npm install, archive rebuild, or restart.

## P13. Add bounded boot and API-upgrade reconciliation

Create an idempotent background reconciler invoked from Runner Farm install/boot and repair paths. It acquires the shared plugin-management lock before any live-tree inspection that can lead to mutation. It waits boundedly for a complete API, tolerates either Unraid-plugin installation order, and re-runs when the API version changes.

If API remains absent, record GraphQL inactive and exit successfully without blocking Runner Farm boot.

## P14. Restart exactly once when state changed

Batch installation, archive, and canonical registration, then restart through `/etc/rc.d/rc.unraid-api restart` once. Poll status with a bounded deadline. No restart occurs for absent API, failed preconditions, or a verified no-op.

## P15. Verify exact package identity and plugin ABI

Prefer the upstream `unraid-api plugins verify <canonical-name>` capability. For interim APIs, verify the exact top-level manifest and perform an isolated canonical package import/ABI check through a fixed helper. Do not claim `hasApiModule` from `plugins list`, which currently reports only name/version.

## P16. Add optional authenticated GraphQL smoke verification

When an explicit test/admin API key is supplied by the live-test harness, query schema/plugin metadata and `runnerFarmStatus.schemaVersion`. Normal installation does not invent, read, or require an API key.

## P17. Add same-API-version module upgrade rollback

Retain the previous flash tarball and reconciliation record until the new package installs, archives, restarts, and verifies. On failure, reinstall the previous tarball, rebuild or restore the prior archive and canonical config, restart once, and verify rollback.

## P18. Add API-version upgrade reattachment

Test an API root/version change that lacks Runner Farm in its new dependency tree. The reconciler installs the flash-cached package into the new tree, builds that version's archive, preserves canonical enablement, restarts once, and verifies import.

## P19. Add uninstall for official and interim states

Disable the canonical name, remove the exact package, rebuild the archive exactly once through the responsible path, restart once, and verify absence. Cover both normal root-dependency state and a same-version reboot state where the package is restored but absent from the root manifest. Preserve unrelated plugins and Runner Farm config/credentials.

## P20. Wire install, repair, and removal into ci-runner-farm.plg

Cache the package and launch bounded reconciliation without making core Runner Farm installation depend on API availability. Add an explicit repair/reconcile action for later API installation or recovery. Removal invokes API-module removal before deleting runtime files but retains rollback evidence on failure.

## P21. Add same-version offline reboot live test

Install and verify, remove any runtime root dependency entry in the test fixture while preserving canonical config/archive, disable external network, reboot, prove archive restore plus direct discovery, optionally query with an explicit test key, then restore network.

## P22. Add API-version upgrade live test

Upgrade or replace the approved test API package/version, allow uncertain plugin boot order, prove Runner Farm's reconciler reattaches from flash, then verify import, canonical config, new version archive, and optional GraphQL query.

## P23. Run the packaging phase gate

Run API package test/build/pack, Runner Farm package reproducibility and final release gates, exact tarball inclusion checks, official/interim no-op and change fixtures, same-version reboot, API-version upgrade, rollback, and uninstall on the approved host.

**Done:** installation is idempotent, same-version reboot-safe, API-upgrade-aware, and removable without duplicate archive or restart work.
