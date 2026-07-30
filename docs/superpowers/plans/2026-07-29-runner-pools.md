# Runner Pools Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Do not use subagent-driven development.

**Goal:** Add first-class routed capacity pools so Rust, Python, and TypeScript GitHub Actions jobs can target independent runner capacity and no longer wait behind unrelated long-running builds.

**Architecture:** Preserve the existing single-fleet behavior as the default. Pool mode is an explicit desired-state controller driven by a strict serialized configuration, derived GitHub routing labels, and authoritative Docker metadata. One global mutation lock and one supervisor coordinate all pools; capacity, autoscale grace, manual scale overrides, lifecycle state, and status are pool-aware. Labels provide scheduling separation, not security isolation. Images, resources, caches, networks, GitHub scope, runner group, autoscale cadence, and image-update policy remain global in this release.

**Tech Stack:** Bash, Docker CLI, GitHub Actions REST API, PHP/Dynamix pages, vanilla JavaScript, Unraid UUI/Aurora styling, shell-based regression tests.

---

## Product contract

### Configuration

Add two keys to the engine defaults, `default.cfg`, and Settings `$defaults`:

```ini
RUNNER_MODE="single"
RUNNER_POOLS="rust|3|2|5|1;python|1|1|2|1;typescript|1|1|2|1"
```

`RUNNER_MODE` is exactly `single` or `pools`.

Each semicolon-separated pool record is:

```text
id | fixed-count | autoscale-min | autoscale-max | idle-buffer
```

`AUTOSCALE` remains a farm-wide switch:

- `AUTOSCALE=false`: every pool uses `fixed-count`.
- `AUTOSCALE=true`: every pool uses its own `min`, `max`, and `idle-buffer`.
- Mixed fixed/autoscale pools are out of scope.
- `AUTOSCALE_STEP`, `AUTOSCALE_INTERVAL`, and `AUTOSCALE_IDLE_GRACE` remain global.

The derived routing label is not editable:

```text
ci-pool-<id>
```

Examples:

```yaml
# Rust
runs-on: [self-hosted, ci-pool-rust]

# Python
runs-on: [self-hosted, ci-pool-python]

# TypeScript / Node
runs-on: [self-hosted, ci-pool-typescript]
```

Pool runners must not inherit the legacy `RUNNER_LABELS`. Otherwise a workflow that still requests `[self-hosted, unraid]` could consume reserved Python or TypeScript capacity. GitHub's default `self-hosted`, OS, and architecture labels remain present.

### Validation invariants

The canonical Bash parser validates the entire immutable configuration snapshot before any Docker or GitHub mutation:

- serialized value is at most 4096 bytes;
- pool mode contains 1–8 records;
- every record has exactly five non-empty fields;
- id matches `^[a-z][a-z0-9-]{0,22}[a-z0-9]$`, with one-character ids also allowed;
- ids are unique;
- all numeric fields are canonical base-10 integers with no sign, whitespace, exponent, leading shell syntax, or overflow;
- every numeric value is between 1 and the hard maximum of 64;
- `min <= max`;
- `idle-buffer <= max`;
- sum of fixed counts is at most 64;
- sum of maxima is at most 64;
- pool mode requires `GH_SCOPE=org`;
- `GH_OWNER` and each repository identifier are validated before use in API paths;
- invalid `RUNNER_MODE=pools` never falls back to single mode and never means zero desired runners.

The Settings UI gives immediate row-level feedback and performs server-backed validation before native form submission. Every backend mutation validates again because browser validation can be bypassed and the native Unraid writer persists the file before the reconciliation command runs.

On invalid persisted configuration:

- `status-json` remains available and returns valid JSON plus `config_error`;
- all mutations except emergency global Stop fail closed;
- existing containers and running jobs remain untouched;
- daemons do not reinterpret, retire, start, or scale runners;
- Fleet shows the exact correction and disables affected controls.

### Compatibility contract

When `RUNNER_MODE=single` or the key is absent:

- existing scalar settings remain authoritative;
- names remain `ci-runner-N`;
- `LABELS` remains the exact legacy `RUNNER_LABELS`;
- the existing config fingerprint input and order remain unchanged;
- existing runners are not marked stale merely because the plugin was upgraded;
- `scale N` and the current Fleet control retain their behavior;
- status includes a synthetic `default` pool without breaking aggregate consumers.

The saved pool definition remains present while single mode is active so an operator can switch modes without losing their pool draft. Pool values have no runtime effect in single mode.

### Pool identity and metadata

Pool-mode names are deterministic:

```text
ci-runner-rust-1
ci-runner-python-1
ci-runner-typescript-1
```

Names are presentation and collision keys. Docker labels are the authority:

```text
net.unraid.ci-runner-farm.managed=true
net.unraid.ci-runner-farm.pool=rust
net.unraid.ci-runner-farm.pool-index=1
net.unraid.ci-runner-farm.routing-label=ci-pool-rust
net.unraid.ci-runner-farm.scope-target=org:dinglebear-ai
net.unraid.ci-runner-farm.identity-version=1
net.unraid.ci-runner-farm.confgen=<pool-and-target-specific fingerprint>
```

Every targeted action must verify the managed label, valid pool/index metadata, and canonical name reconstructed from that metadata. A matching name alone never authorizes log access, recycle, removal, or cache deletion. Legacy `ci-runner-N` containers are accepted only when they carry the managed label.

The stamped `scope-target` is used for deregistration. It is never recomputed from a changed `GH_REPOS`, mode, or pool list. A conservative legacy fallback is allowed only for an old single-mode runner whose repository mapping is unambiguous.

### Desired/actual state machine

Each managed container is classified from one batched inventory snapshot:

- `desired-current`: its desired identity exists and its fingerprint matches;
- `desired-stale`: its desired identity exists but its baked fingerprint differs;
- `retiring`: its pool/mode identity is no longer desired;
- `invalid-managed`: managed label is present but required metadata is malformed or inconsistent.

Rules:

- only desired identities may be created or recreated;
- stale runners drain and are recreated one at a time;
- retiring runners drain and are removed without replacement;
- invalid-managed runners remain visible and untouched until an explicit operator action;
- legacy containers become retiring when entering pool mode;
- pool containers become retiring when returning to single mode;
- pool rename is remove-plus-add;
- after releasing and reacquiring the mutation lock, desired state is reloaded and identity is revalidated before any replacement;
- image rollout, stopped-runner recovery, dead-runner reap, manual recycle, Start, boot autostart, and Docker-start recovery use the same identity rules.

Migration capacity is bounded:

- live managed containers, including stale and retiring runners, never exceed 64;
- the transition ceiling is `max(actual-at-transition-start, new configured baseline)`, also capped at 64;
- obsolete idle capacity is replaced one-for-one;
- if obsolete runners are busy and the ceiling is reached, new capacity waits and status reports `blocked_capacity`;
- code deployment never enables pool mode automatically.

### Graceful and forced removal

Graceful paths are autoscale shrink, fixed scale-down, deleted-pool retirement, and config/image reconciliation:

1. Observe the runner as explicitly `idle`; `starting`, `busy`, `error`, and `unknown` are not removable.
2. Resolve the runner ID from one cached GitHub inventory for its stamped scope.
3. Request GitHub deletion.
4. Stop/remove the container only when deletion succeeds or GitHub returns not found.
5. Treat 403, 422, timeout, rate-limit, and unknown responses as retryable; leave the container intact and surface the reason.

This closes the race where GitHub assigns a job after a local idle check.

Forced paths remain separate:

- global Stop may tear down managed containers;
- user-confirmed busy Recycle may interrupt the selected runner;
- forced paths are explicit in logs and UI.

Before any per-runner `rm -rf`, revalidate and canonicalize `CACHE_ROOT`, validate the canonical runner name, use `--`, and refuse cleanup when the path is ambiguous. Removing a container may proceed while preserving its cache directory if the root cannot be proven safe.

### Scaling contract

Fixed mode:

- Fleet says **Scale to**;
- scale-up and safe scale-down target one pool;
- busy runners above the target are marked for retirement and finish first;
- the response reports actual, target, and pending drain instead of false success;
- manual targets are runtime overrides stored under tmpfs `RUNDIR`;
- overrides survive ordinary supervisor ticks, reset on Start/restart/config Apply/mode or pool-record change, and are not written to flash;
- status exposes configured and effective targets.

Autoscale mode:

- Fleet says **Scale up to**;
- manual actions only accept a target greater than the pool's live count and at or below that pool's maximum;
- manual growth resets only that pool's idle-grace counter;
- the autoscaler may reclaim the added idle capacity later;
- minimum is always at least one because this release has no label-aware demand signal.

One supervisor tick:

1. validates one immutable config snapshot;
2. builds one fleet inventory;
3. reaps dead/unhealthy members without counting them as idle;
4. counts `idle + starting` as warm/pending capacity so slow registration cannot cause runaway growth;
5. restores every deficient pool floor;
6. grows only the pool below its idle buffer;
7. shrinks only explicit idle runners from the same pool after that pool's grace;
8. resumes retiring runners even when autoscale is off;
9. processes later pools even if one pool's GitHub or Docker operation fails.

Use pool-keyed state under `RUNDIR`, including a pool configuration generation:

```text
autoscale.<pool>.<generation>.state
scale-override.<pool>.<generation>
```

Remove obsolete runtime state when a pool is removed or renamed.

### Performance and locking invariants

