# SSH Device Runner Deployment Implementation Plan

> **For implementors:** Use the repository's current execution workflow to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe Unraid WebUI workflow that deploys or upgrades the distributed Linux runner node to literal devices discovered from root's SSH config.

**Architecture:** A fixed-command shell helper owns SSH discovery, remote probing, verified bundle selection, enrollment-profile validation, and asynchronous deployment. The existing CSRF-guarded PHP endpoint exposes typed JSON actions, while the Fleet page renders discovery and operation state without accepting arbitrary hosts, paths, SSH options, or commands. Deployment reuses the existing atomic bundle installer and requires controller-authorized mTLS material to exist before the UI enables the action.

**Tech Stack:** Bash 5, OpenSSH (`ssh -G`, `ssh`), PHP 8, Unraid Dynamix `.page` JavaScript/CSS, Node.js VM behavior tests, OpenSSL/signature verification, existing distributed Linux tarball/install.sh and mTLS node service.

**Spec:** `docs/distributed-runner-farm/ssh-device-deployment-spec.md`

## Global Constraints

- Linux/systemd SSH targets only in this slice; Windows targets are inventoried as unsupported.
- Use only literal aliases from `/root/.ssh/config`; skip wildcard, negated, `Match`, and dynamic entries.
- Browser input is limited to an inventoried alias, protocol-valid node ID, and inventoried bundle SHA-256.
- SSH must use `BatchMode=yes`, `StrictHostKeyChecking=yes`, and bounded timeouts; never write SSH config or known-hosts.
- Bundles and enrollment profiles live under cache-backed private state, never `/boot`.
- Never expose or log `node.env`, private keys, certificate bytes, GitHub credentials, or JIT material.
- Do not issue certificates or mutate controller peer authorization in this feature.
- Preserve the existing local Unraid backend and distributed status behavior.
- Trust only root-owned, non-group/world-writable SSH configuration and included files; reject unsafe effective proxy, local-command, forwarding, canonicalization, and remote-command options.
- Require a root-owned pinned release-signing key and signed manifest; self-declared checksums are integrity evidence, not provenance.
- Bound every subprocess, remote phase, archive, operation record, alias inventory, worker count, and polling loop.
- Permit at most two deployment workers globally and one mutating operation per alias.
- Treat connection proof as a separate observation contract; absence of an authoritative controller projection is `connection_unverifiable`.

## Engineering review decisions

The architecture, simplicity, security, and performance review is binding on
every task below. Implementers must preserve these decisions even where an
older step uses shorter wording:

1. The helper protocol is schema version 1 with exactly `list`, `probe`,
   `artifacts`, `deploy`, and `status`. PHP exposes a dedicated
   `ssh-deploy-status`; generic scale-set operation lookup is never reused.
2. Operation records use separate `phase`, terminal `state`, and stable `code`.
   Terminal states are `succeeded`, `failed`, `interrupted`, and `timed_out`.
3. Before returning `queued`, deploy re-resolves/re-probes the target and copies
   revalidated bundle/enrollment inputs into a root-owned mode-0700 immutable
   per-operation snapshot. Workers never reopen mutable source paths.
4. Worker ownership uses a global two-slot semaphore, per-alias `flock`, and a
   durable identity record containing PID, `/proc` start time, session/PGID,
   heartbeat, launch token, and deadline. Start/status reconcile dead or reused
   identities and terminalize abandoned work; terminal records are pruned by a
   documented age/count bound.
5. Every SSH/SCP/remote phase has `timeout`, `ServerAliveInterval=5`,
   `ServerAliveCountMax=3`, and `ConnectionAttempts=1`; the whole operation has
   a 15-minute deadline with TERM then KILL cleanup.
6. Installation is a transaction across `current`, systemd units, enrollment
   configuration, daemon reload, enablement, and running state. Validate staged
   configuration as the service user before activation; restore every captured
   prior artifact and service state on failure after each mutation boundary.
7. Idempotency includes alias, node ID, bundle SHA, non-secret enrollment/config
   fingerprint, and desired service state. Matching binaries may skip copy but
   never skip configuration/service reconciliation.
