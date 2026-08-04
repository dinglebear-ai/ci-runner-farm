# CI Runner Farm mock clone — design QA

## Source of truth

- Reference: `/home/jmagar/.codex/attachments/aa7816ac-240f-4386-9d9b-f08cedeb0de3/CI Runner Farm for Unraid.html`
- Implementation: `http://127.0.0.1:8787/preview.php?screen=runners`
- Browser viewport: 1440 × 900 CSS pixels
- Device pixel ratio: 1
- Capture density: 1440 × 900 PNG for each viewport capture; the Runner Image full-page pair is 1440 × 1192 PNG.
- Comparison method: the reference and implementation were captured in the same Chromium browser family, at the same viewport and UI state, then placed side-by-side in one combined image and inspected at original resolution. FFmpeg SSIM was used as a secondary signal, not as the visual pass criterion.

## Matched states

| Screen | State used for comparison |
| --- | --- |
| Runners | Queue drawer closed, pool cards expanded, warning visible, autoscale off |
| History | All results, all pools, blank search |
| Logs | All severity levels, follow disabled, blank filter |
| Settings | General tab, clean draft state |
| Pools | Fixed-capacity controls visible, advanced controls closed, clean draft state |
| Runner Image | Default Dockerfile, idle build state, clean draft state |

Live runner telemetry, status badges, queue counts, and log message content remain real dynamic data. Those values can differ between captures; their typography, spacing, color, and container geometry were compared independently.

## Full-view comparison evidence

| Screen | Combined reference + implementation | SSIM | Result |
| --- | --- | ---: | --- |
| Runners | `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-compare-runners-1440-v2.png` | 0.877446 | Passed; remaining pixel variance is live telemetry/content |
| History | `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-compare-history-1440-v2.png` | 0.989927 | Passed |
| Logs | `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-compare-logs-1440-v2.png` | 0.772401 | Passed; remaining pixel variance is live log text and line count |
| Settings | `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-compare-settings-1440-v3.png` | 0.992634 | Passed |
| Pools | `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-compare-pools-1440-v3.png` | 0.967573 | Passed |
| Runner Image | `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-compare-image-full-v3.png` | 0.996215 | Passed |

## Focused comparison evidence

- Header, title, summary tiles, and warning band: `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/typography-compare-header.png`
- Pool heading, table labels, runner rows, and resource typography: `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/typography-compare-fleet.png`
- Runner Image full-page source: `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-source-image-full-v3.png`
- Runner Image full-page implementation: `/home/jmagar/.codex/visualizations/2026/08/03/019fc54b-f234-7e53-9d57-9264d35e33db/final-impl-image-full-v3.png`

## Typography verification

The implementation loads the same extracted Clear Sans WOFF2 assets as the reference. A computed-style audit compared uniquely matched visible text on every screen for `font-family`, `font-size`, `font-weight`, `line-height`, `letter-spacing`, and `text-transform`:

| Screen | Unique visible text matches | Remaining typography differences |
| --- | ---: | ---: |
| Runners | 41 | 0 |
| History | 37 | 0 |
| Logs | 27 | 0 |
| Settings | 43 | 0 |
| Pools | 30 | 0 |
| Runner Image | 51 | 0 |

## Findings and iteration history

| Severity | Finding | Correction | Final status |
| --- | --- | --- | --- |
| P0 | The original plugin lacked the full mock navigation and live History/Logs surfaces. | Added all six wired screens, shared navigation, filters, menus, queue/drawer states, staged settings, pool editing, and Runner Image actions backed by the plugin endpoints. | Resolved |
| P1 | Initial shell, hero, grid, and card geometry diverged from the reference. | Matched the 60 px header, 1440 px content frame, spacing, borders, radii, shadows, responsive collapse, and card/table layouts from measured reference captures. | Resolved |
| P1 | Pools and Settings controls did not initially reflect the same fixed/autoscale and draft/review states. | Implemented the visible modes, review/apply/discard flows, reordering, duplication, add/remove behavior, and shared settings/image draft state. | Resolved |
| P2 | Text appeared heavier and tighter because the fallback stack and several line-height/font shorthands differed. | Switched to the exact source stack and matched headings, labels, small controls, runner ages, keyboard hints, select controls, meter labels, and image actions against computed styles. | Resolved |
| P2 | Dynamic Runners and Logs content reduced whole-frame similarity despite matched layout. | Compared the stable shell and typography separately and confirmed zero computed typography differences while keeping the implementation data live. | Resolved |

No P0, P1, or P2 visual findings remain open.


## Mobile-first verification

The plugin shell and all six application surfaces were audited in Chromium at a **390 × 844 CSS-pixel** mobile viewport with touch emulation enabled.

| Screen | Horizontal overflow | Elements outside viewport | Undersized interactive controls | Active bottom tab |
| --- | ---: | ---: | ---: | --- |
| Runners | 0 | 0 | 0 | Runners |
| History | 0 | 0 | 0 | History |
| Logs | 0 | 0 | 0 | Logs |
| Settings | 0 | 0 | 0 | Settings |
| Pools | 0 | 0 | 0 | Settings |
| Runner Image | 0 | 0 | 0 | Settings |

Every screen rendered at exactly 390 px document/body width. The fixed bottom navigation occupied the full viewport width at 66 px high, respected the active route, and remained above mobile content. The audit also verified no fatal render errors.

### Mobile captures

- Runners: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/runners-390x844.png`
- History: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/history-390x844.png`
- Logs: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/logs-390x844.png`
- Settings: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/settings-390x844.png`
- Pools: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/pools-390x844.png`
- Runner Image: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/image-390x844.png`
- Machine-readable audit: `/home/jmagar/.codex/visualizations/2026/08/03/crf-mobile-polish-e1d6584a/mobile-audit.json`

### Mobile implementation checks

- Root CI Runner Farm route now forwards to the populated Runners surface instead of presenting a blank page.
- Primary navigation becomes a fixed, safe-area-aware bottom bar with route icons and a live runner count.
- Runners, pool rows, queue rows, warnings, menus, and controls reflow into touch-oriented cards and grids.
- History filters, activity rows, run summaries, and rate bars use dedicated mobile layouts.
- Logs remove min-content horizontal expansion and wrap source/message text inside a viewport-bounded reader.
- General Settings, Pools, and Runner Image use 44 px controls, single-column field groups, and mobile review sheets.
- All 31 shell suites, all three behavior suites, patch whitespace checks, and the final release gate passed after the mobile changes.

final result: passed
