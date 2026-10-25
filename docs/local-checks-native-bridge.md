# Native local-checks worker bridge

This is a source protocol/integration checkpoint. It is not installed or
operational on an appliance. `NativeWorkerContract().runtimeQualified` remains
false. Existing four-host coordinator and queue files are unchanged.

## Reused source owners

The existing worker coordinator transfers
`history.pack` and `snapshots.pack`, with exact commit/base/merge-base and each
pack's size/SHA256. `FleetSnapshot` accepts that exact manifest, requires exactly
those two artifacts, checks a combined 1 GiB ceiling, rejects symlinks/changed
files and verifies both hashes. Its canonical identity is compact JSON with
lexicographically sorted object keys and no newline; Python can use
`json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True)`.

The coordinator's queue, reservations and transfer remain authoritative. Farm
does not introduce another scheduler. The currently installed coordinator's
direct host-Docker execution is not a Farm admission proof: its memory value is
an admission estimate and its host execution lock is separate from Farm's ledger.

`WithNativeWorker` reuses the exact inherited native FD8 verifier and the existing
Farm host policy lease/epoch. It charges the existing `build` pool with a distinct
`local-checks:<requestID>` request. No consumer pool or extra budget is created.
Receipts are versioned and epoch-bound in a dedicated private child directory.
Intent precedes broker admission and start; a lost start result retains its
grant/receipt and refuses replay. Known queued intent may retry the same request.

Completion requires an observed stopped immutable container, exact removal and
positive absence before fenced release. Unknown disappearance of a grant is
refused across repeated cleanup calls. A durable prior release-intent permits
recovery after an already completed release. Unknown outcomes never authorize
creating another job/request identity.

`DockerNativeDriver` implements bounded actual Docker inspect/start/remove
commands against the local daemon. It checks pinned image identity, role/source/
request labels, exact hard CPU/memory, a private cgroup namespace, no host PID or
network mode, and exactly the configured read-only source and private DinD store
mounts. It refuses a host Docker socket or unexpected bind. Negative inspect
alone is not absence: an empty exact-ID inventory and live daemon identity are
also required. Tests exercise its parser with fixtures; no real Docker mutation
or appliance isolation qualification has been executed.

## Closed command handshake

Protocol: `farm-local-checks-worker/v1`; role: `local-checks`.

- `admit-start` carries the exact submission, immutable container ID and expected
  policy epoch. It accepts no caller-selected image/path/daemon/command/token.
- `complete` carries only the exact request ID and expected epoch.
- `NativeConfiguration` comes from the native plugin's protected storage and
  image bindings, never from that request.
- `HandleNativeCommand` verifies the current two-pack manifest/checksums and
  reconstructed checkout before entering the typed admission path.

## Remaining owner integration before activation

1. Register this role with native Farm lifecycle inventory. Existing GitHub
   reconciliation/retirement currently treats every build-pool grant as a
   GitHub slot. It must delegate only positively attested local-checks receipts
   to their owner, and keep refusing unknown owners. It must not simply ignore
   unknown grants or reset the ledger. Unload/retirement must preserve active
   local jobs and their exact grants.
2. Add Farm-owned creation of the inert dedicated worker and its private DinD
   store using the reviewed image/bootstrap contract. The coordinator must not
   create a privileged worker by bypassing native ownership/journaling.
3. Add execution transport into that already charged worker, with the existing
   fixed Core entrypoint and protected credential injection. All nested Docker
   work must remain inside the worker's private daemon and charged cgroup.
4. Expose the typed handler through the existing native backend/helper and
   protected bindings; package, independently review and qualify that exact
   artifact before advertising runtime readiness.
5. Change the external coordinator in four small places: probe the native
   contract on Farm hosts; hand over its existing canonical pack manifest;
   delegate prepare/admit/execute/cancel to the native role; commit terminal
   evidence and call completion before releasing its queue reservation. A
   retained native queue/uncertain operation is not a no-effect `busy` refusal
   and must not be blindly retried on another host.