8. Enrollment validation proves key/certificate match, CA chain, validity,
   client-auth EKU, fingerprint, and configured node binding. Remote directories
   are root-owned `0750`; credentials are root:`ci-runner-farm` `0640` and are
   validated by running the node config check as `ci-runner-farm`.
9. Bundle validation uses `openssl dgst -sha256 -verify` with the pinned
   root-owned key at `/usr/local/emhttp/plugins/ci-runner-farm/keys/distributed-release.pem`
   and a detached manifest signature. The manifest binds repository, version,
   platform, and SHA. Reject compressed archives over 1 GiB, expanded content
   over 2 GiB, more than 4096 members, members over 1 GiB, paths over 255 bytes,
   ratios over 20:1, sparse/special files, and escaping symlinks. Installed and release-time
   verifiers share code or consume the same positive/adversarial fixture corpus.
10. Connection success captures controller instance, projection timestamp,
    existing node generation, and certificate fingerprint before deployment;
    it requires the expected controller and a post-start observation with a
    strictly newer authenticated generation. Otherwise return
    `installed_not_connected` or `connection_unverifiable` without false success.
11. CSRF is necessary but insufficient: PHP actions require
    `($_SERVER['REMOTE_USER'] ?? '') === 'root'` and append secret-free events to
    root-owned mode-0600 `${RUNDIR}/audit/ssh-deploy.jsonl`, rotating at 10 MiB
    with one prior file.
12. UI requests carry a monotonically increasing epoch, abort/ignore late
    probe/artifact/status responses, prevent overlapping polls, pause while the
    document is hidden, and back off from 1s to 2s/5s for long phases.
13. V1 intentionally defers Windows deployment, certificate issuance,
    controller peer mutation, batch rollout, automatic downloads, host-key
    enrollment, scheduled upgrades, rich timelines, and a dedicated daemon.
    Unsupported/deferrable work is documented rather than represented by inert
    abstractions or placeholder UI.

---

## File map

- `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`: installed dispatcher and only SSH execution boundary, internally layered into inventory, probe, artifact, operation, transaction, and observation functions.
- `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`: validates WebUI requests and calls only fixed helper actions.
- `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page`: Deploy Node drawer, confirmation, polling, and fleet-connection result.
- `scripts/verify-distributed-artifact.sh`: shared packageable verifier used by release and WebUI deployment paths.
- `tests/ssh-device-deploy.sh`: focused command-boundary tests with fake SSH plus timeout, concurrency, rollback, and recovery cases.
- `tests/distributed-artifact-verifier.sh`: positive/adversarial verifier parity, archive-bound, signature, and enrollment-crypto fixtures.
- `tests/php-actions.sh`: endpoint allowlist and injection-boundary assertions.
- `tests/fleet-behavior.js`: drawer state-machine and duplicate-submit behavior.
- `tests/ui-js.sh`, `tests/final-release-gate.sh`, `deploy.sh`, `build-plg.sh`: packaging and gate integration.
- `docs/distributed-runner-farm/service-packaging.md`, `docs/distributed-runner-farm/README.md`: operator storage, authorization prerequisite, and UI workflow.

### Task 1: Trusted SSH alias inventory and resolution

