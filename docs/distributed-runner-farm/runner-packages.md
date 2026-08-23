# Portable Node Execution Backends and Runner Packages

`crf-node` requires the isolated `container` execution backend. The former `native_process` mode is rejected because workflow code inherited the node agent identity and could access its mTLS credentials, writable control state, and sibling-job process data.

## Execution backend selection

- Set `CRF_EXECUTION_BACKEND=container` to use a controller-approved local container adapter. Container mode requires `CRF_CONTAINER_ADAPTER_PROGRAM=/absolute/path/to/adapter`; `CRF_CONTAINER_ADAPTER_TIMEOUT_MS` defaults to 15000 and is bounded to 100..120000 ms. Native runner-template/runtime/log settings are not required.
- Omitting `CRF_EXECUTION_BACKEND` fails closed. Setting it to `native_process` returns `UnsafeNativeExecution`; there is no unsafe override. The distributed Linux bundle ships a portable Docker adapter and protected runner entrypoint. Its runner image must be pinned by platform digest.

The container adapter is an execution boundary, not a scheduler. The controller remains authoritative for placement/resource admission. The adapter receives placement identity, pool, resource claim, runner name, and JIT descriptor over bounded JSON stdin; the JIT descriptor is never placed in adapter argv or environment. Start recovery inspects by placement identity before any retry, and exact immutable container IDs are persisted for cancellation and liveness checks.

## Host capacity budgets

Node capacity may be explicit or derived from the live host. Set both
`CRF_NODE_CPU_MILLIS` and `CRF_NODE_MEMORY_BYTES` to `auto` to subtract
`CRF_NODE_CPU_RESERVE_MILLIS` and `CRF_NODE_MEMORY_RESERVE_BYTES` from logical
CPU and physical RAM before registration. Mixing `auto` with one explicit
dimension fails closed.

Shared physical hosts, such as Windows plus WSL, must use explicit
non-overlapping budgets until both runtimes share one controller capacity
domain. Independently auto-discovering both would count the same hardware
twice.

## Historical native package inputs

The package cache and materializer remain internal migration components, but deployed configuration cannot select them until a platform sandbox provides a distinct identity per placement.

### Staged template

Set only:

`CRF_RUNNER_TEMPLATE=/absolute/path/to/template`

This preserves the original deployment model. The directory must already contain `run.sh` on Linux/macOS or `run.cmd` on Windows. Runtime/state/log directories may not overlap or live underneath the template.

### Managed pinned package

Set both:

- `CRF_RUNNER_MANIFEST=/absolute/path/to/runner-manifest.json`
- `CRF_RUNNER_CACHE_DIR=/absolute/private/cache`

Do not set `CRF_RUNNER_TEMPLATE` in managed mode. Partial or mixed source configuration fails closed.

The manifest is schema version 1 and declares a release version plus exact platform artifacts: OS, architecture, HTTPS URL, SHA-256, expected archive bytes, and archive format.

The node does not resolve `latest`. Updating a runner is a deliberate manifest change. This keeps node startup reproducible and reviewable.

## Acquisition and cache contract

At daemon startup, before reserving a new node generation, managed mode:

1. loads the strict manifest and rejects unknown fields;
2. chooses an exact OS/architecture artifact;
3. downloads over HTTPS using Rustls into a private staging directory;
4. refuses bytes beyond the manifest's exact expected size and requires the final size to match exactly;
5. verifies SHA-256 before extraction;
6. extracts TAR.GZ or ZIP with independent traversal/link/special-file checks;
7. validates the extracted runner tree and required `run.sh`/`run.cmd` entrypoint;
8. writes non-secret package metadata;
9. atomically promotes the package into a content-addressed cache entry;
10. freezes the promoted cache tree read-only;
11. returns only the cached `template/` subtree to the existing `RunnerMaterializer`.

Package metadata lives beside, not inside, `template/`, so it is not copied into every per-job runner directory.

A cache hit verifies the marker, expected platform/package identity, tree shape, entrypoint, and absence of symlinks/special files before reuse. No network fetch occurs on a valid cache hit.

## Archive policy

Both archive formats have hard entry/depth/uncompressed-byte fuses. Absolute paths, parent-directory components, symlinks, hard links, devices, FIFOs, and other special entries are rejected.

GNU long-name/long-link and PAX TAR metadata are handled internally by the Rust `tar` reader before file entries are returned, so normal official metadata extensions remain compatible while link/file-type policy stays strict.

## Current example

[runner-manifest.example.json](runner-manifest.example.json) captures the official `actions/runner v2.336.0` Linux x64/arm64 and Windows x64/arm64 packages. The sizes come from the official release assets and the SHA-256 values from the official release notes as verified on 2026-08-19.

The example is documentation, not an implicit upgrade channel. Nodes use only the manifest path explicitly configured by the operator.
