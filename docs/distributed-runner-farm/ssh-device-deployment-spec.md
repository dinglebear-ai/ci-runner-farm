# SSH Device Deployment Specification

## Goal

Let an operator deploy or upgrade the distributed Linux runner node from the
Unraid plugin WebUI to explicit devices defined in root's OpenSSH config.

## Scope

- Discover at most 200 literal `Host` aliases from `/root/.ssh/config` and
  root-owned, non-group/world-writable `Include` files. Skip wildcard, negated,
  and dynamic aliases while continuing across later top-level `Host` blocks
  after `Match` sections.
- Resolve each alias with `ssh -G` and show only alias, hostname, user, port,
  reachability, OS, architecture, service state, and installed CRF version.
- Support Linux targets with systemd and passwordless root or `sudo -n`.
- Show Windows and unsupported Linux targets without offering deployment.
- Deploy a locally staged, signature- and checksum-verified distribution bundle whose
  `PLATFORM` and architecture exactly match remote `/etc/os-release` and
  `uname -m`.
- Require a pre-provisioned enrollment profile for the selected node ID. The
  profile contains `node.env`, CA certificate, client certificate, and client
  key under the plugin's cache-backed private state.
- Run deployment asynchronously, expose bounded redacted progress, install
  atomically through the bundle's existing `install.sh`, enable/start the node
  service only after configuration validation, and report the connected node
  through the existing authenticated fleet projection.

## Security and safety constraints

1. Never accept a hostname, SSH option, path, command, bundle path, or identity
   file from the browser. The browser submits only a discovered alias, a valid
   node ID, and the SHA-256 identity of an inventoried bundle.
2. SSH uses `BatchMode=yes`, `StrictHostKeyChecking=yes`,
   `PermitLocalCommand=no`, `RemoteCommand=none`, `RequestTTY=no`,
   `ClearAllForwardings=yes`, `ConnectionAttempts=1`, bounded server-alive
   settings, per-phase timeouts, and a total deployment deadline. The feature
   never uses `accept-new`, disables host-key checking, or writes SSH config.
   Effective `ProxyCommand`, `ProxyJump`, canonicalization, and hostname
   substitution are rejected unless a later spec explicitly supports and
   displays them.
3. Alias and node ID validation use `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$` and
   controller node IDs additionally use the existing protocol identifier rules.
4. Enrollment files and every ancestor must be root-owned, non-symlink, and
   non-writable by group/other inside the cache root. Inventory and deployment
   both verify key/certificate public-key equality, CA chain, validity dates,
   client-auth EKU, certificate fingerprint, and the configured node binding.
   Remote credentials are root:`ci-runner-farm` mode `0640` inside root-owned
   mode `0750` directories so the service can read but not replace them; their
   contents never enter JSON, logs, argv, audit records, or flash.
5. The versioned helper protocol accepts no general-purpose remote command. Its
   fixed actions are `list`, `probe`, `artifacts`, `deploy`, and `status`.
   Responses separate nonterminal `phase`, terminal `state`, and stable `code`.
6. A deployment is idempotent for `(alias, node_id, bundle_sha256,
   enrollment_fingerprint, desired_service_state)`. A second
   request observes the existing operation or reports the already-installed
   release while still reconciling configuration and service health.
7. Deployment stages and validates immutable per-operation snapshots before
   returning `queued`. Activation records the prior symlink, unit files,
   configuration, enablement, and running state. Any failure after mutation
   restores all prior artifacts, reloads systemd, and restores the prior service
   state. Temporary local/remote files and locks are removed with traps.
8. This feature does not issue certificates, mutate the controller peer
   allowlist, deploy the controller, or place GitHub credentials on nodes.
9. OpenSSL verifies a detached SHA-256 signature over the release manifest with
   the root-owned pinned public key at
   `/usr/local/emhttp/plugins/ci-runner-farm/keys/distributed-release.pem`. The manifest binds repository
   identity, version, platform, and bundle SHA before root execution. Archive
   compressed size is at most 1 GiB, expanded size at most 2 GiB, member count
   at most 4096, member size at most 1 GiB, path length at most 255 bytes, and
   compression ratio at most 20:1; sparse entries, special files, and escaping
   symlinks are rejected before extraction.
10. Only the authenticated Unraid root administrator (`REMOTE_USER=root`) may
    list, probe, or deploy. Audit
    records contain operator identity, alias, node ID, bundle SHA, enrollment
    fingerprint, operation ID, timestamps, and result, never credential bytes.
11. One global semaphore permits at most two deployment workers with at most 32
    queued records, and a per-alias
    lock serializes all mutation of a target regardless of node or bundle.
    Worker PID, start time, session identity, heartbeat, and launch token support
    safe interrupted-operation reconciliation. Retain at most 200 terminal
    records and no record older than 30 days. Rotate the root-owned mode-0600
    `${RUNDIR}/audit/ssh-deploy.jsonl` at 10 MiB, keeping one prior file.

## UX contract

The Fleet page adds a "Deploy node" action in the Distributed fleet panel. A
drawer lists configured SSH aliases with refresh/probe state. Selecting a
supported device requires choosing a compatible verified bundle and an existing
enrollment node ID. The confirmation names the alias, resolved host, node ID,
bundle version/platform, and that the service will be enabled and started.

The drawer uses a dedicated SSH status endpoint, backs polling off from one to
two and five seconds, pauses while hidden, and prevents overlapping requests.
It ends in one of five explicit states: installed and connected, installed but
not yet connected, connection unverifiable, failed with a redacted phase/code,
or unsupported. Connected requires the expected controller instance and an
authenticated projection observed after service start with a generation newer
than the captured pre-deployment baseline. Missing projection capability is
`connection_unverifiable`, never disconnected or success.

## Acceptance criteria

- Parser tests reject wildcard/negated aliases, option injection, duplicate
  ambiguity, unsafe `Include` ownership/modes, unsafe effective SSH options,
  symlinks, and unsafe config/enrollment paths; 200 aliases is a hard limit.
- Probe tests cover unreachable, unknown host key, Linux/systemd, Windows,
  architecture mismatch, missing sudo, and an already-installed node.
- Deployment tests prove signature/checksum enforcement, bounded archive
  expansion, cryptographic enrollment validation, exact platform selection,
  immutable snapshots, redaction, configuration-aware idempotency, global and
  per-target concurrency, timeout/interrupt recovery, full transactional
  rollback at every mutation boundary, private ownership/modes, cleanup, and
  service enable/start ordering.
- PHP tests prove CSRF and administrator authorization remain mandatory,
  operation kinds cannot cross stores, helper output is schema-validated, and
  arbitrary host/path/command inputs cannot reach the shell helper.
- Browser behavior tests cover empty, loading, unsupported, deploying, failed,
  installed-but-disconnected, connection-unverifiable, and connected states;
  request epochs, hidden-tab backoff, and duplicate-submit guards prevent stale
  or overlapping responses.
- The plugin package contains the executable helper and the final release gate
  proves required Unraid commands and runs shared-verifier parity, shell, PHP,
  JavaScript, hung-command, archive-bomb, concurrency, stale-worker, rollback,
  stale-projection, and multi-poller suites.