**Files:**
- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`
- Create: `tests/ssh-device-deploy.sh`

**Interfaces:**
- Consumes: `SSH_CONFIG=${SSH_CONFIG:-/root/.ssh/config}`, `CACHE_ROOT`, and `RUNDIR` from `runner-farm.sh` conventions.
- Produces: `ssh_deploy_main list`; one JSON object on stdout and diagnostics on stderr.
- Produces list schema: `{"schema_version":1,"devices":[{"alias":"dookie","hostname":"dookie.example","user":"root","port":22}]}`.

- [ ] **Step 1: Write failing alias-inventory tests**

  Add fixtures containing literal aliases, multiple aliases, `Host *`, `Host !blocked`, multiple `Match`/later `Host` sections, safe and unsafe `Include` files, duplicates, metacharacters, and symlinks. Assert only unique literal aliases matching `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$` appear, sorted bytewise and capped at 200. Require root ownership/non-writable ancestry and fail closed on unsafe effective proxy, local-command, forwarding, canonicalization, or remote-command settings.

  ```bash
  SSH_CONFIG="$fixture/config" bash "$HELPER" list >"$actual"
  jq -e '.schema_version == 1 and [.devices[].alias] == ["dookie","squirts"]' "$actual"
  ! SSH_CONFIG="$fixture/config-link" bash "$HELPER" list
  ```

- [ ] **Step 2: Run the inventory test and verify failure**

  Run: `bash tests/ssh-device-deploy.sh inventory`

  Expected: FAIL because `runner-ssh-deploy.sh` does not exist.

- [ ] **Step 3: Implement strict inventory and resolved display fields**

  Implement `ssh_config_require`, bounded include expansion, `ssh_aliases`, `ssh_resolve`, `ssh_effective_policy_safe`, `json_string`, and the dispatcher. Continue parsing top-level `Host` blocks after `Match`; reject tokens containing `*`, `?`, `!`, or invalid characters. Resolve lazily for the selected/visible alias with `ssh -G`, accept only hostname, user, and canonical numeric port, and reject rather than expose unsupported effective options.

  ```bash
  ssh_alias_valid() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]]; }
  ssh_base=(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o StrictHostKeyChecking=yes -o PermitLocalCommand=no -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes -o ConnectionAttempts=1 -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 --)
  ```

- [ ] **Step 4: Run inventory/resolution tests and commit the independently reviewable unit**

  Run: `bash tests/ssh-device-deploy.sh inventory && bash -n src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: inventory trusted SSH runner targets"
  ```

### Task 2: Bounded remote capability probe

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`
- Modify: `tests/ssh-device-deploy.sh`

**Interfaces:**
- Consumes: one alias returned by Task 1.
- Produces: `ssh_deploy_main probe ALIAS` with the probe schema defined below.
- Produces probe schema: `{"schema_version":1,"alias":"dookie","reachable":true,"supported":true,"os_id":"ubuntu","os_version":"26.04","arch":"x86_64","systemd":true,"privilege":"root","installed_version":"1.10.0","service_state":"active"}`.

- [ ] **Step 1: Write failing probe matrix tests**

  Fake `ssh` by alias and assert typed results for unknown host key, timeout, Linux/systemd/root, Linux/systemd/`sudo -n`, Windows, no systemd, and already-installed service. Assert the probe script is a constant and the alias remains a separate argv element.

  ```bash
  SSH_BIN="$fake_bin/ssh" bash "$HELPER" probe dookie | jq -e '.supported and .privilege == "root"'
  SSH_BIN="$fake_bin/ssh" bash "$HELPER" probe steamy | jq -e '.supported == false and .unsupported_code == "windows_target"'
  ```

- [ ] **Step 2: Implement the bounded fixed probe**

  Execute one constant POSIX probe through `timeout 20s ssh ... "$alias" -- sh -s`, cap captured stdout/stderr at 64 KiB, and require schema keys for OS, architecture, systemd, privilege, current build, configuration fingerprint, and service state. Force `LC_ALL=C`; map only tightly allowlisted exit-255 text and otherwise return generic `ssh_failed`. Classification never changes security behavior.

- [ ] **Step 3: Run focused tests and commit**

  Run: `bash tests/ssh-device-deploy.sh inventory && bash tests/ssh-device-deploy.sh probe && bash -n src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`

  Expected: all print `OK` and exit 0.

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: probe SSH runner targets"
  ```

### Task 3: Signed artifact and cryptographic enrollment inventory

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`
- Modify: `tests/ssh-device-deploy.sh`

**Interfaces:**
- Consumes bundle root: `${CACHE_ROOT}/distributed-bundles/*.tar.gz`.
- Consumes enrollment root: `${CACHE_ROOT}/distributed-enrollment/<node_id>/{node.env,ca.crt,client.crt,client.key}`.
- Produces: `ssh_deploy_main artifacts ALIAS` using a recent server-side probe cache keyed by alias plus trusted SSH-config identity; it never trusts browser capability data or performs an unnecessary second handshake.
- Produces bundle identity: `{sha256,version,platform}` and enrollment identity `{node_id,fingerprint}`; filename and Git SHA are intentionally omitted from v1 UI.

