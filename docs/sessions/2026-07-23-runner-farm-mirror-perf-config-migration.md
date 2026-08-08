---
date: 2026-07-23 07:08:15 EDT
repo: git@github.com:jmagar/ci-runner-farm.git
branch: feat/settings-page-facelift
head: 9e5f226 (this session's work ended at d68db49; 561a3bb/68bec6e/4a515d3/9e5f226 are a concurrent session's commits)
session id: 0020bc0d-8f3d-473a-ad07-613df24f4fda
transcript: /home/jmagar/.claude/projects/-home-jmagar-workspace-soma/0020bc0d-8f3d-473a-ad07-613df24f4fda.jsonl
working directory: /home/jmagar/workspace/ci-runner-farm
beads: none
---

# Runner farm: mirror fix, hot-path performance, and drain-aware config migration

## User Request

Continuing the ci-runner-farm settings-page facelift, the user directed, across several turns: get the shared image cache (runner mirror) actually working by changing its port; address **all** remaining review performance findings (⑦–⑩); explain why the UI reported "no token configured yet" and "mirror still not working"; and then build — "the correct way" — automatic, drain-aware migration of runners onto config changes as they go idle. Finally: sync nashost to the branch tip, and save this session log.

## Session Overview

Fixed the runner mirror (port collision + an unloadable config key), landed four deferred performance improvements to the fleet-poll hot path and background sweeps, root-caused two stale-log UI confusions, and built a config-generation reconciler that recycles runners onto config changes only while idle (zero jobs killed). Everything was verified live against nashost's running CI fleet, then nashost was synced exactly to the branch tip. A second, concurrent Claude session was found working the same branch; this session did not push the feature branch.

## Sequence of Events

- Made `MIRROR_PORT` loadable (it was absent from `CFG_KEYS`), added a `mirror-up` operator verb, set the port to 5100 on nashost, and brought the mirror up on `172.17.0.1:5100` (serving `/v2/ → 200`).
- Implemented and live-verified the four remaining perf findings: ⑦ parallel per-repo API sweeps, ⑧ in-place fleet render, ⑨ parallel @unraid/ui loader, ⑩ inspect-row read-split.
- Root-caused "no token configured yet" and "mirror still not working" as **stale boot-log lines**; recycled the two idle runners onto the `:5100` mirror and cleared the stale `autoscale.log`.
- Explained the `EPHEMERAL="false"` persistent-runner lifecycle (no code change).
- Built the drain-aware config-migration feature (config-generation stamp + reconciler + Apply hook + UI banner); verified live under real CI load.
- Discovered a concurrent Claude session on the same checkout/branch; synced nashost's live plugin files to the branch tip (`4a515d3`) and confirmed zero drift plus a passing config-parity test.

## Key Findings

- `MIRROR_PORT` was used and documented but not in `CFG_KEYS`, so `load_cfg` silently dropped any cfg override — the real reason the mirror never honored a port change. Host port 5000 was already held by an unrelated `mcp-db-toolbox` container.
- `EPHEMERAL="false"` (the default) makes runners persistent and bakes config at creation; they never self-recycle, so the two running runners kept `registry-mirrors:["http://host.docker.internal:5000"]` (a dead endpoint) in `/etc/docker/daemon.json`.
- "no token configured yet" and the mirror error were **stale** `autoscale.log` tail lines from the last array-start (before the port fix), not current state — `status-json` reported `token:true` and the mirror served `200`.
- The user runs a **second concurrent Claude session** on the same checkout/branch: commits `561a3bb`, `68bec6e`, `4a515d3`, `9e5f226` (authored as the user, Co-Authored Claude) interleaved with this session's; the branch reached `origin` via that session's push — this session never ran `git push`.
- ⑦ measured **25.2s → 4.7s** (5.3×) for the 21-repo stats sweep.

## Technical Decisions

- **Config generation over cfg-diffing:** `crf_confgen()` fingerprints only the settings `build_args` bakes into a container; each runner is stamped with that label and any mismatch is "stale." Live keys the daemons re-read each tick (autoscale thresholds, image-update cadence) are deliberately excluded, so changing them recreates nothing.
- **Drain-aware, idle-only, one-at-a-time recycle:** never touch a busy runner (its job finishes first); migrate one runner per pass so the fleet never loses all capacity at once.
- **Two triggers:** the Settings "Apply" `#command` hook launches a detached drain; the autoscale tick runs the same reconcile as a continuous safety net (covers long jobs, direct cfg edits, and stamps newly created runners).
- **⑧ signature + in-place update** rather than a DOM-diff library — minimal risk, preserves the `<uui-badge>` web components and keyboard focus; the full-rebuild path is unchanged for structural changes.
- **This session log** was committed on an isolated worktree cut from `origin/main` and landed on `main`, to avoid racing the concurrent session on the feature branch.

