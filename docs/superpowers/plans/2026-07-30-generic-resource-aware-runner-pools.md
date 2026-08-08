# Generic Resource-Aware Runner Pools and Scale-Set Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Execute inline in one uninterrupted pass. Do not use subagent-driven development.

**Goal:** Let operators create arbitrary labeled GitHub Actions runner pools with independent CPU and memory claims, ship those pools safely on the existing classic backend, and then add an opt-in, live-gated GitHub Actions Runner Scale Set backend that provides authoritative per-pool demand, fair scale-to-zero, and one-job JIT runners.

**Architecture:** Deliver two independently releasable milestones on one branch. Milestone A upgrades the pool schema, adds mandatory resource enforcement for V2 pools, provisions generic labels on classic persistent runners, replaces non-transactional Settings writes, exposes one typed Fleet model, and proves a reversible code-only nashost rollout. Milestone B pins and probes GitHub's scale-set client, introduces one multi-pool Go supervisor, separates GitHub eligibility, advertised resource capacity, remote ownership, and message ACK/replay into distinct transactional boundaries, implements a pure fair scheduler, executes protected JIT runners, and activates the backend only through a persisted migration state machine. If the live gate cannot prove a required GitHub or Docker semantic, keep Milestone A operational and do not weaken the scale-set design.

**Tech stack:** Bash 5, Docker CLI and cgroup v2, PHP/Dynamix pages, vanilla JavaScript, Unraid UUI with Aurora-compatible semantic tokens, Go 1.25.3, `github.com/actions/scaleset` v0.4.0 at commit `6ce025902cd964747a078c2aabe7340ebc667eca`, shell/PHP/Node/Go behavioral tests, GitHub Actions REST/scale-set APIs.

---

## Product and safety contract

### Two release milestones

Milestone A is independently deployable:

1. Canonical V2 pool configuration and V1 migration.
2. Mandatory V2 resource broker and crash-safe reservations.
3. Generic labels/resources on classic runners.
4. Transactional generic-pool Settings.
5. Typed classic Fleet status and race-safe controls.
6. Reproducible package, code-only nashost deploy, live classic validation, and rollback.

Milestone B starts only after Milestone A is green and reversible:

1. Disposable pinned-client compatibility probe.
2. Exact remote ownership and one multi-pool supervisor.
3. Pure fair scheduler and resource-backed advertised-capacity leases.
4. Protected one-job JIT execution.
5. Durable classic-to-scale-set and scale-set-to-classic migration state machine.
6. Scale-set Settings/Fleet extensions.
7. Exact packaged-identity gate, live activation, workload proof, and reverse rollback.

### Configuration contract

Keep:

```ini
RUNNER_MODE="single"   # single|pools
```

Accept V1 unchanged:

```text
id|fixed|min|max|idle
```

Add V2:

```text
v2|id|routing-label|additional-labels-csv|fixed|min|max|idle|cpus|memory
```

Rules:

- An active snapshot is all V1 or all V2; mixed versions fail.
- Keep one to eight pools.
- `id` is an immutable lifecycle key after first successful Apply.
- `routing-label` is the editable user-facing pool name and unique selector identity.
- Additional job requirement labels can be shared, but a workflow selector must include the pool routing label.
- Labels describe eligibility. They do not provide hardware, network egress, mounts, permissions, or isolation.
- Presets Rust, Python, TypeScript, Go, Ops, Residential Egress, and Custom only initialize blank UI cards. No preset discriminator is persisted.
- V1 retains its exact classic behavior and inherited global CPU/memory.
- V2 always uses resource enforcement. Only legacy single/V1 can use the compatibility bypass.
- Classic V2 requires `min >= 1` and numeric `max`.
- Scale-set V2 may use `min = 0` and `max = auto`.
- Keep `64` only as an internal emergency/corruption fuse, not the normal host policy.

Canonical internal types:

```text
config_revision        SHA-256 of the complete normalized active configuration
runner_spec_hash       SHA-256 of everything baked into one pool's runner
controller_instance_id random per helper process startup
demand_sequence        monotonic helper snapshot sequence
compatibility_record_id SHA-256 of every gate-bound input
session_id             GitHub-issued message-session identifier
scale_set_id           GitHub-issued scale-set identifier
cpu_milli              integer scheduler/Docker CPU claim
memory_bytes           integer scheduler/Docker memory claim
```

Do not introduce a generic `generation` field in IPC or status.

### Trust and isolation contract

- GitHub runner groups and repository access are the authorization boundary.
- A non-default restricted runner group, resolved and persisted by GitHub ID, is mandatory before privileged scale-set activation.
- Pools are not hostile-tenant isolation boundaries.
- Reject `SHARE_DOCKER_SOCK=true` whenever V2 or scale-set mode is active.
- Privileged DinD is permitted only for trusted restricted repositories and only after proving nested processes remain charged to the outer runner cgroup.
- Apply explicit CPU, memory, memory-swap, PIDs, and tmpfs limits.
- PAT and GitHub App modes are mutually exclusive. PAT can prove the initial compatibility gate. A GitHub App requires Self-hosted runners organization read/write permission; classic PAT behavior still requires the existing organization administration permission.
- Raw scale-set messages, repository names, refs, job IDs, authorization headers, tokens, and JIT blobs never enter aggregate status, Nchan, or persisted general logs.

### State placement

```text
/boot/config/plugins/ci-runner-farm/
  ci-runner-farm.cfg             operator configuration, mode 0600
  ci-runner-farm.cfg.bak         preserved previous configuration, mode 0600
  installation-id               stable random installation UUID, mode 0600
  scale-set-compat.json          rare compatibility evidence, mode 0600
  scale-set-ownership.json       rare exact remote ownership changes, mode 0600
  backend-transition.json        rare effective backend/phase changes, mode 0600

<CACHE_ROOT>/controller/
  replay/                        non-secret ACK/acquisition journal
  logs/helper/                   bounded helper diagnostics
  logs/runners/<runner>/         bounded Runner and Worker diagnostics

/run/ci-runner-farm/
  reservations/                  pending local starts
  leases/                        outstanding GitHub capacity offers
  scaleset/control.sock          root-only helper socket
  scaleset/snapshot.json         atomic typed helper snapshot
  operations/                    bounded async operation status
  *.pid, *.lock, *.state         ephemeral controller state
```