- [ ] **Step 1: Write failing artifact-validation tests**

  Create a signed minimal tar fixture with `BUILD-INFO`, `SHA256SUMS`, executable `install.sh`, detached manifest signature, and test public key. Exercise the exact 1 GiB/2 GiB/4096/1 GiB/255-byte/20:1 boundaries plus invalid signature/repository, sparse/special/traversal/symlink entries, platform mismatch, unsafe ownership, key/cert mismatch, bad CA chain, dates, EKU, fingerprint/node binding, and a valid pair.

  ```bash
  CACHE_ROOT="$fixture/cache" bash "$HELPER" artifacts dookie | jq -e '
    .bundles[0].version == "1.10.0" and .enrollments == [{"node_id":"dookie"}]'
  ```

- [ ] **Step 2: Run artifact tests and verify failure**

  Run: `bash tests/ssh-device-deploy.sh artifacts`

  Expected: FAIL because the `artifacts` action is unknown.

- [ ] **Step 3: Extract and implement the shared verified inventory**

  Create `scripts/verify-distributed-artifact.sh` and call it from both paths. Verify the detached manifest with `openssl dgst -sha256 -verify`, then hashes, provenance, build/platform, exact numeric archive bounds, and enrollment crypto/identity. Cache successful metadata for 30 seconds in a mode-0600 atomic manifest keyed by `(device,inode,size,mtime_ns,outer_sha)`; reject non-unique SHA matches.

- [ ] **Step 4: Run focused tests and commit**

  Run: `bash tests/ssh-device-deploy.sh artifacts`

  Expected: `ssh-device-deploy artifacts: OK`.

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: validate remote deployment artifacts"
  ```

### Task 4: Namespaced operation lifecycle and recovery

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`
- Modify: `tests/ssh-device-deploy.sh`

**Interfaces:**
- Consumes: `ssh_deploy_main deploy ALIAS NODE_ID BUNDLE_SHA256` and `ssh_deploy_main status UUID`.
- Produces immediately: `{"ok":true,"operation_id":"<uuid>","phase":"queued"}`.
- Produces operation file `${RUNDIR}/operations/ssh-deploy-<uuid>.json` with `{schema_version,kind,operation_id,alias,node_id,bundle_sha256,enrollment_fingerprint,phase,state,code,message,installed_version,connected,worker,created_at,updated_at,deadline_at}`.
- Phases are exactly `queued`, `probing`, `snapshotting`, `copying`, `verifying`, `installing`, `configuring`, `starting`, `waiting_for_fleet`, `rollback`, `complete`; terminal state is separate.

- [ ] **Step 1: Write failing lifecycle/status/concurrency tests**

  Assert the dedicated status action reads only kind=`ssh-deploy` records; global concurrency is two with 32 queued records; every alias serializes; different node/SHA requests cannot race one host; dead/reused PID identity becomes `interrupted`; timeout becomes `timed_out`; locks release; reboot reconciliation works; terminal records prune at 200/30 days; matching binary with changed enrollment still reconciles; and PHP teardown cannot kill a correctly detached worker.

  ```bash
  reply="$(CACHE_ROOT="$cache" RUNDIR="$run" bash "$HELPER" deploy dookie dookie "$sha")"
  op="$(jq -r .operation_id <<<"$reply")"
  wait_for 'jq -e ".state != null"' "$run/operations/ssh-deploy-$op.json"
  jq -e '.state == "succeeded" and .phase == "complete"' "$run/operations/ssh-deploy-$op.json"
  ```

- [ ] **Step 2: Run deployment tests and verify failure**

  Run: `bash tests/ssh-device-deploy.sh deploy`

  Expected: FAIL because `deploy` is not implemented.

- [ ] **Step 3: Implement operation ownership and atomic state writes**

  Derive the idempotency key from alias/node/bundle/enrollment/config/service state. Use a two-slot global semaphore, per-alias `flock`, and atomic mode-0600 JSON. Persist worker PID/starttime/SID/PGID/token/heartbeat before returning. `status` validates owner, mode, regular-file type, UUID, kind, and schema, reconciles identity/deadline, and never searches the scale-set operation directory.

