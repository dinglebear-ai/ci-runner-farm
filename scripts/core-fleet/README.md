# Farm fleet transport ownership

`core_fleet_farm.py` is the authoritative Farm protocol adapter used by the
personal local-CI client. It delegates to the existing protected Farm owner,
ledger and FD8 lifecycle; it does not define a scheduler or direct Docker runner.
The personal `my-core-plugs/tools/local-ci` copy is an exact-hash projection so
its existing source-injection transport remains self-contained. Update this
source first, then copy and record the matching SHA256 in client provenance.

Classic transport requires explicit client selection and current runtime
qualification. It uses the existing classic
capacity binary/fleet lock and preserve operation identity, cancellation,
resource qualification and positive cleanup. An absent native UDS must never
fall back to uncharged host execution.

## Unadvertised classic operation bridge

`classic_transport.py` provides a closed transport boundary for the existing
classic `runner-farm.sh local-checks` exec mode. The personal client projects this source and `core_fleet_classic.py`; no live
installation or operator selection is implied. The root-only public dispatcher reads the existing protected
binding; callers supply a typed native command, exact installation hashes and
finite operation/cleanup budgets, never executable or storage paths. The shell
retains its snapshot reload and FD8 ownership, then execs the capacity helper.
The transport verifies that original child's executing inode and exact argv
before sending its command and transient dependency credential over stdin.

Each command phase has one exclusive immutable intent. Observation never starts
a replacement process. Cancellation records the exact operation/digest and is
delivered only by the original owner through its pidfd. A missing terminal
receipt is `inspect_required`, not an invitation to replay. The released-receipt
observer checks the same epoch/request/image/private roots and positive exact
container absence; it reports cleanup evidence only, never successful tests.

The bridge does not acquire another capacity lock, create a queue/ledger, adopt
a saved PID or send numeric-PID signals. If owner cleanup exceeds its bound,
the transport reports uncertainty and leaves the existing Go owner/deadline and
capacity receipt authoritative. Operator recovery must inspect that owner and
its released receipt; no automatic retransmission or forced grant release is
implemented. Complete appliance lifecycle acceptance and runtime enablement remain separate
pending work.

Focused Linux fixtures (including real FD8 shell exec and original-child pidfd):

```sh
python3 -m unittest discover -s scripts/core-fleet -p 'test_classic*.py' -v
bash tests/classic-local-checks.sh
```

Use the executing environment's supported `TMPDIR` when its default temporary
filesystem lacks quota. These fixtures do not qualify a classic appliance.

### Continuing child custody on transport failure

After launch, exceptions close stdin, request SIGTERM through the original
pidfd and allow the finite cleanup budget for actual child settlement. A child
that exits is waited/reaped before its pipes or pidfd close. An ignored signal
or expired cleanup budget retains the same Popen/pidfd/pipes in one non-daemon
settlement thread inside the existing transport process. The thread drains and
discards output with bounded memory, waits for the original child and only then
closes its handles. It never launches a replacement, sends SIGKILL, retries a
signal, adopts a PID or releases a capacity grant.

The finite request result remains `inspect_required`; a retained settlement
owner is not successful workload or cleanup evidence. The caller must preserve
this original transport process until its child actually settles. If SIGTERM is
ignored indefinitely, the owner remains alive pending the existing native owner
or operator recovery. Client eligibility requires the helper's current qualification receipt and
explicit operator transport selection. Fixture checks do not grant appliance
qualification. A dead
original owner is still an inspect-before-retry situation, never stored-PID
recovery or permission to replay an intent.


## Classic capability observation

The fixed `ci-runner-capacity local-checks-readiness` command composes the
existing runtime qualification verifier and read-only admission diagnostics.
It uses the classic protected binding, distinct from the native plugin binding.
The fixed `local-checks-qualification-review <kernel-id> <full-id>` command only
proposes evidence through the existing reviewer; it never promotes a record.
Neither command creates native job history or changes admission state.

`core_fleet_farm.py`, `core_fleet_classic.py`, `classic_process.py`, and
`classic_transport.py` are authored here. Their personal-client copies are exact
projections, included in its activation hash inventory. A transport observation
failure cannot trigger native/classic failover. The coordinator keeps its
original execution owner through cancellation and settlement; it never retries
an uncertain phase or releases a grant based on process exit alone.