- One global fleet mutation lock remains authoritative.
- Detached daemons close inherited lock file descriptors before starting.
- Never hold the mutation lock while draining or waiting on long GitHub/Docker observations.
- Fetch/preflight outside the lock, acquire it for a short revalidation and one mutation, then release it.
- One pool failure does not abort later pools.
- A daemon tick performs at most eight additions and two graceful removals.
- One inventory snapshot per status/autoscale/reconcile pass:
  - at most one `docker ps`;
  - one batched `docker inspect`;
  - no per-pool `docker ps`/`inspect`;
  - no GitHub calls, `docker exec`, or `docker logs` on the status hot path.
- Parse batched output once into maps; do not repeatedly scan the full output per runner.
- Reuse a paginated GitHub name-to-ID inventory per stamped scope during a mutation batch.
- Reuse registration tokens per scope/batch while they remain valid.
- Bound health probes and provisioning work; a wedged runner cannot stall the entire tick.
- Status remains one visible request every five seconds, does not poll while hidden, and targets p95 below 500 ms at 64 runners.
- Per-tick state and logs remain in tmpfs `RUNDIR`; no autoscale writes to flash.

### Status contract

Preserve existing top-level aggregate fields and add pool data:

```json
{
  "mode": "pools",
  "config_error": "",
  "count": 5,
  "configured": 5,
  "autoscale_enabled": true,
  "autoscale_max": 9,
  "stale": 1,
  "retiring": 1,
  "blocked_capacity": 0,
  "pools": [
    {
      "id": "rust",
      "label": "ci-pool-rust",
      "configured": 3,
      "effective_target": 3,
      "count": 3,
      "up": 3,
      "busy": 2,
      "idle": 1,
      "starting": 0,
      "error": 0,
      "stale": 0,
      "retiring": 0,
      "min": 2,
      "max": 5,
      "idle_buffer": 1
    }
  ],
  "runners": [
    {
      "name": "ci-runner-rust-1",
      "pool": "rust",
      "routing_label": "ci-pool-rust",
      "scope_target": "org:dinglebear-ai"
    }
  ]
}
```

Compatibility meanings:

- `count`: all managed containers;
- `configured`: sum of fixed counts, or sum of autoscale minima when autoscale is enabled;
- `autoscale_max`: sum of per-pool maxima in pool mode;
- top-level `stale`: stale plus retiring, preserving the existing migration banner behavior;
- separate `retiring` and `blocked_capacity` fields add precision;
- single mode returns one `default` pool and `runner.pool="default"`;
- Dashboard/nchan remains aggregate-only and never publishes pool, repository, branch, or job detail.

All shell strings are JSON-escaped. The DOM uses `textContent` where possible, `crfEsc` for HTML, and `CSS.escape` for selector components. Config errors, Docker labels, and runner metadata are treated as untrusted. Tokens never appear in status, errors, or logs.

### UI contract

Settings:

- mode selector: **Single fleet** / **Runner pools**;
- legacy count/labels controls remain stored and visible only in single mode;
- repeatable pool rows for id, fixed, min, max, idle buffer;
- read-only derived label and copyable `runs-on` example;
- orange primary **Add pool** action and secondary Remove actions;
- row errors plus an `aria-live="polite"` summary;
- warning that deleting/renaming a pool drains runners and workflows using the old label will queue;
- routing warning: pools reserve scheduling capacity but are not security boundaries;
- org/default-group warning when privileged DinD or Docker socket access is enabled;
- memory advisory uses the aggregate pool maxima and transition envelope;
- inactive values remain enabled so Apply does not erase them.

Fleet:

- retain aggregate cards and global Start/Stop/Restart/Validate actions;
- rename queue presentation to **Queued workflow runs** and state that it spans configured repositories;
- add compact pool summary/control cards above one shared runner grid;
- do not duplicate runner tables, log drawers, or status intervals per pool;
- add a pool badge/column to the existing runner grid;
- hide the aggregate scale control in pool mode;
- per-pool primary orange Scale button;
- `Scale to` in fixed mode and `Scale up to` in autoscale mode;
- initialize from the live count and never overwrite a focused/dirty input;
- disable only the pending pool action and use `aria-busy`;
- preserve open drawers and update steady-state DOM in place;
- if refresh is requested during an in-flight poll, set `refreshAgain` and immediately poll once more in `finally`;
- invalid config disables mutations except Stop;
- retiring and capacity-blocked states are visible.

### Routing, security, and queue limitations

GitHub assigns a job only to an online idle runner matching every requested label. Unique `ci-pool-*` labels partition eligible capacity; the plugin does not create or prioritize GitHub queues.

This release deliberately does not implement per-pool queue depth:

- the current endpoint counts queued workflow runs, not jobs;
- an in-progress run can still contain queued jobs;
- job labels require per-run job enumeration;
- there is no documented organization-wide queued-jobs-by-label REST endpoint;
- exact queue-driven scaling belongs in a later signed `workflow_job` webhook state machine.

Runner groups remain a single global access-control boundary. Pools share a host kernel, runner image, privileged DinD setting, network policy, and writable dependency caches. They are not trust boundaries. Use runner-group repository restrictions and trusted workflows; use VMs, separate hosts, or stronger isolation for hostile code.