- [ ] **Step 4: Implement immutable input snapshot and bounded worker launch**

  Under the locks, re-resolve/re-probe target identity/platform/privilege/host key and revalidate every artifact. Copy already-open content into a private mode-0700 per-operation snapshot and bind its hashes to the record. Launch with `setsid`/closed stdio and a 15-minute deadline; trap TERM/EXIT, heartbeat, release locks, and terminalize exactly once.

- [ ] **Step 5: Run lifecycle tests and commit**

  Run: `bash tests/ssh-device-deploy.sh operation && bash tests/ssh-device-deploy.sh recovery && bash tests/ssh-device-deploy.sh concurrency`

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: supervise SSH deployment operations"
  ```

### Task 5: Single-session transactional remote activation

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`
- Modify: `tests/ssh-device-deploy.sh`

**Interfaces:**
- Consumes the immutable operation snapshot from Task 4.
- Produces one fixed privileged receiver transaction and terminal operation result.

- [ ] **Step 1: Write failing transfer and rollback-boundary tests**

  Stream one framed snapshot through one bounded SSH session. Test timeout/hang, remote disk exhaustion, checksum failure, installer switch failure, config copy failure, daemon-reload failure, enable failure, start failure, TERM/KILL, and cleanup. After every post-mutation failure assert the exact old symlink, unit bytes, configuration bytes/modes, enablement, and running state are restored.

- [ ] **Step 2: Implement the fixed receiver and transaction**

  The constant remote receiver creates its own root-owned mode-0700 temp dir, consumes the framed stream without returning a reusable path, verifies nonce/signature/hashes/bounds again, stages release/config, validates as `ci-runner-farm`, captures prior state, activates, and rolls back all captured state on failure. Wrap copy, verify, install, daemon reload, validation, and start in explicit phase timeouts with TERM/KILL cleanup.

- [ ] **Step 3: Run transaction tests and commit**

  Run: `bash tests/ssh-device-deploy.sh transaction && bash tests/ssh-device-deploy.sh rollback && bash tests/ssh-device-deploy.sh timeout`

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: activate remote runner nodes transactionally"
  ```

### Task 6: Authoritative connection observation

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh`
- Modify: `tests/ssh-device-deploy.sh`

**Interfaces:**
- Consumes a pre-deploy observation baseline and post-start projection snapshots.
- Produces codes `connected`, `installed_not_connected`, or `connection_unverifiable`.

- [ ] **Step 1: Write failing observation tests**

  Cover no projection capability, wrong controller instance, stale observation, same generation, same node ID with wrong certificate fingerprint, newer authenticated generation, and bounded wait timeout.

- [ ] **Step 2: Implement exact baseline predicate**

  Capture controller instance, observation timestamp, node generation, and certificate fingerprint before deployment. Mark connected only for the expected controller, exact node/fingerprint, observation after service start, and generation strictly greater than baseline. Poll the projection directly at a bounded five-second cadence rather than invoking the full distributed status pipeline.

- [ ] **Step 3: Run observation tests and commit**

  Run: `bash tests/ssh-device-deploy.sh observation`

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: verify remote node connection generations"
  ```

- [ ] **Step 4: Implement redacted completion**

  Record only stable codes and bounded messages. Never log raw SSH stderr, certificate content, environment, remote command output, or paths containing secrets.

- [ ] **Step 5: Run focused tests and commit**

  Run: `bash tests/ssh-device-deploy.sh deploy && bash tests/ssh-device-deploy.sh redaction`

  Expected: both print `OK`; fixtures prove secrets do not occur under `RUNDIR` or captured argv/logs.

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-ssh-deploy.sh tests/ssh-device-deploy.sh
  git commit -m "feat: redact SSH deployment results"
  ```

