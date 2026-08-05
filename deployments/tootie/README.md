# Tootie runner image profile

This directory is the source of truth for the customized `ci-runner-farm-runner`
image deployed on Tootie. It captures the fleet-specific Ubuntu 26.04, Rust,
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

The persistent Tootie profile targets 16 runners: six Rust runners at 6 CPUs
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
- `kache-overlay.Dockerfile` upgrades the currently deployed Tootie image in a
  small, rollback-friendly layer and is the normal fleet rollout path.
- `kache-supervise.sh` owns the container-lifetime daemon without invoking the
  side-effectful `kache daemon status` command.

Run `tests/tootie-kache-profile.sh` before deployment. Copy the full Dockerfile
and supervisor to `/boot/config/plugins/ci-runner-farm/` as the durable rebuild
source. Build the overlay image, then drain and recycle one runner at a time.
