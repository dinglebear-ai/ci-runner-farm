# Distributed control plane decommission — 2026-09-10

**Status: DECOMMISSIONED.** The standalone distributed control plane described in this
directory no longer runs anywhere. All real CI runs on the classic Docker backend of the
Unraid plugin, which this work did not modify.

Tracking: beads epic `unraid-mcp-43mc`.

## Terminology

Hostnames are deliberately omitted: this repository is public, and
`tests/no-internal-identifiers.sh` guards against internal network identifiers. Roles used below:

- **Controller laptop**: the developer laptop that hosted the controller from about 2026-08-28.
  It was also issued a node identity, but that node was not running at teardown.
- **Unraid CI host**: the Unraid server running the classic fleet (`nashost` in this
  repository's deployment docs). It also carried one distributed node.
- **Node host A**: a Linux node host with one node identity.
- **Node host B**: a Linux (WSL) node host carrying **two** node identities.

## Why decommission rather than migrate

- The controller stopped writing its operator projection on 2026-08-31. A restart attempt on
  2026-09-09 crashed with
  `{application_start_failure,crf_controller,{shutdown,{failed_to_start_child,'Elixir.CrfController.Ingress',replay_store_unavailable}}}`,
  after its durable store had corrupted repeatedly.
- It served no real CI. The plugin configuration does not reference the distributed backend,
  and the classic fleet carries all work.
- It was not moved onto the Unraid CI host. The bundle ships systemd units and installs to
  `/opt` (`scripts/build-distributed-bundle.sh`). Unraid has no systemd, and its root
  filesystem is RAM-backed. An Unraid-native controller is what the `my-core-plugs` port
  already declares (`package_root: /usr/local/unraid-native/ci-runner-farm`), so hand-porting
  the bundle would duplicate that work.
- The controller had run on a Linux/systemd host. Its death followed its move onto a laptop.
- Restoring it onto a systemd Linux host was rejected as the default but is documented below
  as the fallback.

## What was done

Order mattered: nodes were quiesced before any controller-side state was removed (see
Finding 1).

| Step | Result |
|---|---|
| Baseline | Classic-fleet admission figures, plugin config hashes and modes, and three read-only preconditions captured before any change |
| Forensics | About 35 MB age-encrypted bundle (crash dump, corrupt durable store, controller config, ownership journal, deployed build identity) kept on the Unraid CI host under `/mnt/cache/runner/src/decommission-evidence/`. The 47 MB of controller logs were deliberately not captured. |
| Teardown | Every node unit stopped, disabled and masked on node hosts A and B, including B's second identity. Unit files preserved in `/etc/systemd/system.decommissioned-20260910/`; `/opt/ci-runner-farm` renamed `*.DECOMMISSIONED-20260910`. The resurrection User Script on the Unraid CI host was disabled. On the laptop, the controller and node launchers were renamed and de-executed, and stale launchd enable-overrides for the controller and session watchdog were set to disabled. |
| GitHub | 0 owned scale-set records and 0 offline runners, both before and after teardown. Nothing was deleted, and nothing needed to be. |
| Credential | The controller's copy of the GitHub token was deleted from the laptop. The token was **not** revoked, because it is the same token the live classic fleet uses. |
| Unraid CI host | The 12 GB distributed-node tree was removed after taking ZFS snapshot `cache/appdata@pre-crf-decommission-20260910`. |
| PKI | All 7 private keys destroyed on the issuing host: the CA key, the controller leaf key, and a retained copy of every node key. Public certificates archived. |

## Findings worth keeping

1. **The deployed nodes came from this repository and predate the reconnect fix.** Node
   build info reported release 1.13.4 (`chore(main): release 1.13.4`, 2026-08-25). That
   predates `fix: re-register nodes after controller state loss`, so the deployed `crf-node`
   treats `unknown_placement` and `unknown_command` as fatal. It would crash-loop and burn a
   node generation per restart. `main` is fixed; the deployed binaries were not. The
   controller did **not** come from this tree: this repository contains no DETS, and its
   durable store is `placement_state_store.ex` (`@schema_version 3`).
2. **The issuing host kept every node's private key.** Destroying keys on the nodes alone
   would have left all of them recoverable from the controller's TLS directory.
3. **One node host can carry more than one node identity.** Node host B ran two node units.
   Stopping only "the" node unit would have left one running.
4. **On Unraid, resurrection lives on flash.** The root filesystem is rebuilt from flash at
   boot, so enumerating `/boot/config/go`, `/boot/config/plugins/`, User Scripts and cron is
   exhaustive. That enumeration found a User Script scheduled **At Startup of Array** that
   runs `service.sh start`. Verifying the teardown by restarting the array, as was once
   proposed, would have taken the live fleet down and resurrected the node it was meant to
   prove dead.
5. **Classic resource accounting did not filter by backend.** A single foreign container row
   could charge the whole CPU budget and silently stop classic scale-up. This is fixed by
   `fix(resources): stop foreign backends consuming the classic budget`.

## Execution pitfalls, for whoever does this next

- The remote login shells were zsh, which does not word-split an unquoted `$VAR`. So
  `systemctl stop $UNITS` received one bogus unit name and did nothing, and a verification
  loop with the same bug reported success. Use `ssh host 'bash -s' <<'EOF'` with bash arrays.
  Verify by an independent signal such as a process count, not by the code path that
  performed the action.
- `systemctl mask` refuses when a real unit file exists in `/etc/systemd/system`. Move the
  file aside first.
- macOS ships `openrsync`, which does not support `--append-verify`.
- A checksum comparison in which both sides fail to empty strings compares equal. Guard every
  input with `test -s` and a non-empty check.
- `shred` and `rm -P` do not guarantee an overwrite on ZFS or APFS copy-on-write storage.

## The classic fleet was not disturbed

Across the whole teardown window, there were zero classic containers exiting non-zero.
Admissible CPU never reached 0, the plugin configuration files stayed unchanged (mode 600),
and the runner count changed only through normal autoscaling.

## Residual items (not acted on; owner decision)

- Node host A's root pool is ZFS with about 9,800 snapshots. The destroyed node keys are
  probably recoverable from them.
- Node host B is WSL without Windows interop, so Windows-side scheduled tasks and services
  were not verified.
- Snapshot `cache/appdata@pre-crf-decommission-20260910` (about 11.5 GB) is the rollback net.
  Destroy it after a cooling-off period. To restore, copy individual paths out of
  `/mnt/cache/appdata/.zfs/snapshot/pre-crf-decommission-20260910/`. Do **not** run
  `zfs rollback`: it would revert all of `cache/appdata`.
- Inert binaries remain in the controller laptop's `~/.ci-runner-farm/bin`.
- Git history still contains the tailnet identifiers that were scrubbed from HEAD in
  `chore: scrub leaked tailnet identifiers and guard against recurrence`.

## Restore (fallback; not recommended)

The `my-core-plugs` port is the intended destination. If this plane must come back anyway:

1. Host the controller on a persistent systemd Linux host, not on Unraid and not on a laptop.
2. Reissue the PKI in full, because every private key has been destroyed: issue a new CA, a
   controller leaf and node leaves. `packaging/distributed/admin/crf-peer-admin` manages the
   fingerprint allowlist. No PKI-issuing script exists in this repository.
3. Rebuild and verify the bundle for the target runtime with
   `scripts/build-distributed-bundle.sh` and `scripts/verify-distributed-bundle.sh`. The dead
   controller ran Erlang/OTP 28.
4. **Wipe node placement state and generations before reconnecting.** The controller was dead
   long enough for its replay tombstones to expire, so resuming old placement state is a
   double-execution hazard, not a clean resume.
5. Deploy nodes from a release that includes the reconnect fix.
6. Reinstall from a fresh, verified bundle. Do not reuse the preserved
   `/etc/systemd/system.decommissioned-20260910/` units or the
   `/opt/ci-runner-farm.DECOMMISSIONED-20260910` binaries.
7. Re-enable the User Script on the Unraid CI host only if a node is deliberately redeployed
   there.

## Issue #4

The scale-set control plane that issue #4 targets is now decommissioned. The `my-core-plugs`
port's placement design structurally addresses several of its defects: consumed-runner
reconciliation, supervisor liveness and health, and the compatibility/evidence lifecycle.
Four have no counterpart there: the prewarm revision domain, per-pool circuit breakers,
cold-start concurrency, and structured recovery outcomes. Recommendation: close what the port
resolves, migrate the rest to `my-core-plugs`, and re-target any genuine classic-fleet defects
at the classic plugin. This record does not action that.