### Task 7: Administrator-authorized typed WebUI actions

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`
- Modify: `tests/php-actions.sh`

**Interfaces:**
- Produces POST actions: `ssh-devices-json`, `ssh-device-probe`, `ssh-deploy-artifacts`, `ssh-deploy-start`, `ssh-deploy-status`.
- Consumes `alias` (63 bytes), `node_id` (63 bytes), and `bundle_sha256` (64 lowercase hex) only on their required actions.
- Uses only dedicated `ssh-deploy-status`; helper operation IDs remain canonical UUIDs.

- [ ] **Step 1: Write failing endpoint allowlist tests**

  Assert CSRF plus administrator authorization, all actions, stable helper exit-code/HTTP mapping, valid schema/kind before echo, canonical error JSON for empty/malformed helper output, secret-free audit events, operation-store isolation, invalid payloads, and injected fields. Capture argv and prove only validated positional values arrive.

- [ ] **Step 2: Run PHP tests and verify failure**

  Run: `bash tests/php-actions.sh`

  Expected: FAIL because the new action cases are absent.

- [ ] **Step 3: Add the fixed helper boundary**

  Define the fixed helper path; require `REMOTE_USER=root`; validate alias/node/SHA/UUID; use `escapeshellarg`; validate response schema/action/kind before echo; return canonical JSON for all errors; append/rotate the exact bounded audit path; return 202 only after a durable worker identity record exists. Map stable helper codes to 400/403/404/409/429/500/504.

  ```php
  case 'ssh-device-probe':
    $alias = post_scalar('alias', 63, true, true);
    if (!is_string($alias) || !ssh_alias_valid($alias)) {
      emit_error(400, 'invalid_ssh_alias', 'select a discovered SSH alias');
      break;
    }
    [$out, $rc] = run_json(escapeshellarg($SSH_DEPLOY).' probe '.escapeshellarg($alias));
    $body = json_decode($out, true);
    if ($rc !== 0 || !is_array($body) || ($body['schema_version'] ?? null) !== 1 || ($body['alias'] ?? null) !== $alias) {
      emit_error($rc === 4 ? 404 : 500, 'ssh_probe_failed', 'SSH probe failed');
      break;
    }
    echo json_encode($body);
    break;
  ```

- [ ] **Step 4: Run PHP tests and commit**

  Run: `bash tests/php-actions.sh && php -l src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`

  Expected: `php-actions: OK` and `No syntax errors detected`.

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php tests/php-actions.sh
  git commit -m "feat: expose SSH node deployment actions"
  ```

### Task 8: Minimal Fleet Deploy Node drawer and operation state machine

