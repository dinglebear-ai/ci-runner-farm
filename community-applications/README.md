# Community Applications listing

Everything needed to list **CI Runner Farm** on Unraid
[Community Applications](https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/community-applications/)
(CA). CA scrapes a maintainer's template repo: one `*.xml` per plugin plus a
single `ca_profile.xml`. These files are served raw from this repo.

## Files here

| File | Purpose |
|---|---|
| [`ci-runner-farm.xml`](ci-runner-farm.xml) | CA plugin template — name, description, category, icon, `PluginURL`, support/project links. |
| [`ca_profile.xml`](ca_profile.xml) | Maintainer profile shown next to the listing. |
| [`ci-runner-farm.png`](ci-runner-farm.png) | 256×256 listing icon (source: [`ci-runner-farm.svg`](ci-runner-farm.svg)). |
| [`DESCRIPTION.md`](DESCRIPTION.md) | Copy for the CA listing and the forum support thread. |

`PluginURL` points at `releases/latest/download/ci-runner-farm.plg`, so CA always
installs the newest published release, and Unraid's "check for updates" resolves
from the same URL.

## Prerequisites (must be true before CA can list this)

1. **Public repository — satisfied.** `dinglebear-ai/ci-runner-farm` is public,
   so CA can fetch the plugin, template XML, icon, and screenshot over
   unauthenticated HTTPS.
2. **Published release — satisfied.** GitHub Releases publishes
   `ci-runner-farm.plg` at `releases/latest/download/…` through release-please.
3. **Dedicated support thread — still required.** CA submissions require an
   Unraid forums support thread. After creating it, replace the GitHub Issues
   stand-in in `<Support>` inside `ci-runner-farm.xml`. The maintainer
   `<Forum>` already points at the verified `limetech` administrator profile.

## Submit

Use the Community Applications submission flow
(https://unraid.net/community/apps — "Submit"). It parses the template XML,
validates `ca_profile.xml`, checks for duplicates, and previews the listing.
Point it at the raw URLs:

- Template: `https://raw.githubusercontent.com/dinglebear-ai/ci-runner-farm/main/community-applications/ci-runner-farm.xml`
- Profile:  `https://raw.githubusercontent.com/dinglebear-ai/ci-runner-farm/main/community-applications/ca_profile.xml`

The CA moderation team then vets it for security, functionality, and design
before it goes live.

## Regenerating the icon

```bash
rsvg-convert -w 256 -h 256 ci-runner-farm.svg -o ci-runner-farm.png
```

## Pre-submission checklist

- [x] Repo is **public**
- [x] A GitHub Release exists with `ci-runner-farm.plg` attached
- [ ] Installed the released `.plg` on a clean Unraid box and verified it works
- [ ] Forum support thread created and `<Support>` updated to its URL
- [ ] Raw URLs for the template, profile, icon, and screenshot all load in a browser
- [ ] Submitted via the CA portal and passed the preview/validation
