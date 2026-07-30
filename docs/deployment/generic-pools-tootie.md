# Generic Runner Pools Deployment and Rollback

This runbook stages code on `tootie` without changing the active runner-pool
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

Commit `b1834cb` was staged on tootie under a unique plugin directory. The host
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