## Files Changed

Files changed by **this session's** commits (the plugin source lives under `src/usr/local/emhttp/plugins/ci-runner-farm/`):

| status | path | purpose | evidence |
|---|---|---|---|
| modified | `include/runner-farm.sh` | MIRROR_PORT loadable + `mirror-up` verb; parallel `gh_fetch_all` sweeps; inspect-row read-split; `crf_confgen` + reconciler + drain + dispatch verbs + status-json stale count | 2d85472, 601bb38, 9570901, d68db49 |
| modified | `RunnerFarmFleet.page` | in-place volatile-cell render (`crfVolatile` + structural signature); config-migration banner | 822580e, d68db49 |
| modified | `include/crf-core.php` | parallelized @unraid/ui loader; `--crf-info` + `.crf-banner-info` style | 458dcd7, d68db49 |
| modified | `RunnerFarmSettings.page` | Apply `#command` reconcile hook | d68db49 |
| created | `docs/sessions/2026-07-23-runner-farm-mirror-perf-config-migration.md` | this session log | this commit |

Note: `default.cfg`, `include/exec.php`, and `RunnerFarmImage.page` were **deployed** to nashost to sync it to the branch tip, but those file edits belong to the concurrent session's commit `561a3bb`, not to this session.

## Beads Activity

No bead activity observed. `bd list --status open` and `bd ready` returned empty in ci-runner-farm; no beads were created, closed, edited, claimed, assigned, or commented this session.

## Repository Maintenance

- **Plans:** no `docs/plans/` directory exists — nothing to move. Evidence: `ls docs/plans` → "no docs/plans dir".
- **Beads:** no open or ready beads; no tracker changes needed. Evidence: `bd list --status open` and `bd ready` both empty.
- **Worktrees/branches:** the hot feature checkout (`feat/settings-page-facelift` @ `9e5f226`) was left untouched because a concurrent session is actively committing there (`git worktree list` shows it at that SHA). A temporary isolated worktree was created from `origin/main` for this doc only and is removed after landing. A pre-existing scratchpad worktree (`pr33-merged`, detached) was left as-is — out of scope and not safe to prune under an active parallel session.
- **Stale docs:** none contradicted by this session; the plugin's `CLAUDE.md`/`README` were not touched. The concurrent session's `tests/config-parity.sh` passes against the synced files (40 engine keys / 31 UI fields / 32 cfg keys agree).
- **Transparency:** the feature branch reached `origin` via the concurrent session, not this one; this session ran no `git push` other than the isolated docs-only landing described here.

## Tools and Skills Used

