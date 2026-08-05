# Generic Runner Pools Deployment and Rollback

This runbook stages code on `nashost` without changing the active runner-pool
configuration. It never publishes to, or pushes Git refs toward, the official
`unraid/ci-runner-farm` repository.

## Preconditions

- Record `hostname`, kernel, Docker version, cgroup mode, online CPU count,
  memory, swap, and cache filesystem.
- Record the active plugin tree SHA-256 manifest, runner image digest, current
  configuration SHA-256, mode, owner, and permissions.
- Confirm the active implementation commit and set a unique stage ID from its
  first 12 hexadecimal characters.
- Keep the existing plugin directory and configuration as recoverable backups.

## Code-only staging

1. Copy `src/usr/local/emhttp/plugins/ci-runner-farm` to
   `/usr/local/emhttp/plugins/.ci-runner-farm.<stage-id>`.
2. Verify every transferred SHA-256 and run PHP and shell syntax checks there.
3. Set directories to 0755, regular files to 0644, `runner-farm.sh`,
   `runner-entrypoint.sh`, event hooks, and nchan hooks to 0755.
4. Run `runner-farm.sh maintenance begin`. This stops new admissions while
   preserving busy runners and their jobs.
5. Rename the active directory to a unique backup and atomically rename the
   staged directory into place.
6. Exercise authenticated Settings and Fleet reads. Confirm schema version 2,
   revisions, resources, pools, reservations, and maintenance state.
7. Run `runner-farm.sh maintenance resume`.

Do not Apply V2 pool settings until the code-only smoke is green.

## Classic V2 proof

Use temporary, collision-free routing labels for Rust, Python, TypeScript, Go,
Ops, and Residential Egress. Verify exact labels, CPU/memory/PID limits,
fixed-mode `Scale to`, autoscale-mode `Scale up to`, resource exhaustion reason
codes, reservation recovery, and progress by healthy pools when another pool
cannot start. Check Docker metadata, process arguments, logs, `_runner`,
`.credentials`, and listener environments for credential sentinels.

Restore the exact pre-test configuration through the transactional Settings
endpoint. Wait for busy runners to drain before retiring temporary identities.

## Rollback

1. Enter maintenance; do not use destructive `stop`.
2. Atomically restore the saved plugin directory.
3. Restore the exact saved configuration only if it changed, preserving mode
   0600 and its SHA-256.
4. Run syntax checks and authenticated status.
5. Resume admissions.
6. Confirm pre-existing busy runners were uninterrupted and remove only the
   uniquely named stage and test fixtures.

## 2026-07-30 code-only proof

Commit `b1834cb` was staged on nashost under a unique plugin directory. The host
reported Linux 6.18.38-Unraid, Docker 29.5.3, cgroup v2, 24 online CPUs,
131517828 KiB RAM, no swap, and ZFS at `/mnt/cache`. The active configuration
was mode 0600 with SHA-256
`6341005956d70b78af1fcca34d9b028f49ea0265be3c86366993b7ff4532fe77`.

All five existing runners were busy before the switch. The deployment paused
autoscaling, entered maintenance, atomically switched the code directory, and
left the configuration byte-identical. Schema-v2 status then reported the same
five runners as busy, classic effective backend, no stale runners, zero pending
reservations, and maintenance state correctly. Resume restarted autoscaling.
Container start ages were unchanged, demonstrating that no busy runner was
recreated or interrupted. The recoverable code and configuration backups remain
uniquely named with the stage ID until final acceptance.

## Pool selectors and label contract

V2 pools have an immutable internal ID, an editable routing label, optional
additional requirement labels, and explicit CPU/memory claims. Workflows must
request the routing label:

```yaml
# Examples; use the routing labels saved in Settings.
runs-on: ci-pool-rust
runs-on: ci-pool-python
runs-on: ci-pool-typescript
```

Rust, Python, TypeScript, Go, Ops, and Residential Egress are convenience
presets only. A label never installs a toolchain, grants a mount, changes
network egress, or creates a security boundary. Residential Egress requires a
separately configured and verified network path before any workflow relies on
that claim.

## Scaling semantics

- Classic fixed pools use **Scale to**.
- Classic autoscaled pools use **Scale up to** as a temporary floor; classic
  demand is not authoritative and classic pools cannot scale to zero.
- Scale-set pools use **Prewarm to** for operator-requested warm capacity.
  Assigned GitHub demand is separate and cannot be overridden by prewarm.
- V2 admission always reserves declared CPU and memory first. The resource
  broker accounts running/draining runners, pending starts, JIT runners, and
  outstanding GitHub poll leases. `64` is only a corruption fuse, not normal
  host policy.
- The scheduler admits at most two cold starts per pass by default and never
  more than four. Feasible pools receive one admission per round.

## Scale-set compatibility and activation

Scale-set activation is deliberately unavailable until a disposable live gate
proves the exact installed package identity. The record binds the plugin,
static helper, pinned scale-set module revision, Go version, runner image,
Dockerfile, entrypoint, owner/API URL, host/installation identity, and a
non-default restricted runner-group ID and policy. It expires after 30 days or
any bound-input change.

Run the offline package gate normally:

```bash
bash tests/final-release-gate.sh
```

Require a live record before claiming activation:

```bash
CRF_REQUIRE_LIVE_GATE=1 \
CRF_LIVE_COMPAT_RECORD=/boot/config/plugins/ci-runner-farm/scale-set-compatibility.json \
bash tests/final-release-gate.sh
```

The compatibility operation uses an opaque ID and must use a disposable
repository, collision-proof selectors, a restricted runner group, exact
recorded remote IDs, and complete cleanup. A missing, stale, tampered, or
identity-mismatched record leaves classic operational and reports the exact
invalidation reason. Never bypass this with a synthesized record.

## Backend migration and recovery

Saving `POOL_BACKEND=scaleset` records requested intent only. It does not alter
the effective backend. **Begin fleet migration** advances a persisted,
revision-bound state machine only after the gate is valid. The forward path
creates scale sets ineligible, quiesces classic without stopping busy jobs,
proves classic remotely ineligible, then enables scale sets. No phase permits
both backends to be production-eligible.

**Roll back to classic** first makes scale sets ineligible, continues serving
already assigned JIT work, drains it, restores classic eligibility, and deletes
only exact owned remote IDs. Ambiguous deletion retains a tombstone for
operator resolution. Restart resumes the persisted phase; it never infers
effective state from Settings.

If the helper, demand snapshot, eligibility proof, ownership ledger, or
compatibility record is stale or invalid, stop migration and keep/restore
classic through the explicit rollback path. Do not delete scale sets by name
and do not use destructive fleet Stop as a deployment shortcut.

## Diagnostics and retention

Helper replay state and bounded logs live below
`<CACHE_ROOT>/controller/`. Per-runner `Runner_*` and `Worker_*` diagnostics
live below `<CACHE_ROOT>/logs/runners/<runner-id>/`, mode 0600, with a default
combined limit of 256 MiB and seven days. Aggregate Fleet/Nchan status excludes
repository names, refs, job IDs, raw messages, JIT blobs, and credentials.
Ephemeral reservations, leases, snapshots, operations, PIDs, and sockets live
under `/run/ci-runner-farm`; steady-state control traffic writes nothing to
`/boot`.