**Files:**
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page`
- Modify: `tests/fleet-behavior.js`
- Modify: `tests/ui-js.sh`

**Interfaces:**
- Consumes the five PHP action schemas from Task 7 and `distributed-status-json` only for normal fleet rendering.
- Produces a small drawer controller with open/load/select/start/poll/render functions; rich timelines and a dedicated retry control are deferred.
- Maintains one `CRF_SSH_DEPLOY` object: `{open,loading,devices,selectedAlias,probe,artifacts,selectedNodeId,selectedBundleSha,operation,error}`.

- [ ] **Step 1: Write failing UI state tests**

  Assert empty/loading/unreachable/unsupported/no-artifact/no-enrollment/ready/current-phase/failure/installed-not-connected/connection-unverifiable/connected states; request-epoch handling for late probe/artifact/status responses; hidden-tab pause; 1/2/5-second backoff; in-flight and duplicate-submit suppression; close/reopen timer cleanup; and safe text rendering.

- [ ] **Step 2: Run JavaScript tests and verify failure**

  Run: `node tests/fleet-behavior.js`

  Expected: FAIL because `crfSshDeployRender` is missing.

- [ ] **Step 3: Add the responsive drawer markup and styling**

  Add a `Deploy node` button and responsive drawer with alias list, essential capability facts, compatible version/platform/SHA, enrollment node ID, confirmation, one current phase, result, and close control. Keep filename, Git SHA, rich timeline, and retry out of v1. Reuse existing controls and safe-area conventions.

- [ ] **Step 4: Implement discovery, probe, selection, and confirmation**

  Load aliases only when the drawer opens; probe only the selected alias; discard late responses when selection changes; enable deploy only when `probe.supported`, one compatible SHA, and one enrollment node ID are selected. The confirmation must repeat resolved host, node ID, version/platform, and "enable and start service".

- [ ] **Step 5: Implement start, polling, and fleet proof**

  Guard with request epoch plus pending/in-flight flags; POST only validated fields; poll dedicated status at one second for fast phases then two/five seconds, pause hidden tabs, and treat server terminal/deadline semantics as authoritative. Render connected, installed-not-connected, and connection-unverifiable directly from the operation result.

- [ ] **Step 6: Run UI tests and commit**

  Run: `node tests/fleet-behavior.js && bash tests/ui-js.sh`

  Expected: `fleet-behavior: OK` and `ui-js: OK`.

  ```bash
  git add src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page tests/fleet-behavior.js tests/ui-js.sh
  git commit -m "feat: add distributed node deployment drawer"
  ```

### Task 9: Package and gate the complete workflow

**Files:**
- Modify: `deploy.sh`
- Modify: `build-plg.sh`
- Modify: `tests/final-release-gate.sh`

**Interfaces:**
- Consumes executable helpers and test suites from Tasks 1-8.
- Produces a plugin package that installs both helpers with exact executable modes and verifies every runtime dependency (`bash`, `ssh`, `timeout`, `flock`, `setsid`, `tar`, `openssl`, `sha256sum`, JSON parser, signature verifier).

- [ ] **Step 1: Write failing package/gate assertions**

  Require explicit executable handling, dependency doctor coverage, shared-verifier parity, package extraction/modes, and every focused suite. Add stress cases for 200 aliases, 100 cached bundles, hung commands, archive bombs, concurrent distinct deploys, stale workers, each rollback boundary, stale projections, and five polling clients.

- [ ] **Step 2: Run package checks and verify failure**

  Run: `bash tests/ui-js.sh && bash tests/final-release-gate.sh`

  Expected: FAIL because packaging and the final gate do not include the helper.

- [ ] **Step 3: Wire packaging and raw deployment permissions**

  Add the helper to explicit executable-file handling in both `deploy.sh` and `build-plg.sh`; do not make every include file executable. Add `bash -n` and the behavioral test to `tests/final-release-gate.sh` before build/package verification.

- [ ] **Step 4: Run the proportional verification matrix**

  Run:

  ```bash
  bash tests/ssh-device-deploy.sh all
  bash tests/distributed-artifact-verifier.sh
  bash tests/php-actions.sh
  node tests/fleet-behavior.js
  bash tests/ui-js.sh
  bash tests/final-release-gate.sh
  ./build-plg.sh
  git diff --check
  ```

  Expected: every suite exits 0, the package builds, and `git diff --check` is silent.

- [ ] **Step 5: Commit packaging and gates**

  ```bash
  git add deploy.sh build-plg.sh tests/final-release-gate.sh scripts/verify-distributed-artifact.sh tests/distributed-artifact-verifier.sh
  git commit -m "test: gate SSH runner deployment"
  ```

### Task 10: Operator documentation and disposable end-to-end evidence

**Files:**
- Modify: `docs/distributed-runner-farm/service-packaging.md`
- Modify: `docs/distributed-runner-farm/README.md`

**Interfaces:**
- Documents the exact contracts implemented by Tasks 1-9; README links once to the operator document instead of duplicating it.

- [ ] **Step 1: Document operator preparation and failure boundaries**

  Document trusted SSH config/include ownership, known-host prerequisites, rejected proxy/local-command options, passwordless root or `sudo -n`, pinned signing key/staging authority, cache/enrollment files with exact ownership/modes and crypto requirements, controller authorization/projection prerequisite, platform matching, concurrency/deadlines, audit/retention, rollback, Windows unsupported state, and removal/rotation. Successful install without authoritative newer-generation proof is not connected proof.

- [ ] **Step 2: Perform a disposable SSH end-to-end smoke**

  Using a disposable Linux/systemd target and test CA/controller allowlist, verify trust-policy failures; signed bundle; enrollment crypto; deployment; service readability; authoritative newer generation; enrollment rotation with same binary; injected post-switch failures with full rollback; worker kill/recovery; total timeout; and cleanup. Capture only redacted identity/version/SHA/phase/service/generation evidence.

- [ ] **Step 3: Commit documentation and evidence references**

  ```bash
  git add docs/distributed-runner-farm/service-packaging.md docs/distributed-runner-farm/README.md
  git commit -m "docs: explain SSH runner deployment workflow"
  ```

## Self-review record

- Spec coverage: every scope, security constraint, UX state, and acceptance criterion maps to Tasks 1-10.
- Placeholder scan: no deferred implementation placeholders are present; unsupported Windows deployment is an explicit v1 boundary with visible UI behavior.
- Type consistency: helper/PHP actions include dedicated status; phase/state/code are separate; request fields, JSON keys, and UI outcome names match across producers and consumers.
- Review coverage: all 19 architecture, simplicity, security, and performance recommendations are implemented in the global decisions and Tasks 1-10; intentionally deferrable work is explicitly listed in Decision 13.

## Engineering review record

### Architecture

- Strengths: the authority direction remains Fleet UI -> administrator-guarded
  PHP -> fixed helper -> SSH target; GitHub credentials, certificate issuance,
  controller authorization, and placement authority do not move to workers.
- Critical corrections applied: dedicated status routing and authoritative
  connection observation.
- Lifecycle corrections applied: immutable operation snapshots, worker identity
  reconciliation, configuration-aware idempotency, and full activation rollback.

### Simplicity

- Inventory, probe, artifact validation, operation supervision, remote
  transaction, and connection proof are independently reviewable tasks.
- V1 removes rich timelines, retry UI, filename/Git-SHA display, repeated docs,
  client-owned terminal deadlines, Windows deployment, and batch rollout.
- One installed dispatcher remains, but its internal protocol boundaries and
  shared verifier prevent a second job framework or package-verifier dialect.

### Security

- Applied protections cover admin authorization, SSH config/include ownership,
  effective-option rejection, strict host keys, cryptographic enrollment,
  signed provenance, archive bounds, immutable staging, secret-free auditing,
  exact remote ownership, deploy-time reprobe, and single-session transfer.
- The plan never treats CSRF, a checksum, a textual node ID, or a matching
  binary version as sufficient authorization or identity proof.

### Performance

- Remote work has per-phase and total deadlines, keepalives, TERM/KILL cleanup,
  two global worker slots, and per-alias serialization.
- Alias inventory is capped; verified bundle metadata is cached by file identity;
  artifact selection reuses a server-side probe; projection polling is direct;
  UI polling backs off, pauses hidden tabs, and forbids overlap.
- Stress gates cover alias/bundle scale, archive bombs, concurrent distinct
  deploys, hung commands, stale workers, and multiple observing tabs.

### Failure modes

| Codepath | Production failure | Rescued | Tested | User sees | Logged |
|---|---|---:|---:|---|---:|
| Inventory | unsafe include or huge alias set | yes | yes | rejected/capped | yes |
| Probe | connected remote command hangs | yes | yes | `timed_out` | yes |
| Artifacts | bundle swap, bad signature, or tar bomb | yes | yes | stable rejection code | yes |
| Operation | worker dies or PID is reused | yes | yes | `interrupted` | yes |
| Transaction | config/start fails after symlink switch | yes | yes | rollback failure phase | yes |
| PHP | wrong operation store or malformed helper JSON | yes | yes | canonical HTTP error | yes |
| UI | stale response overwrites new selection | yes | yes | current selection preserved | no secret data |
| Connection proof | stale/same-generation node appears successful | yes | yes | unverifiable/disconnected | yes |
| Packaging | required Unraid command is absent | yes | yes | dependency doctor failure | yes |

No row is an unrescued, untested, silent critical gap.

### Not in scope

- Windows deployment: separate transport/installer transaction and test matrix.
- Certificate issuance/controller peer mutation: separate PKI authority workflow.
- Batch rollout, waves, and scheduled upgrades: unnecessary for single-target v1.
- Automatic download/build and host-key enrollment: separate supply-chain/trust UX.
- Dedicated deployment daemon and rich audit UI: operation files are sufficient
  after ownership, recovery, retention, and bounded audit records are implemented.

### Completion summary

| Category | Critical | High/important | Minor/deferred |
|---|---:|---:|---:|
| Architecture | 2 | 6 | 3 |
| Simplicity | 2 | 3 | 7 |
| Security | 0 | 12 | 1 |
| Performance | 4 | 5 | 2 |

All overlapping findings are represented by the 19 applied recommendations;
the counts above intentionally include cross-category duplicates from the four
independent reviews.
