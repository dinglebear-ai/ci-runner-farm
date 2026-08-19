# Distributed Runner Farm

This directory is the source of truth for the multi-device CI Runner Farm design and implementation.

The design extends the existing single-host Unraid runner farm into one logical farm with a central control plane and portable node agents. The current Unraid implementation remains a supported local execution backend.

## Documents

- [spec.md](spec.md) defines scope, invariants, and acceptance criteria.
- [architecture.md](architecture.md) defines controller, node, scheduling, cache, and failure topology.
- [protocol-contract.md](protocol-contract.md) defines the versioned controller/node wire and transport contract.
- [controller-config.md](controller-config.md) defines the strict portable controller configuration and sidecar supervision contract.
- [runner-packages.md](runner-packages.md) defines pinned portable GitHub runner acquisition, verification, and cache lifecycle.
- [implementation-plan.md](implementation-plan.md) defines staged delivery.
- [progress.md](progress.md) is the living implementation tracker.

## Core decision

One controller owns GitHub scale-set sessions, global demand, placement, and farm policy. A portable Rust node agent owns host-local execution, resources, runner lifecycle, logs, and durable local recovery state. Nodes do not receive the GitHub PAT or App private key. One-shot JIT configuration is delivered only to the selected node over authenticated TLS.
