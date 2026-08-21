# Distributed Linux service bundle

This packaging is intentionally separate from the Unraid plugin package. It installs the distributed controller/node components under an immutable `/opt/ci-runner-farm/releases/<version>-<platform>-<git-sha>` directory and atomically repoints `/opt/ci-runner-farm/current`.

The controller unit runs the self-contained OTP release and may supervise the Go scale-set adapter when the controller JSON contains a non-null `sidecar` block. The node unit runs `crf-node` directly. `systemctl reload ci-runner-farm-controller` atomically reloads the node-certificate fingerprint allowlist through the packaged `crf-peer-admin` helper without restarting the listener.

The bundle is tagged with the build distribution/version/architecture because Mix releases and the Rust binaries are native artifacts. Do not treat an Ubuntu-built bundle as a generic Linux binary release.

`install.sh` never enables or starts services. It also never overwrites an active controller/node configuration. Examples are installed under `/usr/share/doc/ci-runner-farm-distributed/examples`.

The node service deliberately uses `KillMode=process`: stopping/restarting the node agent must not automatically kill a GitHub runner child that may already own a job. The new agent generation adopts a surviving durable placement. Explicit job cancellation uses the shipped managed process-tree implementation: Unix process groups with TERM-to-KILL escalation and Windows Job Objects.