### Explicit non-goals

- per-pool images or toolchains;
- per-pool CPU, memory, caches, networks, or image-update cadence;
- per-pool runner-group creation or policy management;
- mixed fixed/autoscale pools;
- scale-to-zero;
- arbitrary extra routing labels;
- per-pool GitHub queue estimates;
- webhook-driven demand;
- automatic workflow rewriting in sibling repositories;
- cross-host scheduling;
- automatic orphan cache garbage collection.

## Task 1: Add the canonical pool parser and configuration contract

**Files:**

- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page`
- Create: `tests/runner-pools.sh`
- Modify: `tests/config-parity.sh`

**Step 1: Write failing parser tests**

Cover:

- the three-pool example;
- derived labels;
- absent keys and exact legacy behavior;
- invalid mode and empty pool mode;
- CR/LF, whitespace, quotes, glob, traversal, delimiter, uppercase, leading/trailing hyphen;
- missing/extra fields;
- noncanonical, negative, exponent, and huge integers;
- duplicate ids;
- more than eight pools;
- `min > max`, `idle > max`;
- fixed and maximum aggregate overflow;
- pool mode with repo scope;
- no side effects on invalid configuration.

**Step 2: Run the tests and confirm they fail**

```bash
bash tests/runner-pools.sh
```

Expected: failure because parser functions and keys do not exist.

**Step 3: Implement pure parser helpers**

Required public helpers:

```bash
pool_config_validate MODE POOLS GH_SCOPE
pool_records
pool_record ID
pool_label ID
pool_configured_target ID
pool_effective_target ID
pool_state_generation ID
pool_mode_enabled
```

The helper must be safe to source in tests, perform no Docker/GitHub calls, use no `eval`, never source the web-written cfg, and emit actionable errors without secrets.

**Step 4: Wire defaults and safe loading**

Add `RUNNER_MODE` and `RUNNER_POOLS` to:

- engine defaults;
- `CFG_KEYS`;
- `default.cfg`;
- Settings `$defaults`;
- config parity expectations.

Keep the parser in a sourced include copied by existing package/deploy globs.

**Step 5: Run focused tests**

```bash
bash -n src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
bash -n src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
bash tests/runner-pools.sh
bash tests/config-parity.sh
```

**Step 6: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page \
  tests/runner-pools.sh tests/config-parity.sh
git commit -m "feat: define runner pool configuration"
```

## Task 2: Build one metadata-rich fleet inventory

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `tests/runner-pools.sh`

**Step 1: Add failing behavioral and call-count tests**

Stub Docker output for:

- legacy managed runners;
- valid pool runners;
- malformed/forged metadata;
- an unmanaged container with a valid-looking runner name;
- 64 runners across one and eight pools.

Assert:

- one `docker ps` and one batched `docker inspect` per inventory;
- no pool multiplied scans;
- authoritative pool/index/scope comes from metadata;
- legacy fallback occurs only for managed legacy names;
- invalid-managed containers are classified but never adopted.

**Step 2: Implement inventory helpers**

Required interface:

```bash
fleet_inventory_refresh
inventory_names [POOL]
inventory_field NAME FIELD
inventory_count [POOL]
inventory_state_counts POOL
runner_identity_validate NAME
runner_desired_class NAME
```

Parse batch output once into tmpfs-backed maps or one-pass records. Status, autoscale, reconciliation, scale, and lifecycle actions consume the same snapshot.

**Step 3: Preserve exact single-mode behavior**

Do not change legacy name generation, labels, or fingerprint input ordering. Add regression assertions that existing single-mode runners are not stale after the feature lands.

**Step 4: Verify**

```bash
bash tests/runner-pools.sh
bash tests/autoscale-controls.sh
```

**Step 5: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh tests/runner-pools.sh
git commit -m "refactor: inventory runners by pool metadata"
```

## Task 3: Stamp pool identity and exact GitHub scope

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `tests/runner-pools.sh`

**Step 1: Write failing construction tests**

Assert pool mode builds:

```text
ci-runner-rust-1
LABELS=ci-pool-rust
pool=rust
pool-index=1
routing-label=ci-pool-rust
scope-target=org:<owner>
identity-version=1
```

Assert:

- legacy construction is byte-for-byte compatible in relevant args;
- fingerprints include global baked settings, pool identity/label, exact stamped target, and schema version;
- fingerprints exclude fixed/min/max/idle and autoscale cadence;
- an unmanaged name collision fails visibly;
- lowest free pool-local index is selected.

**Step 2: Refactor construction paths**

Thread optional pool identity through the existing shared primitives rather than duplicating lifecycle implementations:

```bash
runner_name INDEX [POOL]
runner_scope_target INDEX [POOL]
crf_confgen INDEX [POOL] [SCOPE_TARGET]
build_args INDEX [POOL]
start_one INDEX [POOL]
```

Pool mode is org-only, so every pool runner stamps `org:<owner>`. Preserve legacy repo round-robin behavior for single mode.

**Step 3: Validate target ownership**

Before touching an existing name:

- verify managed label;
- verify pool/index metadata;
- reconstruct the canonical name;
- reject unmanaged collisions;
- reject invalid or forged scope metadata.

**Step 4: Verify**

```bash
bash tests/runner-pools.sh
bash tests/safe-paths.sh
```

**Step 5: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh tests/runner-pools.sh
git commit -m "feat: stamp pool runner identity"
```

