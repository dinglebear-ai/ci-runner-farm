**CI Runner Farm**

Self-hosted GitHub Actions runners for Unraid &mdash; a utilization-aware fleet
of docker-in-docker runners with routed capacity pools, a shared image cache,
and warm package caches.

Runner pools reserve Rust, Python, TypeScript, or other capacity behind derived
labels such as `ci-pool-rust`. Target them with
`runs-on: ci-pool-rust`. Pools require organization scope and a
nonzero minimum; autoscaling uses live busy/idle headroom, not per-label GitHub
queue depth.

Pool labels are scheduling routes, not security boundaries. Every pool shares
the host kernel, image, network policy, privileged Docker setting, caches, and
the plugin's one global runner group.