Steady-state demand, heartbeat, reservations, leases, and sessions must write zero bytes to `/boot`.

### Transactional boundaries

Treat these as separate protocols:

1. **GitHub eligibility:** exactly one backend may be remotely eligible for production selectors.
2. **Advertised capacity:** every free advertised slot owns a CPU/memory lease for the outstanding long poll.
3. **Remote ownership:** create intent is persisted before the API call; exact returned IDs are persisted before commit; never adopt/delete by name.
4. **Message replay:** acquisition/ACK phases are journaled durably before ACK.
5. **Local start:** reserve under the fleet lock, unlock for slow work, then relock to finalize after observing reality.

### Performance budgets

- One Go helper process.
- At most eight per-pool session goroutines and one active session per enabled pool.
- Helper idle RSS no more than 64 MiB for eight pools.
- Helper idle CPU below 1%.
- One shared GitHub API rate limiter/backoff controller.
- Expected full snapshot below 256 KiB; hard IPC limit 1 MiB.
- Atomic snapshot read/validation below 100 ms.
- Heartbeat no more often than 10 seconds; stale after two missed heartbeats.
- Fleet lock p95 hold below 250 ms.
- No Docker, GitHub, network, image, or JIT calls while the fleet lock is held.
- One recurring `docker ps` and one batched `docker inspect`.
- Zero external calls from scheduler evaluation or status rendering.
- Pure scheduling complexity `O(P + R + K)` and below 250 ms for eight pools/64 runners.
- Demand wake to admission decision below five seconds.
- Two concurrent cold starts by default; four absolute maximum.
- Default diagnostic cap 256 MiB total and seven days.

---

## Baseline and working rules

### Step 1: Verify the implementation worktree and remotes

Run:

```bash
pwd
git status --short --branch
git remote -v
git log -1 --oneline
```

Expected:

- A dedicated `codex/` implementation branch.
- Clean worktree.
- Base contains this plan.
- `origin` is `git@github.com:jmagar/ci-runner-farm.git`.
- `upstream` may exist as `git@github.com:unraid/ci-runner-farm.git`, but no command in this plan pushes it.

### Step 2: Capture the existing green baseline

Run:

```bash
for test in tests/*.sh; do bash "$test"; done
php -l src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php
node --check <(awk '/^<script>$/{f=1;next}/^<\/script>$/{f=0}f' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page | perl -0pe 's/<\?=.*?\?>/null/gs')
node --check <(awk '/^<script>$/{f=1;next}/^<\/script>$/{f=0}f' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page | perl -0pe 's/<\?=.*?\?>/null/gs')
```

If an existing test is red, stop and record the exact baseline failure before changing source.

### Step 3: Add shared test utilities before production code

Create:

- `tests/lib/assert.sh`
- `tests/lib/fake-clock.sh`
- `tests/lib/fake-docker.sh`
- `tests/lib/fake-github.sh`
- `tests/fixtures/`

Utilities must:

- use task-specific temporary directories from `mktemp -d`;
- never write `/boot`, real cache roots, Docker, or GitHub;
- count every external call;
- support injected 404/409/429/5xx/timeouts and response loss;
- support fake monotonic/wall clocks without sleeping;
- print exact expected/actual values on failure.

Run all existing tests again and commit only the no-behavior-change harness:

```bash
git add tests/lib tests/fixtures
git commit -m "test: add deterministic runner farm fixtures"
```

---

## Milestone A — Generic resource-aware classic pools

## Task 1: Canonical V2 pool configuration

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page`
- Modify: `tests/runner-pools.sh`
- Modify: `tests/config-parity.sh`
- Create: `tests/fixtures/pools-v1.tsv`
- Create: `tests/fixtures/pools-v2.tsv`

### Step 1: Write failing schema and migration fixtures

Cover:

- exact five-field V1;
- exact ten-field V2;
- mixed snapshot rejection;
- one to eight records;
- maximum valid serialized length and one byte over;
- missing, extra, and trailing fields/delimiters;
- case-insensitive ID/routing collisions;
- routing-to-additional-label collisions;
- shared additional labels accepted;
- duplicate additional labels rejected;
- reserved `self-hosted`, OS, architecture, and internal routing labels rejected;
- control/NUL/newline/path/whitespace injection;
- invalid `GH_OWNER`;
- fractional CPU normalization (`0.5 -> 500`, `2 -> 2000`);
- memory normalization (`512M`, `2G`) to bytes;
- invalid/zero/overflow claims;
- `inherit` effective resolution while retaining provenance;
- V1 never serializes merely by loading;
- stale config defaults clear on reload;
- saved V2 ID immutability policy.

Run:

```bash
bash tests/runner-pools.sh
bash tests/config-parity.sh
```

Expected: new cases fail.

### Step 2: Replace repeated parser mutation with one immutable snapshot

Implement source-safe functions:

```bash
pool_config_normalize()      # lexical grammar/canonicalization only
pool_policy_validate()       # backend/capacity/resource policy
pool_snapshot_load()         # exactly once per load_cfg
pool_snapshot_records()
pool_snapshot_field()
pool_config_serialize_v2()
pool_config_revision()
pool_runner_spec_hash()
parse_cpu_milli()
parse_memory_bytes()
```

`load_cfg()` must:

1. reset every allowlisted key to its source default;
2. parse only `CFG_KEYS`;
3. normalize exactly once;
4. store one canonical internal table;
5. compute `config_revision`;
6. never write configuration.

Do not use `eval`, `source` on operator data, JSON parsing for the record grammar, or subprocess-per-field accessors.

### Step 3: Lock identity and label semantics

- New unsaved ID is editable.
- Persisted ID is read-only.
- Routing label is user-facing identity.
- Rename is represented as a new ID plus retirement of the old ID.
- Presets remain absent from runtime schema.
- V1 in-memory routing remains its exact existing derived label.

### Step 4: Add config parity

Add every new default to:

- engine defaults;
- `default.cfg`;
- Settings `$defaults`;
- parity allowlists/engine-only exceptions.

Run:

```bash
bash tests/runner-pools.sh
bash tests/config-parity.sh
```

Expected: pass.

### Step 5: Commit

```bash
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page \
  tests/runner-pools.sh tests/config-parity.sh tests/fixtures/pools-v1.tsv tests/fixtures/pools-v2.tsv