## Task 4: Make GitHub registration and graceful removal batch-safe

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `tests/runner-pools.sh`

**Step 1: Add failing API boundary tests**

Cover:

- paginated name-to-ID inventory fetched once per scope/batch;
- registration token reused per scope/batch while valid;
- stored scope target used after owner/repository configuration changes;
- graceful delete success and 404 remove the container;
- 403, 422, timeout, and malformed responses retain it;
- a simulated assignment race does not interrupt the job;
- forced Stop and confirmed Recycle use an explicit force path;
- API headers include the current GitHub API version;
- errors never echo authorization values.

**Step 2: Implement scope caches**

Required interfaces:

```bash
github_scope_validate TARGET
github_runner_inventory TARGET
github_runner_id TARGET NAME
github_registration_token TARGET
deregister_runner_graceful NAME
remove_runner_force NAME
```

Fetch external state outside the fleet mutation lock. Reacquire, reload desired state, verify identity/state, perform one short mutation, and release.

**Step 3: Revalidate destructive cache paths**

Immediately before cleanup:

```bash
crf_safe_cache_root
runner_identity_validate "$name"
rm -rf -- "$safe_root/docker/$name"
```

If safety cannot be proven, preserve the directory and warn.

**Step 4: Verify**

```bash
bash tests/runner-pools.sh
bash tests/safe-paths.sh
```

**Step 5: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh \
  tests/runner-pools.sh tests/safe-paths.sh
git commit -m "fix: make runner retirement race safe"
```

## Task 5: Implement desired-state reconciliation and mode transitions

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `tests/runner-pools.sh`

**Step 1: Write failing transition tests**

Cover:

- single to pools;
- pools to single;
- removed pool;
- renamed pool as remove-plus-add;
- one changed pool does not stale another;
- busy retiring runner remains until idle;
- retirement resumes with autoscale off and after reboot;
- worker re-reads desired state after releasing the lock;
- image rollout cannot resurrect a removed pool;
- stopped-runner recovery cannot resurrect a removed pool;
- invalid-managed stays untouched;
- transition at 63/64 and 64/64 never exceeds the hard cap;
- new capacity waits when all obsolete capacity is busy;
- detached worker closes inherited lock descriptors;
- Stop terminates/neutralizes the reconcile worker.

**Step 2: Implement the four-state classifier**

Use the inventory and per-identity fingerprint to classify current, stale, retiring, and invalid-managed.

**Step 3: Implement bounded reconcile passes**

One pass:

1. validate snapshot;
2. build inventory;
3. remove at most one explicit-idle retiring runner through graceful deregistration;
4. create at most one missing desired identity within the transition ceiling;
5. recycle at most one explicit-idle stale runner;
6. report blocked/busy work;
7. schedule another pass until retirement completes, even in fixed mode.

Do not hold the lock while waiting for a runner to become idle. Do not resurrect a runner after a config change.

**Step 4: Integrate every lifecycle entrypoint**

Update:

- Start and boot autostart;
- Docker-start recovery;
- stopped runner recreation;
- dead/unhealthy reap;
- image update/recycle;
- config Apply drain;
- Stop/restart.

**Step 5: Verify**

```bash
bash tests/runner-pools.sh
bash tests/autoscale-controls.sh
```

**Step 6: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh tests/runner-pools.sh
git commit -m "feat: reconcile runner pool desired state"
```

## Task 6: Make fixed scaling and autoscaling independent per pool

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `tests/autoscale-controls.sh`
- Modify: `tests/runner-pools.sh`

**Step 1: Write failing scale tests**

Fixed mode:

- scales only the selected pool;
- uses the lowest free index to grow;
- removes highest-index explicit idle runners first;
- busy excess becomes pending drain;
- runtime override survives ticks;
- override resets on Apply/Start/restart/mode or record change.

Autoscale:

- busy Rust grows only Rust;
- independent grace files;
- every deficient pool gets evaluated;
- `starting` counts as pending warm capacity;
- only explicit idle shrinks;
- manual burst is add-only and bounded by that pool max;
- manual burst resets only that pool's grace;
- removed pool never regrows;
- aggregate live cap is honored;
- one pool failure does not abort another.

**Step 2: Refactor shared scaling primitives**

Required interfaces:

