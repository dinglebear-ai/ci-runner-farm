# Ten-minute tasks: shared PHP configuration, Dockerfile, and secrets

Continue after the strict controller and durable operation tasks.

## H01. Extract atomic file replacement

Create `storage-core.php` and tests. Require a regular target directory, reject symlink destinations, create a same-directory mode-0600 temp, write completely, flush/fsync when available, then rename. Failure preserves old bytes.

## H02. Extract bounded input helpers

Add reusable helpers for bounded stdin and bounded regular-file reads with explicit overflow detection. Test exact limit, limit+1, NUL/control handling, symlinks, and cleanup.

## H03. Extract bounded GitHub PAT response handling

Move the 64 KiB curl body accumulator and HTTP/transport response interpretation into `secret-core.php`. Test 200, 401, 403, transport failure, malformed identity, and overflow.

## H04. Extract GitHub PAT validation and atomic commit

Move shape validation and bounded live authentication, then commit only after success through the shared atomic helper. Test old-token preservation on validation, network, and storage failures.

## H05. Extract GitHub App key validation

Validate exactly one supported PEM key up to 32 KiB without writing it. Test PKCS#1, PKCS#8, malformed, multiple, and oversized inputs.

## H06. Add GitHub App key set/clear helpers

Use atomic storage/removal and invalidate cached installation token/session files only after successful change. Test set, clear, write failure, and cache invalidation.

## H07. Harden registry-token set/clear helpers

Replace direct `file_put_contents` with the shared atomic helper, preserve the current 4096-byte limit, and test set/clear/write failure independently.

## K01. Add opaque credential revision state

Create a private mode-0600 credential-state file beneath `$CFGDIR` containing schema version, a random 64-hex public revision, and private fingerprints of PAT/App-key/registry files. Expose only the random revision plus presence booleans.

Add a shared secret lock. If state is missing or fingerprints mismatch because of legacy/manual/crash changes, reconcile to a new random revision under the lock before returning or comparing state. No secret hash is exposed.

**Test:** legacy files, manual edit, missing state, corrupt state, crash mismatch, concurrent readers, no leaked fingerprint.

## K02. Add config-plus-credential revision transactions

Every secret set/clear acquires the secret lock, reconciles current state, compares expected config and credential revisions, validates/stages the secret, replaces it atomically, then writes a new random revision/fingerprint state. A crash between the two files is detected on next reconciliation and cannot accept the old revision.

**Test:** two concurrent writers, stale config, stale credential, crash after secret rename, crash after state rename, old-value preservation on validation/write failure.

## K03. Add secret CLI request parsing and revision guards

Create `secret-cli.php`, parse one bounded strict JSON object, require config and credential revisions, reconcile private credential state, and dispatch only fixed verbs. Test malformed/unknown fields, stale revisions, and marker non-reflection.

## K04. Add PAT CLI verbs

Implement set and clear using H03-H04 plus K02; emit only sanitized metadata and the new opaque revision. Test field limit, live validation, clear, and no leakage.

## K05. Add GitHub App key CLI verbs

Implement set and clear using H05-H06 plus K02; test field limit, cache invalidation, crash reconciliation, and no leakage.

## K06. Add registry-token CLI verbs

Implement set and clear using H07 plus K02; test the 4096-byte limit, stale credential, clear, and no leakage.

## CFG01. Extract the 48-key configuration allowlist

Move the exact key order and restricted parser into `config-core.php`. Never source/eval the file. Test valid lines, unknown/duplicate keys, quotes/backslashes/CR/LF, symlink, and deterministic key order.

## CFG02. Add typed GitHub/auth mapping

Map scope, owner, repositories, runner group, auth mode, app IDs, and intentional nullable clears to the existing strings. Enforce current GitHub/payload grammars and per-key byte bounds.

## V01. Map single-runner mode

Map mode, count, labels, default CPU/memory sentinels, backend, ephemeral, and run-as-root fields. Test uncapped values and bounds.

