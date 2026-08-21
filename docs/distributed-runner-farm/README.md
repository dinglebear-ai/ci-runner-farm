# Distributed Runner Farm

This directory is the source of truth for the multi-device CI Runner Farm design and implementation.

The design extends the existing single-host Unraid runner farm into one logical farm with a central control plane and portable node agents. The current Unraid implementation remains a supported local execution backend.

## Documents

- [spec.md](spec.md) defines scope, invariants, and acceptance criteria.
- [architecture.md](architecture.md) defines controller, node, scheduling, cache, and failure topology.
- [protocol-contract.md](protocol-contract.md) defines the versioned controller/node wire and transport contract.
- [controller-config.md](controller-config.md) defines the strict portable controller configuration and sidecar supervision contract.
- [runner-packages.md](runner-packages.md) defines pinned portable GitHub runner acquisition, verification, and cache lifecycle.
- [service-packaging.md](service-packaging.md) defines the distribution-tagged Linux bundle, installer, systemd units, and verification contract.
- [certificate-lifecycle.md](certificate-lifecycle.md) defines CA-agnostic enrollment, hot leaf rotation/revocation, emergency revoke-all, and phased CA rotation.
- [implementation-plan.md](implementation-plan.md) defines staged delivery.
- [progress.md](progress.md) is the living implementation tracker.

## Operator surfaces

- Unraid **Runners** shows the external controller projection (nodes, capacity,
  offers, placements, demand sessions, and sidecar health) separately from the
  local container-node process, generation, and cache-backed storage.
- `runner-farm.sh distributed-status-json` combines local process evidence with
  the bounded mode-0600 projection written by the node. The projection is
  capability-gated and arrives over the existing authenticated mTLS session;
  the WebUI never proxies or exposes controller RPC.
- `runner-farm.sh distributed-pools-json` exports reviewed Unraid pool policy for
  controller configuration without activating it.
- `crf-operator-status` on the controller remains the authoritative mutation and
  full diagnostic surface for drains, orphan remediation, replay fences, and
  peer authorization.

## Activation boundary

Code, registration, and node health alone are not proof that distributed
scheduling is active. Activation requires a fresh compatibility record bound to the exact
installed plugin, helper, module, image, runner groups, and host identity. The
live workload evidence must prove assigned jobs, zero-to-one, cancel/reassign,
ack replay, nested-cgroup charging, classic quarantine, and cleanup. Only then
may the explicit migration state machine move effective admission from classic
to scale sets. Production completed this cutover on 2026-08-21; the gate remains
the required path for a new installation or rollback/re-activation.

## Core decision

One controller owns GitHub scale-set sessions, global demand, placement, and farm policy. A portable Rust node agent owns host-local execution, resources, runner lifecycle, logs, and durable local recovery state. Nodes do not receive the GitHub PAT or App private key. One-shot JIT configuration is delivered only to the selected node over authenticated TLS.
