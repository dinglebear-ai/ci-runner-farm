# Native U8 parity work

Target: GitHub Actions behavior in Farm main `902937c` (v1.16.0), native U8 API
1.44.0. GitLab is explicitly excluded by the operator. Existing classic release,
Go allocator, ownership epochs, receipt fences and QA protocol remain supported.
This matrix tracks implementation; it is not appliance qualification.

| Capability | Authoritative existing owner | Native route implemented locally | Evidence required |
|---|---|---|---|
| Fleet start/stop/restart/scale/recycle | `include/runner-farm.sh` command dispatch; `providers/github.sh` | Typed native backend jobs + Fleet controls | Engine tests, operation/ownership tests, real job |
| Scope, repos/org, runner group and labels | `include/runner-farm.sh` CFG_KEYS; `RunnerFarmSettings.page` | Native settings using same protected config parser | Round trip/invalid config/persistence |
| PAT / GitHub App / private registry credentials | `include/exec.php`; `include/github-app.sh` | Write-only private credential operations over local root-only socket | No secrets in output/logs/argv, atomic writes, rotation/clear |
| Named size pools and CPU pinning | `include/runner-pools.sh`; `include/cpu-pinning.sh` | Same engine validation/config fields | Existing pool/pinning tests + native UI |
| Shared admission and standalone owner initialization | `pkg/hostcapacity`; `internal/capacitycmd`; `include/shared-capacity.sh` | Same controller, same FD8 fleet lock; no second allocator | Existing Go compatibility/race and shared-host qualification |
| Autoscaling / elastic / queued demand | `include/build-demand.php`; engine autoscale ticks | Native daemon owns foreground ticks; no detached shell daemons | Demand and ownership tests, actual queue |
| Image source, Dockerfile editing/build, update/drain | engine build/imageupdate functions; default GitHub Dockerfile | Native Runner Image section and owned jobs | Build/cancel/recovery + actual artifact |
| Network isolation, registry mirror, KVM, cache/workspace/share mounts | existing provider/preflight/resource owners | Same engine effects with native settings/storage bindings | Resource/ownership tests, Fedora enforcing |
| Runtime status, per-runner and Farm/build logs | engine status/log dispatch and redaction | Bounded native snapshots/logs | Secret redaction + UI empty/error distinctions |
| Recommendations and bounded history | `runner-recommendations.sh`, `runner-history.sh` | Same engine reports and owned refresh cadence | Existing recommendation/history tests |
| Cache usage / package cache clear / retired and completed Docker stores | existing cache/prune commands | Explicit scoped native controls, destructive confirmation | Existing safe-path/cache tests |
| Lifecycle startup/restart/unload/abort/reboot | classic PLG/events detach workers today | NativeService + responsive bounded operations; unload must not orphan a live fleet | Active-work unload refusal, abort, supervision, restart/reboot |
| Classic-to-native migration | existing ledger/owner state | Explicit fenced handoff, no implicit adoption/reset | Existing workload preservation + rollback |

Until the native routes and their evidence exist, a feature remains incomplete.
Fresh-host operational testing and existing-host migration are separate claims.
Native installation is through Core's supported plugin lifecycle. No changes to
Tower or real GitHub registrations are part of local implementation.

## Local implementation status

Native routes exist for the matrix above, including explicit supported-retirement
migration and journaled standalone initialization recovery. Migration inspection
is read-only and supervised; it rejects classic runtime, boot replay and orphan
creators. The operator retires the old plugin through its existing Plugin
Manager lifecycle (after jobs finish), binds the exact retained cache folder in
Core, then completes the native handoff. Settings, credentials, ledger, receipts
and existing ownership epoch stay in place. An existing Farm-owned shared policy
is pinned exclusively while the handoff record commits. Legacy QA-owned shared
admission must use its existing fenced ownership transfer; this UI replacement
never creates a second budget or resets an owner.

Initialization journals the original owner before atomic non-replacing policy
publication. Recovery replays the original controller under fleet.lock and an
exclusive policy lease, matching both epoch and complete normalized owner
identity. It supports interruption before policy publication, during adoption,
and after policy activation but before start closure removal. Existing grants,
fences and receipts are retained by idempotent adoption. Unknown or pre-journal
ownership requires operator review rather than an invented recovery identity.

Native effects receive the exact Core-held cache binding. Both config save and
mutable shell snapshots reject effects against another cache path. Selecting a
dedicated existing folder preserves that folder; a pool-root selection receives
a dedicated runner-farm leaf. These are local implementation claims, not live
migration, Core lifecycle or appliance qualification.

Native service restart preference is persisted only after an explicit backend
start. The plugin-owned activation child restores it after capability admission;
it cannot restart during unload. Fleet scheduling is separately enabled only
by a successful explicit start/restart/positive scale; stop or scale0 disables it. Startup restoration reuses the original bounded readiness workflow once per backend activation; ordinary maintenance never schedules recurring fullstart commands. Existing Go controller tests and
shell/provider tests remain the source compatibility checks. New native tests
cover request typing, jobs/busy/cancellation/unload, private credentials,
redaction, engine projection and foreground worker/drain ownership. Browser
layout, Fedora enforcing policy, live Docker/GitHub operations, reboot and
existing-owner migration still require target-specific qualification.

## U7 control-level audit (next candidate after spike.3)

The broad matrix above was insufficient to establish every U7 control. This
second pass inventories the shipped GitHub-facing pages and exec adapter, not
just backend verbs. GitLab controls remain explicitly outside scope.