```bash
cmd_scale TARGET                         # single mode compatibility
cmd_scale POOL TARGET                    # pool mode
cmd_scale_internal POOL TARGET
pool_scale_down_idle POOL COUNT
pool_autoscale_tick POOL
autoscale_tick
```

The command dispatcher distinguishes two- and three-argument forms without adding separate scale policy implementations.

**Step 3: Add runtime override/state management**

All state is under `RUNDIR`, generation-keyed, atomically written, and deleted when obsolete.

**Step 4: Bound each tick**

Across all pools:

- maximum eight additions;
- maximum two graceful removals;
- round-robin starting pool so a consistently failing Rust pool cannot starve later pools.

**Step 5: Verify**

```bash
bash tests/autoscale-controls.sh
bash tests/runner-pools.sh
```

**Step 6: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh \
  tests/autoscale-controls.sh tests/runner-pools.sh
git commit -m "feat: scale runner pools independently"
```

## Task 7: Extend status JSON without regressing the hot path

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `tests/runner-pools.sh`

**Step 1: Write failing status tests**

Assert:

- valid JSON in single, pools, invalid-config, retiring, stale, and empty/stopped states;
- existing aggregate keys and meanings remain;
- `default` pool in single mode;
- pool and scope target on runner objects;
- configured/effective/live/busy/idle/starting/error/stale/retiring values;
- no per-pool queued field;
- hostile strings are JSON-escaped;
- no token values;
- one `docker ps` and one batched inspect at 64 runners/eight pools;
- zero GitHub, logs, or exec calls on status.

**Step 2: Build pool summaries from the shared inventory**

Do not call pool enumeration helpers that rescan Docker. Aggregate the already parsed records in one pass.

**Step 3: Preserve Dashboard privacy**

Keep Dashboard/nchan aggregate-only.

**Step 4: Verify**

```bash
bash tests/runner-pools.sh
```

Optionally benchmark the stubbed 64-runner path and retain a documented p95 target below 500 ms on the live host.

**Step 5: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh tests/runner-pools.sh
git commit -m "feat: report runner pool status"
```

## Task 8: Harden PHP actions for pool-aware targeting

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php`
- Create: `tests/php-actions.sh`
- Modify: `tests/config-parity.sh`

**Step 1: Write failing endpoint/static tests**

Cover:

- mutation requires POST and valid CSRF;
- scale accepts canonical decimal only;
- rejects missing, junk, negative, whitespace, exponent, and overflow;
- pool id shape and length;
- unknown pool rejected again by engine;
- target above per-pool max;
- runner log/recycle accept both name shapes syntactically;
- shell verifies metadata ownership;
- pool definition request capped at 4096 bytes;
- explicit HTTP errors for invalid requests;
- CSRF is serialized into JavaScript with `json_encode`.

**Step 2: Add pool-aware scale and validation**

Keep one `scale` action:

```text
action=scale&n=4
action=scale&pool=python&n=2
```

Add read-only:

```text
action=validate-pools&mode=pools&pools=...
```

Use `escapeshellarg` for every argument. Passing validation never authorizes the later persisted configuration.

**Step 3: Expand name syntax without trusting it**

Accept:

```regex
^ci-runner-(?:[0-9]+|[a-z][a-z0-9-]{0,22}[a-z0-9]-[0-9]+)$
```

One-character pool ids need an equivalent branch. The shell remains authoritative for ownership.

**Step 4: Verify**

```bash
php -l src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php
php -l src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
bash tests/php-actions.sh
bash tests/config-parity.sh
```

**Step 5: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php \
  tests/php-actions.sh tests/config-parity.sh
git commit -m "fix: validate pool actions strictly"
```

## Task 9: Add the Settings pool editor

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page`
- Modify: `tests/runner-pools.sh`

**Step 1: Add failing UI contract tests**

Assert source-level and serialized behavior for:

- mode selector;
- hidden canonical `RUNNER_POOLS` field;
- repeatable rows;
- derived label and YAML preview;
- orange primary Add action;
- accessible Remove actions;
- row-level and `aria-live` errors;
- routing-not-security warning;
- org/default-group/privileged warning;
- deletion drain warning;
- memory envelope across pool maxima;
- inactive fields remain enabled;
- server validation before native submit;
- persisted invalid value remains editable.

**Step 2: Implement a DOM-safe editor**

Use DOM creation and `textContent`. Serialize rows into the strict scalar immediately before validation/submission. Never interpolate row values into executable HTML.

**Step 3: Preserve native Unraid save semantics**

On submit:

1. serialize rows;
2. validate locally and focus the first bad field;
3. POST `validate-pools`;
4. on success call the native form's `submit()` method so `/update.php` and `#command` continue to work;
5. post-write reconciler validates again.

If server validation fails, do not submit.

**Step 4: Verify**

```bash
php -l src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
bash tests/runner-pools.sh
bash tests/config-parity.sh
```