Until these gates pass, the four-host dispatcher's host-Docker path must not be
presented as Farm-integrated execution, and these source tests must not be
presented as a full Core local sign-off or four-host deployment.

## Native helper and bounded process transport

The root-only backend exposes `local-checks-contract` and `local-checks` through
its existing Unix socket/job lifetime. A `local-checks` request's `value` is the
closed `farm-local-checks-worker/v1` command. Only execution additionally accepts
`values.dependencyCredential`, delivered transiently by the existing coordinator
credential owner. No request can select a command, executable, image, path,
Docker daemon, host policy or epoch. The existing backend cancellation and
unload gates cover these jobs.

The backend obtains the existing fleet lock and passes its actual open file as
FD8 to the same native executable's `--local-checks` helper. Stdin contains
compact command JSON, one newline, then the optional dependency credential with
no trailing newline. The bounded decoder accepts that credential only for
`execute`. It becomes `EX_STANDARDS_TOKEN` only in memory and then enters the
worker over `docker exec --interactive` stdin. It is excluded from arguments,
Docker Config.Env, manifests and receipts; log output is redacted before durable
writes. This reuses the existing coordinator's dependency-access identity; it
does not reuse the unrelated QA provisioning token or create a credential store.

A reviewed root-owned mode-0600 `native-local-checks.json` beneath the native
plugin's Core settings binding defines version=1, host, epoch, immutable image,
private job root and `runtimeQualified`. That file is deliberately not generated
or installed by this source change. Unqualified bindings refuse ordinary checks. The
published source contract still reports runtime qualification false. A separate
bounded exact-image qualification must precede enabling real checks; merely
setting a flag is not qualification evidence.

The `create-admit` action verifies the coordinator's canonical two-pack manifest
and clean committed checkout, then journals creation intent before the sole
Docker create attempt. The inert worker uses the pinned image's existing cgroup
bootstrap followed by a fixed private dockerd, with hard CPU/memory/swap/PID
limits, no host Docker socket and only the exact readonly source/private DinD
mounts. Its immutable ID is committed before existing build-pool admission and
start. Docker readiness is limited to six attempts within twelve seconds and
requires Docker 26+ for Core's volume-subpath mounts. Uncertain creation/start
retains its intent/charge and refuses automatic replay.

The `execute` action accepts only the existing request identity. It revalidates
receipt, epoch, fence, actual worker binding and resource charge, then invokes
the fixed Core checks script in that worker. The complete worker is stopped on
success, failure or cancellation before positively proven absence and fenced
release. An uncertain stop retains the existing charge. Full Core acceptance,
nested kernel-limit qualification and four-host coordinator activation remain
separate from these local source/transport tests.


## Qualification before enabling checks

The closed `qualify` action is permitted with `runtimeQualified=false`; it cannot
execute repository commands or accept credentials. It still verifies the actual
committed two-pack snapshot, inherits the same fleet FD8 and policy epoch, and
uses the same existing build-pool charge. Its request is bounded to at most two
CPUs, 12 GiB memory, 180 seconds and 1–8 GiB requested scratch. Available bytes
are checked before creation. This is a free-space preflight, not a filesystem
quota or disk-isolation proof.

The fixed existing image bootstrap starts only private dockerd. The packaged
static helper reads actual cgroup-v2 CPU/memory/swap/PID limits and counts only
process comm names to reject Runner.Listener. A scratch inner image contains
only that same helper; it needs no registry pull or dependency credential. Its
fixed read-only, non-root, no-network nested run proves 1 CPU, 64 MiB memory,
zero swap and 64 PIDs. The outer probe must match the worker's exact charge.
The proof records `scope=cgroup-isolation-only`, image/probe hashes, both actual
limits, and `diskQuotaEnforced=false` before stopping/removing the worker and
fenced release. It does not run Core tests, establish PR sign-off or promote the
runtime-qualified flag.

`cancel` and `complete` remain available for an existing owned request while the
binding is unqualified. An uncertain stop retains its charge and can be retried
only through that same owner and identity. Unsupported qualifier/stop drivers
are refused before creation. Unknown creation effects still require explicit
owner recovery rather than replay with a new request ID.