## V02. Map legacy V1 pools

Serialize and normalize `id|fixed|min|max|idle` records with organization scope, duplicate checks, aggregate 64 limits, and canonical ordering.

## V03. Map V2 pools

Serialize routing/additional labels, fixed/min/max/idle, exact CPU/memory claims, `max=auto`, eight-pool and 16 KiB limits. Test every cross-pool label collision.

## CFG03. Preserve pool-autoscale sentinel semantics

Map `INHERIT` to literal `POOL_AUTOSCALE=inherit`; map `EXPLICIT` plus an empty/non-empty ID list to the canonical explicit value. Test unknown, duplicate, and non-existent IDs.

## V04. Map resource budgets and policy

Map CPU/memory budget null to `auto`, reserves, CPU overcommit, `NONE|DOUBLE` swap, and nonnegative PIDs using current controller semantics.

## V05. Map cache root and mounts

Map cache root and cache-mount list with current per-key byte limits; leave destructive path validation to the controller and test traversal-like strings remain rejected at apply.

## V06. Map workspace mode

Map `TMPFS` plus exact bytes to the canonical size string and `CACHE_BIND` to empty `WORK_TMPFS_SIZE`. Test mode/value contradictions.

## V07. Map image and registry identity

Map built-in/remote source, nullable image/registry clears, image reference grammar, and per-key limits.

## V08. Map Docker and network policy

Map socket sharing, DinD, shared cache, isolation mode, runner network, and mirror port with current cross-field rules.

## V09. Map autoscaling

Map enabled/min/max/min-idle/step/interval/grace using current controller integer and 64-runner constraints.

## V10. Map image-update policy

Map enabled state, interval 300-86400, and drain timeout 0 or 60-86400.

## CFG04. Add deterministic patch merge and serialization

Merge only present typed fields with the exact revision-guarded current allowlist. Serialize canonical `KEY="value"` lines and reject NUL, CR, LF, quote, and backslash. Partial patches preserve unrelated groups.

## CFG05. Add configuration snapshot read

`config-cli.php read` returns revision, validity/issues, nullable typed configuration, canonical effective string values for all 48 keys, one opaque credential revision, and PAT/App-key/registry-token presence booleans. Invalid manually edited config still returns a useful snapshot.

## CFG06. Add side-effect-free config validation

`validate` requires expected config revision and patch, maps/merges against that exact revision, invokes the same semantic validators, and performs no flash commit, daemon action, override change, or reconciliation.

## CFG07. Add config apply

`apply` uses the same mapping, writes a same-directory mode-0600 stage, calls existing `apply-config`, deletes the stage on every path, and returns the strict envelope.

## DF01. Centralize Dockerfile read

Return saved/default content plus the SHA-256 of the currently effective editable content, with existing size/symlink checks.

## DF02. Add revision-guarded Dockerfile save

Require the caller's expected current Dockerfile SHA, stage and atomically replace only when it still matches, then return the new SHA. Preserve existing content on stale or write failure.

## V11. Delegate WebGUI secret actions

Keep POST/CSRF/form parsing in `exec.php`; delegate PAT, App-key, and registry set/clear to shared helpers while preserving response compatibility.

## V12. Delegate WebGUI configuration actions

Delegate validation/apply mapping and staging while preserving tab-partial merge and existing HTTP/domain results.

## V13. Delegate WebGUI Dockerfile actions

Delegate read/save/hash behavior and preserve current save-then-build UI flow.

## V14. Package shared CLI and library files

Package CLI scripts as 0755 and PHP libraries as 0644; verify exact installed paths and deterministic archive contents.

## V15. Run the shared-PHP gate

Run PHP syntax, storage/credential/config/Dockerfile tests, WebGUI endpoint tests, config parity, package reproducibility, final release gate, and `git diff --check`.

**Done:** both adapters share one revision-safe, sentinel-preserving implementation.