**Step 5: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page \
  tests/runner-pools.sh tests/config-parity.sh
git commit -m "feat: configure routed runner pools"
```

## Task 10: Add pool summaries and per-pool controls to Fleet

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page`
- Modify: `tests/runner-pools.sh`

**Step 1: Write failing UI tests**

Cover:

- one compact pool card per pool;
- one shared runner grid and drawer;
- pool badge/column;
- global scale hidden in pool mode;
- `Scale to` fixed wording;
- `Scale up to` autoscale wording;
- orange primary button;
- live count initialization;
- focused input not overwritten;
- only pending pool disabled with `aria-busy`;
- invalid config disables mutations except Stop;
- retiring/blocked capacity visible;
- queued tile says workflow runs and remains global;
- one status interval;
- hidden-tab polling guard;
- `refreshAgain` follow-up;
- open drawer and steady rows survive nonstructural refreshes;
- pool membership participates in the structural signature;
- all new data is escaped.

**Step 2: Render pool cards from the existing status response**

Do not add per-pool endpoints or intervals. Derive the copyable YAML from the validated label.

**Step 3: Reuse one runner renderer**

Add a pool badge/column without duplicating bays, logs, drawers, stats, or recent-run logic.

**Step 4: Wire pool-aware Scale**

Send `{action:'scale', pool, n}`. On completion, request one authoritative follow-up refresh. Use the backend response for toast/log details.

**Step 5: Verify**

```bash
php -l src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
bash tests/runner-pools.sh
bash tests/autoscale-controls.sh
```

**Step 6: Commit**

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page \
  tests/runner-pools.sh tests/autoscale-controls.sh
git commit -m "feat: operate runner pools from Fleet"
```

## Task 11: Correct documentation and add the complete routing runbook

**Files:**

- Modify: `README.md`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/README.md`
- Modify: `.github/workflows/lint.yml`
- Modify: `deploy.sh` only if explicit file lists changed

**Step 1: Add documentation assertions**

Extend tests to require:

- exact Rust/Python/TypeScript selectors;
- generic-label leakage warning;
- routing-not-security statement;
- global runner-group limitation;
- utilization/idle-buffer autoscale wording;
- no “queue-aware autoscaling” claim;
- no per-pool queued claim;
- org-scope requirement;
- nonzero minima;
- activation and rollback ordering;
- no automatic sibling workflow edits;
- no official upstream push.

**Step 2: Correct current autoscale marketing**

Replace claims that queued jobs drive scaling. State that the global queued tile counts workflow runs while capacity growth uses live per-pool busy/idle headroom.

**Step 3: Document safe activation**

1. Deploy code with `RUNNER_MODE=single`.
2. Add a general compatibility pool if legacy selectors still exist.
3. Prepare specialized pool definitions.
4. Change workflow jobs to unique `ci-pool-*` selectors.
5. Enable pool mode.
6. Verify registered labels and one smoke job per pool.
7. Saturate Rust and prove Python/TypeScript stay available.
8. Remove the legacy/general pool only after workflow inventory is complete.

Rollback is symmetric:

1. Restore legacy workflow selectors first.
2. Wait for those workflow changes to land.
3. Switch to single mode.
4. Let pool runners drain.

Warn that switching modes first leaves specialized jobs queued.

**Step 4: Run every test in CI**

Change lint workflow to run:

```bash
for test in tests/*.sh; do bash "$test"; done
```

Keep syntax and PHP lint steps.

**Step 5: Verify**

```bash
for test in tests/*.sh; do bash "$test"; done
```

**Step 6: Commit**

```bash
git add README.md src/usr/local/emhttp/plugins/ci-runner-farm/README.md \
  .github/workflows/lint.yml deploy.sh tests
git commit -m "docs: explain runner pool routing"
```

## Task 12: Full verification, package inspection, and backward-compatible live smoke

**Files:**

- Verify all changed files
- Generated locally: `ci-runner-farm.tgz`, `ci-runner-farm.plg`

**Step 1: Run the complete local gate**

```bash
set -e
for file in $(git ls-files '*.sh'); do bash -n "$file"; done
for file in $(git ls-files '*.php' 'src/usr/local/emhttp/plugins/*/*.page'); do
  grep -q '<?php' "$file" || continue
  php -l "$file"
done
for test in tests/*.sh; do bash "$test"; done
./build-plg.sh
```

Expected: every command exits zero.

**Step 2: Inspect package contents and permissions**

```bash
tar -tzf ci-runner-farm.tgz | sort
tar -tzf ci-runner-farm.tgz | grep -E 'runner-pools|RunnerFarmFleet|RunnerFarmSettings|runner-farm.sh|exec.php'
```

Expected: every new/changed runtime asset is present. Do not commit generated `.tgz` or hand-edit generated release metadata.

**Step 3: Review the complete diff**

```bash
git diff main...HEAD --check
git diff --stat main...HEAD
git status --short
```

