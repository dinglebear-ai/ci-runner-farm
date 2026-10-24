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