git commit -m "feat: add canonical v2 runner pool configuration"
```

## Task 2: Mandatory V2 resource broker and reservations

**Files:**

- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-resources.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg`
- Create: `tests/resource-admission.sh`
- Modify: `tests/runner-runtime.sh`
- Modify: `tests/reconcile-locks.sh`
- Modify: `tests/config-parity.sh`

### Step 1: Write failing pure resource tests

Test these public functions:

```bash
resource_budget_resolve
resource_claim_sum
resource_standalone_capacity
resource_admit_one
resource_reason_text
reservation_create
reservation_finalize
reservation_release
reservation_reconcile
```

Fixtures must cover auto/explicit CPU and memory, reserves, CPU overcommit, no memory overcommit, impossible single runner, optional per-pool maximum, emergency fuse, fractional CPUs, all lifecycle phases, invalid/unlimited managed containers, and fragmentation.

### Step 2: Implement integer accounting

Use only:

```text
cpu_milli
memory_bytes
```

Scheduling budget:

```text
allocatable_cpu = floor((host_cpu_milli - reserve_cpu_milli) * cpu_overcommit)
allocatable_memory = host_memory_bytes - reserve_memory_bytes
admissible = allocatable - Docker claims - reservations - later poll leases
```

Never use instantaneous free RAM or CPU utilization as a guarantee.

### Step 3: Implement reservation records

One mode-0600 record per start:

```text
schema_version
operation_id
boot_id
owner_pid
deadline
config_revision
pool_id
runner_name
cpu_milli
memory_bytes
runner_spec_hash
phase
```

Required protocol:

1. collect immutable/slow inputs outside lock;
2. acquire fleet lock;
3. reload and compare `config_revision`;
4. refresh/revalidate the already-collected inventory revision;
5. commit unique reservation;
6. release lock;
7. perform Docker/GitHub/network work;
8. reacquire lock;
9. observe the real container/inventory result;
10. finalize or release;
11. release lock.

No external command may run inside the locked sections.

### Step 4: Enforce Docker limits

For V2 add exact:

```bash
--cpus <canonical decimal>
--memory <bytes-or-canonical-suffix>
--memory-swap <explicit policy>
--pids-limit <bounded value>
--tmpfs <bounded private runtime mounts>
```

Reject host Docker socket sharing. Add preflight for cgroup/controller support. Create an integration fixture that proves nested DinD CPU/memory appears under the outer runner cgroup; activation later depends on it.

### Step 5: Add call and lock budgets

Instrument test fakes to fail when:

- Docker/GitHub/network is called under fd 8 flock;
- no-op inventory exceeds one `ps` plus one batched `inspect`;
- status/scheduler invokes any external command;
- fake lock hold exceeds 250 ms.

### Step 6: Run and commit

```bash
bash tests/resource-admission.sh
bash tests/runner-runtime.sh
bash tests/reconcile-locks.sh
bash tests/config-parity.sh
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-resources.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg \
  tests/resource-admission.sh tests/runner-runtime.sh tests/reconcile-locks.sh tests/config-parity.sh
git commit -m "feat: add resource broker and crash-safe reservations"
```

## Task 3: Classic generic labels, resources, and protected registration

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page`
- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh`
- Modify: `tests/runner-runtime.sh`
- Modify: `tests/autoscale-controls.sh`
- Modify: `tests/safe-paths.sh`
- Create: `tests/secret-handoff.sh`

### Step 1: Write failing classic provisioning tests

Assert `build_args` consumes already-normalized:

```text
effective_labels
cpu_milli
memory_bytes
runner_spec_hash
config_revision
```

Assert exact Docker metadata and that resource/label edits produce one-for-one idle replacement while busy work survives.

### Step 2: Replace registration-token Docker Env

Add an entrypoint protocol:

1. start container with a private tmpfs and a wait-only entrypoint;
2. stream the registration/JIT payload through stdin or an inherited descriptor;
3. write it only inside private container tmpfs;
4. configure/start the runner;
5. unlink secret before listener execution;
6. emit a positive consumed acknowledgment;
7. fail closed and remove the container on timeout/error.

Do not pass secret material through Env, argv, labels, bind-mounted persistent files, shell tracing, status, or logs.

### Step 3: Preserve classic behavior

- Fixed UI/action semantics remain `Scale to`.
- Classic autoscale action remains `Scale up to` and a temporary floor.
- Classic requires `min >= 1`, numeric `max`, and has no pool demand/zero scaling.
- Single/V1 runner names, labels, fingerprints, and no-churn behavior stay unchanged.
- Keep provisioning/cache/firewall preflight, explicit-idle deletion, fresh GitHub inventory, fd 8/fd 9 closure, bounded reconcile, and peer isolation.

### Step 4: Run sentinel tests

Use a unique sentinel token and scan:

```text
docker inspect Env
docker inspect labels
container argv
host process list
plugin logs
runner logs
status JSON
configuration
package staging tree
stopped container filesystem
runtime directories after cleanup
```

### Step 5: Run and commit

```bash
bash tests/runner-runtime.sh
bash tests/autoscale-controls.sh
bash tests/safe-paths.sh
bash tests/secret-handoff.sh
git add src/usr/local/emhttp/plugins/ci-runner-farm tests
git commit -m "feat: enforce generic classic pool profiles"
```

## Task 4: Transactional Settings and mutation security

**Files:**

- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page`
- Modify: `tests/php-actions.sh`
- Modify: `tests/ui-js.sh`
- Create: `tests/settings-behavior.js`
- Create: `tests/settings-endpoint.php`

### Step 1: Write failing endpoint security tests

Cover:

- GET mutation rejected;
- only `$_POST` is read for mutations;
- `csrf_token[]=x`, `action[]=x`, and every array payload return typed 400/403, never PHP TypeError;
- unknown/oversized action rejected;
- arbitrary paths/commands rejected;
- stale `expected_config_revision` rejected;
- invalid snapshot never reaches disk/reconcile;
- write/fsync/rename failure preserves old config;
- resulting cfg and backup are mode 0600;
- direct `/update.php` path is not used for these settings.

### Step 2: Add `apply-config`

Endpoint receives one explicit allowlisted settings snapshot. Shell/PHP must:

1. validate POST/method/CSRF/action types and limits;
2. compare expected revision;
3. canonicalize using the same server parser;
4. reject field errors with stable codes;
5. write same-directory temporary mode 0600;
6. flush and atomically rename;
7. preserve previous mode-0600 backup;
8. return canonical config plus new revision;
9. trigger reconciliation only after commit.

Settings Apply saves configuration only. It cannot start a backend migration.

### Step 3: Build explicit field serialization

Replace positional `querySelectorAll('input')` serialization with:

```html
data-pool-field="id"
data-pool-field="routing_label"
data-pool-field="additional_labels"
data-pool-field="fixed"
data-pool-field="min"
data-pool-field="max"
data-pool-field="idle"
data-pool-field="cpus"
data-pool-field="memory"
```

Serialize through one fixed ordered allowlist. Preset controls must never enter runtime serialization.

### Step 4: Implement accessible editor behavior

- Full-width pool `<fieldset>` with `<legend>`.
- Sections: Identity, Routing, Capacity, Resources.
- Per-field inline error IDs.
- Focusable summary links to invalid fields.
- Saved IDs read-only.
- `Duplicate as new pool` plus retire-old warning.
- Exact selector code and visible `Copy selector` button.
- Persistent text: labels do not provide infrastructure/isolation.
- V1 Apply upgrade banner and lossy downgrade warning.
- `inherit` displays effective CPU/memory.
- “Scheduling budget,” “Reserved by managed runners,” and “Admissible now.”
- Preset on blank card only; populated overwrite requires preview/confirm.
- Inactive draft excluded from active validation.

Every async request uses an epoch or `AbortController` for success, error, and catch. Apply is single-flight with `aria-busy`; failures retain all input.

### Step 5: Run and commit

```bash
php -l src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php
php tests/settings-endpoint.php
node tests/settings-behavior.js
bash tests/php-actions.sh
bash tests/ui-js.sh
git add src/usr/local/emhttp/plugins/ci-runner-farm tests
git commit -m "feat: add transactional generic pool settings"
```

## Task 5: Typed Fleet model and race-safe classic UI

**Files:**

- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-status.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php`
- Create: `tests/fleet-behavior.js`
- Create: `tests/pool-status.sh`
- Modify: `tests/ui-js.sh`
- Modify: `tests/runner-runtime.sh`

### Step 1: Write typed status fixtures

One snapshot:

```json
{
  "schema_version": 2,
  "config_revision": "sha256",
  "observed_at": 0,
  "inventory_revision": "sha256",
  "backend": {"requested": "classic", "effective": "classic", "transition": "classic_active"},
  "resources": {
    "cpu_milli": {"budget": 0, "reserve": 0, "reserved": 0, "admissible": 0},
    "memory_bytes": {"budget": 0, "reserve": 0, "reserved": 0, "admissible": 0}
  },
  "reservations": [],
  "pools": [],
  "runners": []
}
```

Machine values stay integer. Formatting is display-only. Stable reason codes are machine contracts.

### Step 2: Build one immutable model

`runner-status.sh` consumes:

- normalized config;
- one already-built Docker inventory;
- reservations;
- resource broker result;
- later demand/leases/ownership/transition.

`cmd_status_json` only serializes the model. Scheduler and status share the same derived state; neither performs Docker/GitHub calls.

Keep `dashboard-json` as a separate count-only privacy projection.

### Step 3: Remove recurring per-runner calls

Recurring control/status must use at most:

```text
1 docker ps
1 batched docker inspect
```

No recurring per-runner `exec`, `logs`, or `inspect`. Use one fresh batched GitHub runner inventory or image-written state for classic busy/idle; stale truth blocks removal. Detailed job/log data loads only for an opened runner drawer.

### Step 4: Rebuild Fleet cards safely

- Rename tile to `Tracked repository run queue` and add `not pool demand`.
- Stable-key cards, not wholesale innerHTML replacement.
- Primary row: configured/effective target, admitted/blocked, up/busy/idle/starting/draining.
- Details disclosure: labels and scheduling budget.
- Preserve focused value, selection/caret, and disclosures across polls.
- Separate epochs/single-flight for farm, queue, cache, log, stats, and runner drawer.
- Keep last-good UI on malformed/version-mismatched replies.
- Display per-source age.
- Accessible live status for success; persistent inline mutation errors.
- Orange `Scale to` and `Scale up to` buttons.

### Step 5: Run and commit

```bash
bash tests/pool-status.sh
node tests/fleet-behavior.js
bash tests/ui-js.sh
bash tests/runner-runtime.sh
git add src/usr/local/emhttp/plugins/ci-runner-farm tests
git commit -m "feat: add typed classic fleet status"
```

## Task 6: Package and live-prove Milestone A

**Files:**

- Modify: `build-plg.sh`
- Modify: `ci-runner-farm.plg`
- Modify: installer mode rules generated by `build-plg.sh`
- Create: `tests/package-reproducible.sh`
- Create: `tests/performance-contracts.sh`
- Create: `docs/deployment/generic-pools-nashost.md`

### Step 1: Add offline release gates

Run:

```bash
for test in tests/*.sh; do bash "$test"; done
find src -type f \( -name '*.php' -o -name '*.page' \) -print0 | xargs -0 -n1 php -l
shellcheck src/usr/local/emhttp/plugins/ci-runner-farm/include/*.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/event/* tests/*.sh
```

The deterministic 8-pool/64-runner fixture must assert:

- linear parsing/scheduling;
- one `ps`/one batched `inspect`;
- zero status/scheduler external calls;
- lock budget;
- response size bound;
- no subprocess-per-field behavior;
- simulated thousands of churn/restart/reservation transitions.

### Step 2: Build twice

Use separate temporary output directories and compare:

```text
archive SHA-256
archive byte count
sorted file list
file modes
ownership metadata
unpacked content hashes
```

Installer must explicitly set every executable, including `runner-entrypoint.sh`, to 0755. Do not rely on checkout modes.

### Step 3: Add non-destructive maintenance

Implement `quiesce`/`maintenance` distinct from `stop`:

- stop new admissions;
- do not remove busy runners;
- expose state/status;
- allow safe resume.

Never use destructive `cmd_stop` for deployment or busy rollback.

### Step 4: Code-only deploy to nashost

Before changing live state:

1. record nashost hostname/kernel/Docker/cgroup/cpu/memory/swap/cache facts;
2. record current runtime file hashes and image digest;
3. back up cfg mode 0600 and SHA-256;
4. set `CRF_STAGE_ID="$(git rev-parse --short=12 HEAD)"` locally and stage beneath `/usr/local/emhttp/plugins/.ci-runner-farm.$CRF_STAGE_ID`;
5. verify syntax/hashes/modes;
6. enter maintenance;
7. replace code with an explicit recoverable backup;
8. run authenticated Settings/Fleet smoke;
9. resume.

Do not Apply V2 until code-only smoke succeeds.

### Step 5: Live classic tests and rollback

Create temporary Rust/Python/TypeScript/Go/Ops/Residential Egress label configurations, then prove:

- exact labels/selectors;
- resource limits;
- fixed `Scale to`;
- autoscale `Scale up to`;
- one-for-one profile migration;
- exhaustion/fragmentation reasons;
- reservation recovery after controller restart;
- peer progress after one pool failure;
- no secret leakage.

Restore the exact previous cfg/code and prove behavior without interrupting busy work. Remove fixtures.

### Step 6: Commit milestone

```bash
git add build-plg.sh ci-runner-farm.plg src tests docs/deployment
git commit -m "test: prove classic resource-aware pool release"
```

---

## Milestone B — Live-gated scale-set backend

## Task 7: Pinned disposable compatibility probe

**Files:**

- Create: `tools/crf-scaleset/go.mod`
- Create: `tools/crf-scaleset/go.sum`
- Create: `tools/crf-scaleset/vendor/`
- Create: `tools/crf-scaleset/cmd/crf-scaleset/main.go`
- Create: `tools/crf-scaleset/internal/github/`
- Create: `tools/crf-scaleset/internal/probe/`
- Create: `tools/crf-scaleset/internal/protocol/`
- Create: Go tests beside packages
- Modify: `build-plg.sh`
- Create: `tests/scale-set-probe.sh`

### Step 1: Pin and vendor

`go.mod` must require Go 1.25.3 and the exact released v0.4.0 commit. Do not track `main`.

Run:

```bash
cd tools/crf-scaleset
go mod download
go mod verify
go mod vendor
git diff --exit-code -- go.mod go.sum vendor
go test ./...
go test -race ./...
go vet ./...
```

### Step 2: Define the client boundary

Use:

```go
type ScaleSetAPI interface {
    CreateRunnerScaleSet(context.Context, CreateSpec) (ScaleSet, error)
    GetRunnerScaleSet(context.Context, int64) (ScaleSet, error)
    UpdateRunnerScaleSet(context.Context, int64, UpdateSpec) (ScaleSet, error)
    DeleteRunnerScaleSet(context.Context, int64) error
    GetRunnerGroupByName(context.Context, string) (RunnerGroup, error)
    CreateMessageSession(context.Context, int64) (Session, error)
    GetMessage(context.Context, Session, int) (MessageBatch, error)
    AcquireJobs(context.Context, Session, AcquireRequest) (AcquireResult, error)
    AcknowledgeMessage(context.Context, Session, int64) error
    GenerateJitRunnerConfig(context.Context, int64, JITRequest) ([]byte, error)
}
```

Wrap `MessageSessionClient`; do not call the library `Listener`.

### Step 3: Add fake protocol/crash tests

Test:

- 202 long poll;
- nil/partial/truncated statistics;
- all documented statistics counters;
- partial and ambiguous `AcquireJobs`;
- crash before/after acquisition and ACK;
- ACK redelivery;
- session replacement;
- dynamic max-capacity values, including zero;
- shrink during outstanding poll;
- assignment arriving after shrink;
- JIT single-use deletion;
- bounded request/response frames;
- redaction.

### Step 4: Build deterministically

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
  go build -mod=vendor -trimpath -buildvcs=false \
  -ldflags='-s -w -buildid=' \
  -o ../../build/crf-scaleset ./cmd/crf-scaleset
```

Verify:

```bash
file build/crf-scaleset
ldd build/crf-scaleset && exit 1 || true
go version -m build/crf-scaleset
sha256sum build/crf-scaleset
```

Build twice from clean temporary output and compare SHA-256.

### Step 5: Implement isolated live probe

Authenticated POST action returns an opaque operation ID. The probe must use:

- dedicated restricted runner group;
- disposable test repository;
- installation-scoped random names/selectors;
- selectors incapable of matching production;
- exact recorded remote IDs;
- no name sweeping.

Live checks:

1. create/get/update/delete;
2. resolved runner-group ID and restricted/public policy;
3. multiple custom labels;
4. `TotalAssignedJobs`;
5. current image JIT;
6. zero-to-one wake;
7. cancellation/reassignment;
8. crash before/after ACK and replay;
9. dynamic capacity, max zero, shrink-during-poll, post-shrink assignment;
10. label/group eligibility updates;
11. busy-to-idle eligibility race;
12. nested DinD outer-cgroup charging;
13. exact cleanup of sessions, registrations, containers, and scale sets.

If no remotely enforced eligibility barrier is proven, fail.

### Step 6: Persist compatibility evidence

Write atomically mode 0600 only after cleanup proof:

```json
{
  "schema_version": 1,
  "compatibility_record_id": "sha256",
  "plugin_digest": "sha256",
  "helper_digest": "sha256",
  "module_revision": "6ce025...",
  "go_version": "go1.25.3",
  "image_digest": "sha256",
  "dockerfile_digest": "sha256",
  "entrypoint_digest": "sha256",
  "owner": "org",
  "api_url": "https://api.github.com",
  "installation_id": "uuid",
  "host_id": "machine-id hash",
  "runner_group_id": 0,
  "capabilities": {},
  "tested_at": "RFC3339",
  "cleanup": {"complete": true, "ids": []}
}
```

Invalidate after 30 days or any bound-input change. No HMAC key is needed for the local root trust boundary.

### Step 7: Commit

```bash
git add tools/crf-scaleset build-plg.sh tests/scale-set-probe.sh src
git commit -m "feat: add pinned scale-set compatibility probe"
```

## Task 8: Exact ownership and one production supervisor

**Files:**

- Create: `tools/crf-scaleset/internal/supervisor/`
- Create: `tools/crf-scaleset/internal/journal/`
- Create: `tools/crf-scaleset/internal/ipc/`
- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh`
- Create: `tests/scale-set-supervisor.sh`
- Create: `tests/fixtures/scaleset-ipc/`