Confirm:

- no unrelated changes;
- no secrets;
- no references to planning trackers;
- no official upstream remote changes;
- single mode remains the default.

**Step 4: Code-only deploy to the development Unraid host**

Deploy only after local verification:

```bash
./deploy.sh root@tootie
```

Do not edit the live config into pool mode.

**Step 5: Verify existing live single-mode operation**

On the host:

```bash
/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh validate
/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh status-json
/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh autoscale-status
docker ps --filter label=net.unraid.ci-runner-farm.managed=true
```

Acceptance:

- five existing runners remain registered and healthy;
- names and legacy labels are unchanged;
- no upgrade-induced stale count;
- manual autoscale burst still works within the global maximum;
- Fleet, Settings, Image, Dashboard, logs, recycle validation, and status load;
- pool configuration is visible but inactive;
- official `unraid/*` upstream receives no push.

**Step 6: Do not activate pools automatically**

Full routing smoke requires coordinated workflow changes and is a separate explicit operational activation:

- configure Rust 3, Python 1, TypeScript 1;
- verify all GitHub registrations and unique labels;
- run one labeled job per pool;
- saturate Rust and prove Python/TypeScript remain eligible;
- exercise Rust-only autoscale;
- exercise Python manual burst and reclaim;
- remove a busy test pool and prove drain-before-removal;
- restart Docker and prove pool identity is preserved.

The implementation is complete without changing sibling workflows or enabling pool mode on the live farm.

**Step 7: Final branch state**

```bash
git status --short
git log --oneline --decorate -12
```

Keep the work on the local `codex/runner-pools` branch. Do not push to the official `unraid/*` upstream. A later push to the user's fork requires explicit user direction.

## Production failure matrix

| Codepath | Failure | Required behavior |
|---|---|---|
| Config parse | Truncated/malformed scalar looks empty | Fail closed; preserve runners; valid `config_error` status |
| Settings | Client validation bypassed | Every mutator validates the persisted snapshot again |
| Start | Unmanaged container owns a desired name | Visible collision; never adopt/remove it |
| Metadata | Pool/index/scope is forged or missing | `invalid-managed`; no automatic mutation |
| Registration | One pool token/API request fails | Other pools continue; failed identity retries later |
| Deregistration | Runner gets a job after idle check | Retain container unless GitHub deletion succeeds/404s |
| Scope change | Old runner removed after owner/repo edit | Use stamped original scope target |
| Migration | Legacy plus pool capacity exceeds host | One-for-one replacement and transition ceiling |
| Removed pool | Busy runner outlives apply timeout | Background reconcile continues even with autoscale off |
| Image update | Pool removed while lock is released | Re-read desired identity; never resurrect |
| Fixed scale | Reconciler restores config immediately | Respect generation-keyed runtime override |
| Autoscale | Slow start appears as no warm capacity | Count `starting` as pending; bound additions |
| Autoscale | One pool API timeout blocks later pools | Failure isolation and round-robin bounded work |
| Scale-down | `error` or `starting` treated as idle | Remove only explicit `idle` |
| Cache cleanup | `CACHE_ROOT` changed to unsafe path | Revalidate at deletion; preserve data on ambiguity |
| Status | Pool loops multiply Docker calls | One ps + one batched inspect, group in memory |
| Fleet | Old poll overwrites action result | In-flight guard plus one queued refresh |
| DOM | Forged metadata becomes markup/selector | JSON escape, `textContent`, `crfEsc`, `CSS.escape` |
| Routing | Generic workflow steals specialized capacity | Unique selectors and migration warnings |
| Rollback | Pool mode disabled before workflows change | Workflow-first rollback order |
| Security | Operator assumes trust isolation | Explicit routed-capacity warning and group guidance |

## Official sources

- [GitHub workflow syntax: `jobs.<job_id>.runs-on`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idruns-on)
- [Self-hosted runner routing precedence](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#routing-precedence-for-self-hosted-runners)
- [Using default and custom self-hosted runner labels](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)
- [Creating and assigning custom labels](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/apply-labels)
- [Runner groups](https://docs.github.com/en/actions/concepts/runners/runner-groups)
- [Choosing runners by group and labels](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)
- [Managing runner-group access](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)
- [Self-hosted runner REST API](https://docs.github.com/en/rest/actions/self-hosted-runners?apiVersion=2026-03-10)
- [Workflow-run REST API](https://docs.github.com/en/rest/actions/workflow-runs?apiVersion=2026-03-10)
- [Workflow-job REST API](https://docs.github.com/en/rest/actions/workflow-jobs?apiVersion=2026-03-10)
- [Self-hosted runner autoscaling and `workflow_job` webhooks](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#webhooks-for-autoscaling)
- [`workflow_job` webhook payload](https://docs.github.com/en/webhooks/webhook-events-and-payloads#workflow_job)
- [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits)
- [REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api?apiVersion=2026-03-10)

