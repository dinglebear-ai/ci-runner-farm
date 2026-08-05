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

Files:

- `runner.Dockerfile` is the complete reproducible runner image recipe.
- `kache-overlay.Dockerfile` upgrades the currently deployed Nashost image in a
  small, rollback-friendly layer and is the normal fleet rollout path.
- `kache-supervise.sh` owns the container-lifetime daemon without invoking the
  side-effectful `kache daemon status` command.

Run `tests/nashost-kache-profile.sh` before deployment. Copy the full Dockerfile
and supervisor to `/boot/config/plugins/ci-runner-farm/` as the durable rebuild
source. Build the overlay image, then drain and recycle one runner at a time.
