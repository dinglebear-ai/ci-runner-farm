# Controller Configuration

Distributed mode is enabled by setting `CRF_CONTROLLER_CONFIG` to an absolute path containing the schema-versioned JSON controller configuration. If the variable is absent or empty, the controller preserves the legacy/minimal startup path.

The config file must be a regular file. On Unix it must not be group/world accessible. Unknown keys at any nesting level are rejected.

## Schema version 1

Top-level keys are mandatory:

- `schema_version`
- `scheduler`
- `state`
- `node_registry`
- `scaleset`
- `sidecar`
- `tls`
- `demand`

### Scheduler

`scheduler.executable` points to the absolute `crf-scheduler` binary. `request_timeout_ms` is bounded from 100 to 30000 ms. The scheduler runs as one persistent framed Port process; Elixir does not implement a second placement algorithm.

### Durable controller state

`state.placement_path` is the private atomic placement ledger. JIT descriptors are never stored in this file.

`scaleset.sequence_path` is the durable request-sequence high-water mark used to prevent replay regression after an Elixir restart.

### Scale-set adapter

`scaleset` contains the Unix socket, controller identity, config/ownership revisions, and IPC timeout. The timeout accepts 100 to 120000 ms. Production should use 120000 ms because GitHub session close, handle retirement, and long-poll handoff can legitimately exceed 30 seconds; the Elixir call boundary allows an additional five seconds. The controller never stores the GitHub PAT or App private key; those remain inside the Go adapter's separate sealed runtime configuration.

`sidecar` chooses adapter ownership:

- JSON `null`: the Go adapter is managed externally.
- object: OTP launches and supervises `crf-scaleset supervise` before `ScaleSetClient`.

A managed sidecar object contains:

- `executable`: absolute `crf-scaleset` binary.
- `runtime_config`: absolute mode-0600 Go runtime config.
- `compatibility`: absolute mode-0600 sealed compatibility record.
- `startup_timeout_ms`: 100 to 120000 ms.

The socket path is not repeated in the sidecar block. The sidecar always uses `scaleset.socket_path`, preventing transport configuration drift.

OTP treats an unexpected sidecar exit as a supervised failure. Normal shutdown sends SIGTERM to the child PID, waits two seconds, escalates to SIGKILL only if needed, and then closes the Port. The Go server itself owns stale-socket removal and socket-directory permissions.

### Node TLS

`tls` contains the listener port, controller certificate/key, CA certificate, handshake timeout, and certificate SHA-256 fingerprint-to-node mappings. TLS 1.3 and client certificates remain mandatory.

### Demand and pool policy

`demand` controls automatic reconciliation, interval, offer TTL, placement-loss grace, bounded offers per tick, and 1 to 8 pool policies. Placement loss only marks an operator-visible orphan after the grace; it does not automatically free or rerun possibly active work.

Every pool declares:

- ID and hard concurrency ceiling (maximum 64);
- per-run CPU milli-cores and memory bytes;
- optional OS and architecture constraints (JSON `null` means unconstrained);
- required execution backend;
- required capability strings;
- GitHub runner work folder.

The controller translates this boundary once into `PoolPolicy` values consumed by the Rust scheduler.

BEAM coverage workloads need a separate pool claim rather than a larger
node-wide budget alone: the container adapter applies each placement's memory
claim as its hard cgroup limit. The example `beam` pool reserves 10 GiB with no
swap for each placement. Qualify that pool with the `beam-runtime` distributed
acceptance target before routing production Elixir jobs to it; the target proves
the checked-out Phoenix toolchain can start and complete `mix test --cover`
without increasing the cgroup `oom` or `oom_kill` counters. The scheduler also
requires the image-derived `otp-28-compatible` capability; the memory claim
alone is not compatibility evidence.

The GitHub scale set itself has one routing label: the pool ID/selector. A
workflow uses that selector alone (`runs-on: ci-pool-rust`). Do not copy classic
runner label arrays such as `[self-hosted, Linux, X64, ci-pool-rust]` into a
scale-set workflow: GitHub does not attach those classic labels to a JIT
scale-set runner. Platform and resource requirements belong in this controller
pool policy.

On an Unraid node, `runner-farm.sh distributed-pools-json [x86_64|arm64]` renders the currently validated single-fleet or V2 pool snapshot as this exact JSON array. The export is read-only and selects the local `container` backend; it does not create a controller configuration, enable distributed mode, or start services. Operators insert the resulting array as `demand.pools` in the private controller configuration and review it before activation.

## Startup ordering

Configured distributed startup is deliberately fail-fast and ordered:

1. node registry
2. durable placement ledger
3. offer ledger
4. node mailbox
5. Rust scheduler Port
6. placement coordinator
7. node ingress
8. connection Task supervisor
9. optional Go scale-set sidecar
10. scale-set IPC client
11. demand coordinator
12. TLS node listener

With automatic reconciliation disabled, the complete controller can boot without a live scale-set socket. This is useful for staged deployment and certificate/node enrollment. With a managed sidecar configured, the socket is ready before the scale-set client/demand coordinator start.

## Example

See [controller-config.example.json](controller-config.example.json). It uses an externally managed sidecar. Replace `sidecar: null` with the managed object described above when OTP should own the Go process.