- **Shell (Bash):** primary tool — all edits verified with `bash -n`, `shellcheck`, `php -l`, `node --check`; deploys and live tests over SSH to nashost; git inspection and the isolated-worktree landing.
- **Edit / Read / Write:** source edits to `runner-farm.sh`, `crf-core.php`, `RunnerFarmFleet.page`, `RunnerFarmSettings.page`.
- **claude-in-chrome MCP:** live browser verification of the ⑧ in-place render and ⑨ loader on nashost's webGUI (reached via the `*.myunraid.net:31337` cert host). Degraded — the extension repeatedly froze/disconnected (CDP `Runtime.evaluate` timeouts, "renderer may be frozen"); worked around by treating backend `status-json`/`jq` output as the source of truth.
- **vibin:save-to-md skill:** this session log. Its injected git context was for the `soma` repo (the shell's CWD), so all repo facts were re-gathered from `ci-runner-farm`.
- **Subagents:** none spawned in this (post-compaction) portion; a systematic-debugging agent was used earlier to root-cause the mirror startup failure.

## Commands Executed

| command | result |
|---|---|
| `runner-farm.sh mirror-up` (nashost) | mirror up on `172.17.0.1:5100`; `/v2/ → 200` |
| serial vs parallel 21-repo sweep (timed) | serial 25203ms vs parallel ~4700ms |
| `recycle ci-runner-1` / `ci-runner-2` (idle) | both rebaked to `:5100`; `REACHABLE` from inside the runners |
| `reconcile-config` under live load | 4 busy runners untouched; `ci-runner-1` migrated the instant it went idle |
| `crf_confgen` stability check | `278e72a04aab` twice; `eb9916dcfcae` when `MIRROR_PORT` changed |
| full drift scan + `config-parity.sh` | nashost == `4a515d3` for all tracked files; parity `OK` |

## Errors Encountered

- **Mirror "could not start ci-runner-mirror":** root cause — port 5000 held by `mcp-db-toolbox`, and the real docker error was swallowed by `>/dev/null 2>&1`. Resolved by error-capture + port pre-check (pre-compaction) and the operational move to `MIRROR_PORT=5100`.
- **Chrome extension CDP timeouts / frozen renderer:** transient; worked around with backend verification. No data lost.
- **`git log @{u}..HEAD` initially empty despite six local commits:** investigated and explained — the concurrent session had already pushed the branch (local was in sync with `origin`), so nothing was "unpushed" from this session's view.

## Behavior Changes (Before/After)

| area | before | after |
|---|---|---|
| baked config change | running runners kept old config until a manual fleet Restart | runners auto-migrate onto the new config as they go idle; busy runners finish first |
| `MIRROR_PORT` in cfg | silently ignored (not in `CFG_KEYS`) | honored |
| fleet 5s poll render | full `innerHTML` rebuild (uui-badge churn, focus/selection loss) | in-place volatile-cell update when structure unchanged |
| background API sweeps | sequential per-repo curls | concurrent, chunked (`gh_fetch_all`) |
| Fleet tab | no config-migration visibility | "N runners updating to the new configuration" banner |

## Verification Evidence

| command | expected | actual | status |
|---|---|---|---|
| `crf_confgen` twice + MIRROR_PORT change | stable, then differs | `278e72…` twice, `eb9916…` on change | pass |
| reconcile under real load | busy untouched, idle migrate | 4 busy held; `ci-runner-1` migrated on idle | pass |
| migrated runner mirror | `:5100` + reachable | `registry-mirrors:[…5100]`, `REACHABLE` | pass |
| ⑦ sweep latency | far under 25s serial | 4.7s | pass |
| full drift scan | nashost == branch tip | zero drift | pass |
| `config-parity.sh` | OK | OK (40/31/32) | pass |
| `status-json` | token set, no stale | `{token:true,count:2,stale:0}` | pass |

## Risks and Rollback

- Auto-migration recycles runners: idle-only + one-per-pass bounds the blast radius; a job outlasting `IMAGE_DRAIN_TIMEOUT` (default 3600s) is logged and migrates on its next idle. Rollback: revert `d68db49` — runners then keep old config until a manual Restart (prior behavior).
- On deploy/update, unstamped (pre-feature) runners are treated as stale and migrate once — a one-time, drain-aware self-healing pass.
- The running autoscale daemon must be restarted onto the new code to stamp newly created runners (done on nashost during testing).

## Decisions Not Taken

- A full DOM-diff library for ⑧ — rejected as over-engineering; a structural signature plus in-place update is lower risk.
- Caching the processed @unraid/ui CSS (⑨) — rejected (stale-style risk after a bundle update); parallelized the fetches instead.
- Grandfathering unstamped runners as "current" — rejected (it would skip the first config change); unstamped reads as stale and self-heals.
- A standalone reconcile daemon — folded reconcile into the existing autoscale tick plus the Apply-triggered drain instead.

## References

- Branch `feat/settings-page-facelift`; this session's commits `2d85472`, `822580e`, `601bb38`, `458dcd7`, `9570901`, `d68db49`.
- nashost webGUI: `http://…:6969` redirects to the `*.myunraid.net:31337` HTTPS cert host.

## Open Questions

- The concurrent session's `9e5f226` ("harden reconcile + widget") modifies this session's reconcile code; its exact changes were not reviewed here — worth confirming they compose with the drain-aware design.
- Reconcile-recycle interaction with autoscale scale math is verified only up to a 4-runner fleet; behavior at larger fleets is untested.

## Next Steps

- The concurrent session appears to own the feature branch and nashost deploys going forward — coordinate to avoid double-deploying to the same box.
- If desired, review `9e5f226`'s reconcile hardening against `d68db49` and reconcile any overlap.
- No code push is pending from this session; the feature branch is already on `origin` at the concurrent session's tip, with this session's commits included. This session log lands on `main` independently.
