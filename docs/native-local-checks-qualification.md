# Native local-checks acceptance record

`runtimeQualified` is an operator intent flag, not sufficient evidence. General
create/execute requires a matching private acceptance record. Cleanup and bounded
kernel qualification remain available when acceptance is missing or stale. An
exact pinned canary while the flag is false is the route to qualify a new helper.
This qualification is separate from normal GitHub runner acceptance.

The fixed sibling `native-local-checks-qualification.json` is root-owned mode0600,
not a caller-selected path. The protected binding pins its exact bytes with
`qualificationSHA256`. The version1 record uses protocol
`farm-local-checks-qualification/v1` and contains host, epoch, immutable image,
helperSHA256, policySHA256, machineIDSHA256, kernelRelease, kernelRequestID, kernelReceiptSHA256, fullRequestID,
fullReceiptSHA256 and fullResultSHA256. Hash fields are lowercase SHA256 hex.

A reviewed record must reference two completed, released requests. Kernel
qualification supplies actual outer/nested cgroup proof and the exact helper
probe hash. Full checks supply the authored Core wrapper's pass/exit0 result,
source commit/base/bundle and released receipt. The full run cannot request more
CPU/memory than the kernel-qualified worker. No hard disk quota is claimed.
Evidence paths derive only from protected policy/binding and validated IDs.

The validator reads the actual `/proc/self/exe` bytes, not the installed pathname,
and hashes JSON marshaled from the protected parsed host-capacity configuration.
Current machine-id hash and kernel release are pinned as well; absence fails closed.
Boot ID is not pinned, so a normal reboot with unchanged materials remains eligible.
Any helper, image, host/epoch, machine/kernel or policy change requires new reviewed matching
materials. Evidence must remain private, nonsymlinked and byte-identical. The
record does not publish a GitHub status or approve a different source revision.
It is retained acceptance of the worker/runtime; every job still verifies its
own committed snapshot, limits, live owner and exact cleanup.

`local-checks-readiness` on the native backend is a read-only dynamic result. It
reports `runtimeQualified: false` if operator intent is false or evidence has
changed. `local-checks-contract` remains a static protocol description. Neither
endpoint creates capacity, starts Docker, mints a record or promotes a binding.

Record creation/promotion belongs to the explicit root operator review: gather
terminal kernel/full-suite/cleanup receipts, review exact materials, persist the
record exclusively and fsync, then CAS only the protected digest/intent after
idle-state verification. A scheduler/browser request cannot supply these fields.
Do not copy an old helper's acceptance to a newly built binary. Keep the canary
pin cleared after its terminal release. Do not change or delete retained evidence
to manufacture readiness; stale evidence is an actionable failed preflight.

After the exact frozen helper's new kernel and full canary receipts are released,
the root operator can request a deterministic proposed record without writing:

```
ci-runner-native --local-checks-qualification-review /protected/native-local-checks.json KERNEL_REQUEST_ID FULL_REQUEST_ID
```

The helper reads only its fixed protected policy, binding and derived evidence
paths, validates every acceptance condition, and emits the proposed record on
stdout. It refuses old-helper evidence. This computes the typed policy digest
with the same code used by dispatch; do not substitute another JSON serializer.
The command does not persist a record, flip intent, clear a canary, or reserve a
worker. Root review and an exclusive journaled/CAS promotion remain separate.