| U7 feature / source | Native implementation / current local status | Remaining qualification |
|---|---|---|
| Fleet start, stop, restart, validate and scale0–64 (`RunnerFarmFleet.page`, `exec.php`) | `ManageLive`, typed `ValidateOperation`, same engine; explicit disruptive confirmation | Real isolated fleet/job, validate container and failed/cancelled effects |
| Runner identity, pool, phase, current job/link, repository/branch and resource detail (`RunnerFarmFleet.page`) | Native live Fleet table, safe HTTP(S) links, complete details retained | Actual running/busy/idle/disconnected rows; narrow viewport and keyboard |
| Fleet refresh and queue/outcome/cache tiles (`RunnerFarmFleet.page`) | Native bounded overview composes same engine status and cached JSON readers; serialized poll, cached ages displayed, unknown remains unavailable | Live cache freshness and provider outage; no new remote polling from overview |
| Job-weight recommendations and history advisory (`RunnerFarmFleet.page`) | Native summary, priorities and job class/score/pool; complete report preserved | Current/history samples and empty/unavailable distinction |
| Owned runner log/recycle and Farm/build logs (`exec.php`) | Existing bounded controls/operations and redaction; source engine remains owner | Actual log streams, recycle busy/failure, credential redaction |
| Every non-GitLab configuration key (`RunnerFarmSettings.page`, engine CFG_KEYS) | Existing exact parser schema exposed; Core cache binding overrides form data | Invalid enum/numeric/pool, save/reconcile/persistence and restart |
| Reset-to-defaults preview (`RunnerFarmSettings.page:crfResetDefaults`) | New read-only defaults preview through original parser; preserves current Core cache, saves only on explicit submission | Browser form edits/reset/save and persistence |
| PAT creation presets (`RunnerFarmSettings.page:crfGetPat`) | Native repo/org plus optional GHCR and registry-only links with exact classic scopes | Browser links; use isolated target credentials for registration |
| Configured credential status, write-only PAT/App key/registry save and credential removal (`exec.php`, settings page) | Presence-only status; private files and serialized removal; values never returned | Minimal credential validity + rotation/revocation/cleanup effects |
| Dockerfile saved-provider / legacy-unsuffixed / shipped-default fallback (`exec.php`, image page) | New exact fallback ordering; load does not mutate legacy file | Retained classic custom Dockerfile migration |
| Dockerfile 2MiB boundary, nonempty/NUL validation (`exec.php`) | Restored bound; bounded root-local JSON budget accommodates worst-case escaping, eight slots/deadline retained | Actual Core browser/IPC boundary with large file |
| Rust/Python/Node/Android insert/remove (`RunnerFarmImage.page`) | Snippets projected deterministically from classic authored blocks into backend data; native form preview, unknown/partial marker refusal | Real editor submission, unsaved edits and keyboard; explicitly authorized image build |
| Save Dockerfile, reset to shipped default, Save+Build and independent Build (`RunnerFarmImage.page`) | Native controls; Save+Build one owned job with save before build and hour budget | Real image, build progress/cancel/failure and resulting runner |
| Image local/remote choice, registry login, auto-update and drain (`RunnerFarmSettings.page`, engine) | Existing settings/owned ticks and one-pass drain preserved | Busy runner update/rollback and private registry |
| Named pools, CPU pinning, memory, ephemeral/root, cache/workspace/share mounts (`runner-pools.sh`, `cpu-pinning.sh`, provider) | Same validators/planners/provider; exact Core-held cache | Real Docker resource/mount result and release fences |
| DinD, host Docker socket, shared image mirror, KVM and strict network/artifact exception (`providers/github.sh`, engine) | Same privileged engine; ordinary Core container workloads do not bypass ownership | Fedora policy, network effects, KVM and mixed workload isolation |
| Autoscaling, elastic bounds, queued build demand, lifecycle replacement (`include/*`, native scheduler) | Existing foreground owner and controller; no detached classic workers; stop/scale0 revoke creator authority first | Real queue growth/shrink, busy retention and failed/cancelled stop |
| Package cache clear, all-cache prune, completed/retired Docker preview/apply (engine) | Existing engine safety; missing retired-store apply UI added with confirmation | Task-owned paths only; live refusal while active and correct preview/apply |
| Dashboard enable/disable (`RunnerFarmDashboard.page`) | Setting now gates native reporting before Docker inspection; Core owns tile placement/removal | Native dashboard interaction and disabled reporting; U8 tile customization differs from classic Cond |
| Standalone/shared admission, existing owner migration and interrupted initialization | Reviewed spike.3 journal/fence/identity/cache work retained; same ledger/epochs/QA protocol | Root-owned FD8, boot filesystem, actual migration/rollback and shared QA consumer |
| Install/update/withdraw/abort/service restoration/reboot | Supported native Core lifecycle and existing reviewed managed ownership | Current API admission, Core storage claim, unload busy/failure, restart/reboot, enforcing SELinux |

This audit does not convert authored/native harness checks into appliance
acceptance. The current target reported by the coordinator is API1.47; saved
API1.44 remains a structural compatibility baseline only. Next qualification
should first exercise native admission, storage binding, managed backend and
read-only/defaults/image-edit controls without GitHub effects. Real runner
provisioning then needs an explicitly selected disposable repository/scope,
write-only credentials, a bounded runner/job budget and coordinated cleanup.
