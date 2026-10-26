# Local Core checks boundary

`internal/localchecks` implements the closed client/coordinator/worker contract
for complete Core checks on a selected compatible host. The external coordinator
owns discovery, its durable queue and screened Git pack transfer. Farm owns
admission, inert worker creation, execution and cleanup on Farm hosts through
`HandleNativeCommand` and the existing native backend/helper.

These calls have effects: they can create/start a dedicated privileged DinD
worker, execute the fixed Core entrypoint, transport the protected dependency
credential through stdin, stop/remove the worker, and settle its fenced grant.
The closed request never chooses commands, credential values, host paths or a
Docker daemon. Work remains inside the admitted worker's private daemon/cgroup.
No sign-off publication or independent durable queue is implemented here.

Source implementation is distinct from installation and runtime qualification.
Use the selected host's readiness contract and exact helper/image/epoch receipts
in [native qualification](native-local-checks-qualification.md); a capacity
observation or source test is not a reservation or appliance acceptance.

## Submission

The closed version-1 JSON request accepts only:

- `repository`: exactly `unraid/core`.
- `commit`, `base`: full lowercase 40-character Git commit identities.
- `bundleSHA256`: the exact transferred bundle digest.
- `requestID`: an opaque bounded identifier reused for the same logical request.
- `cpus`, `memoryMiB`, `scratchMiB`, `timeoutSeconds`: explicit bounded limits.

Unknown fields, arbitrary commands, credentials, paths and moving branch names
are refused. Requests larger than 8 KiB and trailing JSON documents are refused.
The coordinator must authenticate the caller and authorize the repository and
resource request before placement. The request ID is not authentication.

## Placement and admission

`Place` accepts at most 64 explicitly configured worker observations. Workers
must attest a Linux Docker engine, the Core checks-container capability, an
amd64/arm64 engine and sufficient unallocated CPU, memory and scratch space after
host reserves. Observations older than 15 seconds, implausibly future-dated
observations and invalid CPU readings are ineligible. Eligible workers are
ordered by measured CPU utilization with host identity as a deterministic tie.

The coordinator's `Reserver` must atomically reserve actual capacity before a
host is returned. A positive `ErrBusy` with an empty receipt permits trying the
next host. Any unknown outcome, nonempty refusal receipt, changed identity or
cancellation stops placement and preserves the receipt for its owner's recovery.
Admission has a 30-second context deadline; implementations must honor it.
No new queue or independent resource ledger is created.

## Worker preparation and execution owner

`Prepare` accepts paths from trusted worker configuration after transfer. It
checks the exact bundle digest, canonical checkout, clean committed HEAD, base
commit/history, origin and executable Core container entrypoint. Ambient Git
directory/configuration environment is not forwarded to Git probes. The live
owner must verify the grant both before and after source verification.

The resulting invocation is fixed:

```text
core/scripts/local_ci_container.sh checks COMMIT BASE
```

The adapter must keep exclusive custody of that checkout and its reservation
from verification through execution and terminal cleanup. It must prevent
source changes between preparation and execution, enforce aggregate resource
limits around all nested containers, bind logs/results to the exact request and
retain uncertain grants until reconciled. `Prepare` itself starts no workload.
The adapter must forward only the approved private dependency credential via the
supported process secret mechanism; never serialize it into a request or receipt.

The published `local_ci.sh` currently also requires an open matching PR and
publishes GitHub status/sign-off. Those behaviors remain unchanged. A separate
Core-owned caller integration is required before that command can submit checks
to this coordinator. This checks-only contract must never claim GitHub sign-off.
