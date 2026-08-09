# Nashost runner image profile

This directory is the source of truth for the customized `ci-runner-farm-runner`
image deployed on Nashost. It captures the fleet-specific Ubuntu 26.04, Rust,
Cargo-profile, MinIO, and Kache configuration that is intentionally more
specialized than the plugin's generic starter Dockerfile.

Kache uses the checksum-pinned upstream `kunobi-ninja/kache` v0.13.0 release.
The binary is installed once in GitHub's tool-cache and exposed through
`/usr/local/bin/kache` as a symlink. This keeps the container supervisor and
`kache-action` clients on the same inode and daemon protocol epoch.

Persistent runners use exact remote lookup and asynchronous uploads, with
speculative prefetch disabled. The supervisor therefore treats a live daemon as
ready and does not enumerate the complete MinIO prefix.

## Current resource envelope

The persistent Nashost profile targets 16 runners: six Rust runners at 6 CPUs
and 7 GiB, one Python runner at 2 CPUs and 6 GiB, three TypeScript runners at
2 CPUs and 6 GiB, three Ops runners at 2 CPUs and 6 GiB, plus one 8-CPU/10-GiB
runner for each of Go, System, and Residential Egress. The pools reserve 74 CPUs
and 114 GiB in total.

With a 77-CPU budget, 1-CPU host reserve, 124-GiB memory budget, and 8-GiB host
reserve, the admission controller exposes 76 CPUs and 116 GiB. This leaves
2 CPUs and 2 GiB of admitted headroom. The single Python slot is intentional: it
keeps six Rust workers available for the dominant queue without weakening the
host reserves or overcommitting memory.

Before any drain or reconciliation, verify that
`ci-runner-farm-runner:latest` resolves to the approved image and that a
pristine container reports Kache 0.13.0 with SHA-256
`5490686480adca08df1849d6dfba449e7e898e187135a452cfa6c6c40f9ff972`.
Temporary compatibility images must keep a distinct tag and must never replace
fleet `latest`.

Files:

- `runner.Dockerfile` is the complete reproducible runner image recipe.
- `kache-overlay.Dockerfile` upgrades the currently deployed Nashost image in a
  small, rollback-friendly layer and is the normal fleet rollout path.
- `endpoint-validation.sh` is the single Kache/Gotify endpoint contract used by
  image builds, the installer, and the scheduled audit.
- `kache-supervise.sh` owns the container-lifetime daemon without invoking the
  side-effectful `kache daemon status` command.

Run `tests/nashost-kache-profile.sh` before deployment. Copy the full Dockerfile
and both supporting shell scripts to `/boot/config/plugins/ci-runner-farm/` as
the durable rebuild source. The public recipes intentionally contain no private endpoint. Inject the
approved endpoint explicitly when building either recipe. Persist it once for
the plugin's **Save + Build Candidate** path as a protected, one-line input:

```bash
: "${KACHE_REMOTE_ENDPOINT:?set the approved Nashost Kache endpoint}"
printf '%s\n' "$KACHE_REMOTE_ENDPOINT" | sudo install -m 0600 /dev/stdin \
  /boot/config/plugins/ci-runner-farm/kache-endpoint
```

The candidate builder reads that file only for Dockerfiles that declare
`ARG KACHE_REMOTE_ENDPOINT`; the value is not included in settings, status JSON,
or engine log messages. For a direct command-line build, pass the same value:

```bash
: "${KACHE_REMOTE_ENDPOINT:?set the approved Nashost Kache endpoint}"
docker build \
  --build-arg KACHE_REMOTE_ENDPOINT="$KACHE_REMOTE_ENDPOINT" \
  -f deployments/nashost/kache-overlay.Dockerfile \
  deployments/nashost
```

Omitting the argument, supplying a documentation-only address, or including
quotes, backslashes, whitespace, control characters, credentials, or a malformed
authority fails the build before the Kache configuration is written. Build the
overlay image, then drain and recycle one runner at a time.

## Safe image promotion

Local image builds are candidates, not releases. **Save + Build Candidate** creates
an immutable `candidate-<dockerfile-sha>-<time>-<pid>` tag and records the exact
Docker image ID. **Promote Verified Candidate** rechecks both values before it can
move `ci-runner-farm-runner:latest`. Experimental or compatibility builds must
keep distinct tags; never call `docker tag ...:latest` outside this promotion
path. Verify a pristine candidate's Kache version and SHA-256 before promotion.

## Exclusive fleet mutations

Claim an ownership lease for multi-step maintenance so another shell, the UI, or
a daemon tick cannot interleave a recycle or reconciliation:

```bash
engine=/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
owner="nashost-maintenance-$(date +%s)"
$engine mutation-owner-claim "$owner" 1800
CRF_MUTATION_OWNER="$owner" $engine reconcile-config
# Additional guarded scale/recycle/start/stop commands go here.
$engine mutation-owner-release "$owner"
```

The lease expires automatically, is invalidated across reboot, and is stored as
a mode-0600 state file. Daemon mutation ticks skip while another owner holds the
lease. Do not reuse an owner's token from an unrelated session.

## Daily fleet audit

Install the persistent Unraid User Scripts audit after installing the matching
plugin release:

```bash
cd deployments/nashost
sudo CRF_EXPECTED_KACHE_ENDPOINT="$KACHE_REMOTE_ENDPOINT" \
  ./install-fleet-audit.sh
```

The endpoint is required on first install and is persisted in the mode-0600 audit
environment. Later installer runs preserve that value when the environment
variable is omitted. Export the approved Nashost endpoint before running either
command; the repository deliberately provides no plausible fallback value.

Gotify has no executable hostname fallback either. If notifications are enabled,
create the shared environment with both the explicitly approved URL and token
before installing the audit:

```bash
sudo install -m 0600 /dev/null /boot/config/plugins/user.scripts/gotify.env
sudoedit /boot/config/plugins/user.scripts/gotify.env
# GOTIFY_URL='https://approved-gotify.example'
# GOTIFY_TOKEN='replace-with-the-dedicated-app-token'
```

A token without a URL, a non-HTTPS URL (except exact localhost/127.0.0.1
loopback), an unsafe URL, or a failed HTTP delivery makes the audit
nonzero and records `notification_result=FAIL` in its timestamped log. The token
is carried only in a mode-0600 temporary curl configuration and is never written
to audit output. Omitting the token disables Gotify without inventing a target.

The installer preserves existing User Scripts schedules, registers a daily
06:30 run, writes logs under `/mnt/user/logs/ci-runner-farm-audit`, and pins the
installed plugin package SHA-256 in a mode-0600 audit environment. The audit
requires exactly 16 online GitHub identities with exact labels, the approved
runner image and Kache binary, one Kache supervisor and daemon per runner, the
expected resource envelope and 2-CPU/2-GiB headroom, no reconciliation or active
mutation owner, and one stable watchdog. Failures create both an Unraid alert and
a high-priority Gotify message; successful daily audits send a low-priority
Gotify receipt. Set `CRF_NOTIFY_SUCCESS=false` in the audit environment to silence
success receipts while retaining failure alerts. Every run leaves a complete
timestamped log in place.

## Evidence retention and cleanup

Before deleting incident artifacts, copy the selected status snapshots, audit
outputs, helper scripts, image inspection/history, and plugin metadata into a
dated directory below `/mnt/user/logs/ci-runner-farm-audit/forensics/`. Generate
a SHA-256 manifest and tarball, verify them, then delete only an explicit
allowlist of temporary files and obsolete worktrees. Remove a forensic Docker
tag only after recording its image ID and proving no container references it.
