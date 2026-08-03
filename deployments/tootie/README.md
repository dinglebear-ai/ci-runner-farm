# Tootie runner image profile

This directory is the source of truth for the customized `ci-runner-farm-runner`
image deployed on Tootie. It captures the fleet-specific Ubuntu 26.04, Rust,
Cargo-profile, MinIO, and Kache configuration that is intentionally more
specialized than the plugin's generic starter Dockerfile.

Kache uses the checksum-pinned `jmagar/kache` fleet release based on upstream
v0.12.0. The binary is installed once in GitHub's tool-cache and exposed through
`/usr/local/bin/kache` as a symlink. This keeps the container supervisor and
`kache-action` clients on the same inode and daemon protocol epoch.

Persistent runners use exact remote lookup and asynchronous uploads, with
speculative prefetch disabled. The supervisor therefore treats a live daemon as
ready and does not enumerate the complete MinIO prefix.

Files:

- `runner.Dockerfile` is the complete reproducible runner image recipe.
- `kache-overlay.Dockerfile` upgrades the currently deployed Tootie image in a
  small, rollback-friendly layer and is the normal fleet rollout path.
- `kache-supervise.sh` owns the container-lifetime daemon without invoking the
  side-effectful `kache daemon status` command.

Run `tests/tootie-kache-profile.sh` before deployment. Copy the full Dockerfile
and supervisor to `/boot/config/plugins/ci-runner-farm/` as the durable rebuild
source. Build the overlay image, then drain and recycle one runner at a time.
