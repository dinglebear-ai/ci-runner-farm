# Charged local-checks execution adapter

The `Execute` entrypoint extends the source/placement contract with a real bounded
subprocess lifecycle. It still requires the worker's existing charged sandbox;
it does not turn an uncharged host shell into a managed worker.

`FarmExecutionOwner` integrates the existing `hostcapacity.WithConsumer` owner.
Its declared consumer, policy epoch and lease stay pinned through workload,
terminal evidence and the sandbox's stopped-owner/release protocol. The sandbox
must resolve its protected grant receipt while its execution lease is held.
The adapter verifies that exact existing grant ID, fence, authorized pool and
charged CPU/memory cost against the same Farm ledger. It never initializes a
ledger, creates/adopts a grant, copies a budget or releases a sandbox allocation.

`ChargedSandbox` remains the existing worker's implementation boundary. It must
prove actual aggregate kernel limits, nested-container confinement, exclusive
checkout custody and stopped descendants. The adapter refuses absent owners,
changed epochs, undeclared classes, missing grants and stale fences. A standalone
broker allocation or advisory scheduler ticket cannot satisfy this contract.

Within that custody, `Execute`:

- Revalidates the bundle, checkout and grant through `Prepare`.
- Runs only the fixed Core checks-container entrypoint and exact SHA/base.
- Starts a separate process group with the request deadline; cancellation sends
  TERM then escalates to KILL, and remaining group descendants are killed after
  the entrypoint exits. The sandbox owner still supplies final stopped proof.
- Inherits no ambient credential environment. Its approved dependency token can
  enter only through the execution owner's in-memory environment delivery.
- Redacts that supplied value across output-write boundaries before retaining
  logs; raw/retained output is bounded to 16 MiB. Output excess cancels work.
- Creates exclusive private job evidence and 0600 logs/terminal JSON. Existing
  job evidence is not overwritten or treated as permission to rerun work.
- Commits terminal evidence inside the owner callback before custody can end.
  Unknown execution/evidence outcomes require the original owner's recovery;
  callers must not blindly submit a second execution with a new identity.

The tests execute actual committed temporary Git fixture scripts. They prove
fixed invocation, lease ordering, log/receipt retention, supplied-value redaction,
deadline handling and cancellation with a positively absent child process. A
real isolated shared-capacity ledger verifies existing charge/fence checks.
These are local subprocess/ledger integration tests, not a production Docker
resource qualification or a four-host deployment.

The coordinator must still provide its supported transfer and concrete worker
sandbox adapters. No installed coordinator skill, Core caller, native plugin UI,
host policy or live worker was changed by this source slice.