### Step 1: Write ownership crash tests

Test:

- persist create intent before request;
- response lost after remote creation;
- exact spec reconciliation;
- same-name foreign object collision;
- exact ID commit;
- 404 idempotent delete;
- 409/429/5xx/timeout delete retains tombstone;
- removed/renamed pool keeps frozen spec;
- installation/owner/group/helper mismatch fails closed;
- no automatic orphan adoption.

Remote names derive from:

```text
crf-<installation-id-short>-<pool-id>-<remote-spec-revision>
```

### Step 2: Implement durable replay journal

Non-secret cache-pool entries:

```text
scale_set_id
session_id
message_id
phase=received|validated|acquire_started|acquire_observed|committed|ack_pending|acked
assigned_count
acquired_handles
config_revision
ownership_revision
updated_at
```

On ambiguous acquisition, query/reconcile remote state before retry. ACK only after `committed`. Host reboot must resume.

### Step 3: Lock one helper topology

Exactly:

- one supervisor PID;
- maximum eight per-pool goroutines;
- one session per enabled pool;
- one API limiter/backoff manager;
- one atomic snapshot writer;
- per-pool panic/error isolation and bounded restart.

No Docker API/CLI authority in Go.

### Step 4: Implement bounded root-only IPC

Socket directory 0700, socket 0600, peer credential validation. Fixed operations only:

```text
apply_sessions
publish_capacity_leases
issue_jit
read_snapshot
reconcile_owned
delete_owned
```

Every request/reply:

```json
{
  "schema_version": 1,
  "request_id": "uuid",
  "operation": "read_snapshot",
  "config_revision": "sha256",
  "ownership_revision": "sha256",
  "controller_instance_id": "uuid",
  "sequence": 0
}
```

Snapshot adds `observed_at`, `valid_until`, per-pool IDs, assigned demand, applied lease epoch, session health, and acquired work handles. It excludes raw job/repository/message data.

Reject wrong schema/revision/instance, sequence regression, stale time, oversized strings/arrays, unknown paths/commands, and payloads over 1 MiB.

### Step 5: Enforce budgets

Test one helper PID, max eight sessions, idle RSS <=64 MiB, idle CPU <1%, heartbeat <=10 seconds, stale after two misses, snapshot expected <256 KiB, hard <=1 MiB, validation <100 ms.

### Step 6: Run and commit

```bash
cd tools/crf-scaleset
go test ./...
go test -race ./...
go vet ./...
cd ../..
bash tests/scale-set-supervisor.sh
git add tools/crf-scaleset src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh tests
git commit -m "feat: add crash-safe scale-set supervisor"
```

## Task 9: Pure fair scheduler and poll leases

**Files:**

- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scheduler.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-resources.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Create: `tests/scheduler.sh`
- Create: `tests/fixtures/scheduler.tsv`

### Step 1: Write pure scheduler fixtures

Input:

```text
normalized pools
fresh TotalAssignedJobs
warm targets
service-capable running slots
draining/resource-charged slots
pending start reservations
outstanding poll leases
host budget
per-pool max
fairness cursor
```

Output:

```text
desired per pool
admitted per pool
blocked reason per pool
ordered start decisions
ordered safe removals
advertised capacity vector
new leases
new cursor
```

Cover simultaneous Rust/Python/TypeScript/Go/Ops demand, min zero, max auto, fragmentation, infeasible pool, broken pool, stale demand, assigned vs draining, pending starts, fairness, and emergency fuse.

### Step 2: Implement `O(P + R + K)` policy

Equal round-robin:

- one committed admission per feasible pool per round;
- advance cursor only after commit;
- no weights, semantic preset priority, bin packing, or backtracking;
- two starts default, four hard maximum.

`desired = TotalAssignedJobs + warm target`, minus service-capable slots only.

### Step 3: Add resource-backed discovery offers

Before helper advertises free capacity:

1. broker creates CPU/memory lease;
2. lease records pool, poll/epoch, claim, config revision, deadline;
3. helper applies the lease vector;
4. resources remain unavailable to manual/prewarm/peer starts;
5. assignment inherits lease;
6. shrink cannot release before advertising poll completes/expires;
7. uncertain restart state reconstructs conservatively.

Rotate offers so every feasible zero pool is discovered within the bound measured by the live gate.

### Step 4: Add event-driven wake

Helper snapshot sequence change wakes broker. Decision occurs within five seconds. Keep periodic reconcile as fallback. Stale/regressed/wrong-revision demand blocks discretionary shrink and is never zero. Terminal cleanup remains allowed.

### Step 5: Run and commit

```bash
bash tests/scheduler.sh
bash tests/resource-admission.sh
bash tests/autoscale-controls.sh
bash tests/performance-contracts.sh
git add src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scheduler.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-resources.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh tests
git commit -m "feat: add fair scale-set capacity scheduler"
```

## Task 10: Protected JIT execution

**Files:**

- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh`
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-entrypoint.sh`
- Modify: image/Dockerfile generation paths
- Modify: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh`
- Create: `tests/scale-set-runtime.sh`
- Extend: `tests/secret-handoff.sh`

### Step 1: Write lifecycle crash matrix

Inject crash/response loss:

- before/after JIT issuance;
- before/after secret handoff;
- before/after Docker create;
- after Docker starts but before shell sees response;
- before/after container observation;
- before/after runner registration;
- before/after job terminal;
- before/after container delete;
- helper restart;
- host/controller restart;
- cancellation/reassignment;
- runner crash;
- GitHub outage;
- stale demand.

### Step 2: Implement one-job operation

`runner-jit.sh` consumes only:

```text
committed scheduler admission
reservation ID
acquired work handle
single-use JIT descriptor
normalized runner spec
```

It does not calculate demand, own sessions, or change backend state.

Unique runner directories:

```text
work/<runner-id>
docker/<runner-id>
logs/runners/<runner-id>
```

### Step 3: Reuse protected entrypoint handshake

Container receives JIT material after start through stdin/FD into private tmpfs, consumes/unlinks, positively acknowledges, then launches listener. On timeout/failure remove container and release reservation only after observed deletion.

### Step 4: Externalize diagnostics and cleanup

Capture both:

```text
_diag/Runner_*
_diag/Worker_*
```

Root-only cache storage, redact known secret shapes/sentinels, rotate by size and age, total default 256 MiB/seven days. Do not run `du` every poll.

Completed/exited cleanup proceeds under stale demand. Busy/assigned work is preserved.

### Step 5: Run and commit

```bash
bash tests/scale-set-runtime.sh
bash tests/secret-handoff.sh
bash tests/runner-runtime.sh
bash tests/safe-paths.sh
git add src tools/crf-scaleset tests
git commit -m "feat: execute protected one-job jit runners"
```

## Task 11: Durable backend migration and rollback

**Files:**

- Create: `src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-migration.sh`
- Modify: `runner-farm.sh`, `runner-scalesets.sh`, `runner-scheduler.sh`, `runner-jit.sh`
- Modify: `include/exec.php`
- Create: `tests/backend-migration.sh`
- Create: `tests/fixtures/migration.tsv`

### Step 1: Write phase transition fixtures

Persist:

```json
{
  "schema_version": 1,
  "requested_backend": "scaleset",
  "effective_backend": "classic",
  "transition_phase": "preparing_scaleset_ineligible",
  "transition_id": "uuid",
  "target_config_revision": "sha256",
  "ownership_revision": "sha256",
  "compatibility_record_id": "sha256",
  "last_proven_barrier": "classic_only",
  "updated_at": "RFC3339"
}
```

Forward phases:

```text
classic_active
preparing_scaleset_ineligible
quiescing_classic
classic_ineligible
activating_scaleset
scaleset_active
```

Reverse phases:

```text
scaleset_active
quiescing_scaleset
scaleset_ineligible
draining_assigned_jit
activating_classic
classic_active
```

### Step 2: Lock activation rules

- `POOL_BACKEND` is requested only.
- Apply cannot advance phase.
- Only authenticated POST `begin-migration`/`rollback-backend` with expected config, ownership, compatibility, and transition revisions may start/continue.
- Restart reads persisted effective state; it never infers activation from cfg.
- Pool/backend edits during transition reject or pause on revision mismatch.

### Step 3: Implement remotely enforced eligibility barriers

Use only the exact barrier proven by the live probe, such as a restricted quarantine group or transition selector. `maxCapacity=0` alone is not accepted unless the gate proves it prevents assignment.

Forward:

1. create exact owned scale sets ineligible for production;
2. prove supervisor/JIT/scheduler/resources/gate health;
3. non-destructively quiesce classic;
4. preserve busy jobs;
5. prove classic remotely ineligible, including busy-to-idle race;
6. make scale sets production eligible;
7. apply positive leased capacity;
8. commit effective scale-set state.

Reverse:

1. make scale sets ineligible for new work;
2. keep sessions/JIT for already assigned/running work;
3. drain to bounded terminal state;
4. make classic remotely eligible;
5. prove classic effective;
6. delete exact owned remote objects by ID;
7. retain tombstones on ambiguity;
8. commit classic effective state.

### Step 4: Define config-edit behavior

- Routing/group edit: new remote spec revision through same barrier.
- Resource-only edit: drain/recreate JIT capacity without remote identity change when safe.
- Pool removal: frozen tombstone until all work/sessions/runners/remote IDs are gone.
- Completed JIT cleanup is allowed in every phase.
- Manual scale, image update, and reconcile are phase-aware.

### Step 5: Crash/failure matrix

Test restart before/after every phase and:

```text
queued, assigned, running, cancelled, reassigned
GitHub 404/409/429/5xx/timeout
helper outage
stale demand
failed exact-ID deletion
config revision change
orphan ambiguity
busy-to-idle assignment race
```

No busy runner is force-stopped. No two production-eligible backends overlap.

### Step 6: Run and commit

```bash
bash tests/backend-migration.sh
bash tests/scale-set-runtime.sh
bash tests/scheduler.sh
bash tests/reconcile-locks.sh
git add src tools/crf-scaleset tests
git commit -m "feat: add durable runner backend migration"
```

## Task 12: Scale-set Settings and Fleet extensions

**Files:**

- Modify: `RunnerFarmSettings.page`
- Modify: `RunnerFarmFleet.page`
- Modify: `include/exec.php`
- Modify: `include/crf-core.php`
- Modify: `include/runner-status.sh`
- Create: `tests/scaleset-ui-behavior.js`
- Extend: `tests/settings-endpoint.php`

### Step 1: Add credential/readiness Settings tests

Cover:

- `AUTH_MODE=pat|github_app` mutual exclusion;
- numeric App/installation IDs;
- root-only atomic private-key storage;
- tmpfs installation token;
- credential rotation invalidates sessions;
- resolved non-default runner group ID and policy;
- gate stale/tampered/mismatched identities;
- operation IDs cannot contain paths/commands;
- saving requested backend does not migrate.

### Step 2: Add readiness UI

Show:

```text
requested backend
effective backend
helper digest/version
module revision
Go version
plugin/image/entrypoint digests
runner group ID/policy
gate age/result
exact invalidation reason
orange Run compatibility test
```

Long operations launch once and poll by opaque ID.

### Step 3: Extend typed Fleet snapshot

Top-level:

```text
requested/effective backend
transition id/phase/progress
compatibility/helper identity
host scheduling budget
operation state
```

Per pool:

```text
assigned jobs and freshness
desired/admitted/blocked
advertised capacity and lease age
session health
ownership/remote ID state
tombstone/orphan state
runner phase counts
```

Do not repeat the full host/gate record per pool.

### Step 4: Add explicit operations

- Orange `Begin fleet migration`.
- Orange `Roll back to classic`.
- Confirmation shows busy/idle/assigned counts, revisions, and consequences.
- Orange `Prewarm to` uses warm target, not assigned demand.
- Enter and click share one single-flight action.
- Exact resource/gate/phase block reason remains inline on failure.

### Step 5: Run and commit

```bash
php tests/settings-endpoint.php
node tests/settings-behavior.js
node tests/fleet-behavior.js
node tests/scaleset-ui-behavior.js
bash tests/php-actions.sh
bash tests/ui-js.sh
git add src tests
git commit -m "feat: add scale-set operations to runner UI"
```

## Task 13: Final packaged-identity gate, live activation, and rollback

**Files:**

- Modify all relevant tests/build/installer files
- Create: `tests/final-release-gate.sh`
- Extend: `docs/deployment/generic-pools-nashost.md`

### Step 1: Run fresh complete verification

```bash
for test in tests/*.sh; do bash "$test"; done
cd tools/crf-scaleset
go test ./...
go test -race ./...
go vet ./...
go mod verify
git diff --exit-code -- go.mod go.sum vendor
cd ../..
find src -type f \( -name '*.php' -o -name '*.page' \) -print0 | xargs -0 -n1 php -l
shellcheck src/usr/local/emhttp/plugins/ci-runner-farm/include/*.sh \
  src/usr/local/emhttp/plugins/ci-runner-farm/event/* tests/*.sh
```

The final release gate must assert every numeric budget from this plan.

### Step 2: Reproducible final package

Build twice, compare byte-for-byte, unpack, and verify:

- helper static identity and module metadata;
- helper explicit 0755;
- shell/entrypoint modes;
- no secrets/test artifacts;
- offline assembly;
- deterministic archive.

### Step 3: Stage exact code on nashost

Repeat Milestone A code-only procedure:

- current state/hash/config/image backup;
- unique staged directory;
- non-destructive maintenance;
- syntax/hash/mode validation;
- recoverable switch;
- authenticated UI smoke.

### Step 4: Rerun compatibility gate against packaged identity

Earlier development evidence is insufficient. Gate must bind the exact installed:

```text
plugin files
helper binary
Go/module metadata
runner image
Dockerfile
entrypoint
owner/API URL
host/installation identity
restricted runner-group ID/policy
```

Require exact cleanup before activation.

### Step 5: Explicitly migrate and run live workloads

Use real workflows for:

- Rust;
- Python;
- TypeScript;
- Go;
- Ops;
- Residential Egress label template, with documented real network configuration separate from the label.

Prove:

- exact label routing;
- simultaneous fair progress;
- zero-to-one wake;
- CPU/memory exhaustion and fragmentation;
- outstanding-poll resource lease;
- cancellation/reassignment;
- helper restart;
- plugin/controller restart;
- host reboot recovery where safe/authorized;
- one pool session failure without peer loss;
- bounded two/four starts;
- stale demand safety plus terminal cleanup;
- Runner/Worker diagnostics and retention;
- no aggregate repository/job detail;
- no sentinel secret leakage;
- no steady-state flash churn;
- helper/process/IPC/lock/call/storage budgets.

### Step 6: Reverse migration

Use the state machine:

1. make scale sets ineligible;
2. preserve assigned/running work;
3. restore classic eligibility;
4. prove classic jobs;
5. delete exact recorded remote IDs;
6. resolve/retain any tombstone explicitly;
7. retain V2 configuration;
8. remove all disposable workflows/repos/groups/containers/state.

Also prove package rollback independently.

### Step 7: Update docs and final commit

Document:

- selector examples;
- labels-not-capabilities warning;
- trusted runner-group requirement;
- classic vs scale-set semantics;
- `Scale to`, `Scale up to`, `Prewarm to`;
- resources and reserves;
- compatibility gate;
- migration/recovery;
- exact rollback;
- diagnostic locations/retention.

Run fresh verification again, then:

```bash
git add .
git commit -m "test: prove scale-set activation and rollback"
```

---

## Final review, publication, and PR

### Step 1: Inspect the complete branch

```bash
git status --short
git log --oneline --decorate main..HEAD
git diff --stat main...HEAD
git diff --check main...HEAD
```

No unrelated files, secrets, live credentials, temporary probe data, package binaries, or nashost backups may be committed.

### Step 2: Fresh final verification

Repeat all shell, PHP, Node, Go, race, vet, vendor, package reproducibility, and diff checks. Do not reuse earlier output as proof.

### Step 3: Push only the user fork

Verify immediately before push:

```bash
test "$(git remote get-url origin)" = "git@github.com:jmagar/ci-runner-farm.git"
test "$(git remote get-url upstream)" = "git@github.com:unraid/ci-runner-farm.git"
git push -u origin HEAD
```

Never run `git push upstream`.

### Step 4: Create the PR

Use `apply_patch` to create `/tmp/ci-runner-farm-pr-body.md` with these completed sections:

```markdown
## Summary
- Milestone A: canonical generic pools, enforced resources, transactional Settings, typed Fleet
- Milestone B: live-gated scale-set supervisor, fair leases, protected JIT, reversible migration

## Safety boundaries
- restricted runner-group and trusted-workload model
- no host Docker socket for V2/scale-set mode
- exact-ID remote ownership and replay-safe ACK protocol
- protected registration/JIT secret handoff

## Verification
- exact commands and fresh results
- nashost packaged-identity gate and live workload results
- classic-to-scale-set and scale-set-to-classic rollback proof

## Upstream
- pushed only to the jmagar fork; official Unraid upstream was not modified
```

Replace every summary bullet with the concrete implemented behavior and exact final results; do not leave template prose in the submitted PR.

```bash
gh pr create \
  --repo jmagar/ci-runner-farm \
  --base main \
  --head "$(git branch --show-current)" \
  --title "feat: add generic resource-aware runner pools" \
  --body-file /tmp/ci-runner-farm-pr-body.md
```

The PR body must summarize both milestones, compatibility-gate status, nashost tests, security boundaries, rollback proof, and exact verification commands/results.

### Step 5: Run Lavra review and address every finding

Review the full PR diff across architecture, security, correctness, performance, tests, UI/accessibility, packaging, and operational rollback. For every actionable finding:

1. reproduce or prove the issue;
2. add a failing regression test;
3. implement the smallest root-cause fix;
4. run focused tests;
5. run the complete final suite;
6. commit;
7. push only `origin`;
8. update the PR.

Do not dismiss a review finding without concrete evidence. Completion requires zero unresolved actionable findings and fresh green verification after the last fix.

---

## Explicitly deferred

Do not add these during this implementation:

- mixed classic/scale-set pools in one effective fleet;
- weighted or preset-specific priority;
- general bin packing/backtracking;
- semantic behavior inferred from preset or label names;
- per-pool images or per-pool GitHub Apps;
- webhook fallback;
- automatic orphan adoption;
- distributed multi-host scheduling;
- hostile multi-tenant isolation claims;
- Prometheus/history dashboards;
- binary IPC;
- cryptographic protection against a malicious local root user;
- a literal 24-hour test as a blocking gate.

Use deterministic simulated-time churn as the blocking test and run any real-duration soak after deployment without weakening the release criteria above.
