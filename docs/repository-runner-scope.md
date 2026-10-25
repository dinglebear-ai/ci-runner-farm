# GitHub runner registration ownership

Registration authority lives in Farm's private, versioned
`farm-registration-policy.json` sibling. The shared host-capacity JSON document
is unchanged, including its exact bytes during routing updates; existing strict
QA readers need no upgrade. In-memory registration fields are never serialized
into that shared document.

A private policy pins the final active shared-policy SHA256, host, epoch and
GitHub owner, plus explicit `org` or `repo` scope and a bounded repository
allowlist. Its settings SHA256 is review/apply provenance, not a permanent
settings lock. Labels, count, cache and other unrelated settings can change
without invalidating unchanged registration authority. Missing private policy
means legacy organization-only authority. Missing scope inside an existing
private policy is invalid and never becomes organization fallback.

Before minting a token, the existing adapter validates its selected target.
Round-robin repository selection is unchanged. Before start/admission, the
existing capacity owner captures the exact public target in its durable receipt.
Repository list reorder/removal cannot retarget an existing owner's registration
or cleanup. Retained-owner cleanup uses that target even if current private
policy is unavailable; it does not require a new publication to stop a runner.

Live `.runner` and exited diagnostic identity must match the pinned target.
GET, labels PUT, DELETE, authorized absence and paginated unregistered-name
absence all use its exact repository or organization endpoint, without fallback.
Unpinned old receipts can migrate only as organization owners.

## Native Settings review contract

`registration-policy-proposal` returns `farm-registration-policy-proposal/v1`:
`epoch`, `owner`, current/requested scope and repository lists, `changed`,
`sharedPolicyBindingCurrent`, `consumerOwnerProofRequired`, and `idleProven:false`.
Its three review pins are `expectedPolicySHA256` (raw shared bytes),
`expectedSettingsSHA256` (public settings snapshot), and
`expectedRegistrationPolicySHA256` (private bytes or exact sentinel `absent`).
The server computes `intentSHA256` with the same canonical builder used by apply;
the UI must retain this before submission rather than guess it or scan files.

Confirmed `update-registration-policy` accepts exactly those three pins. It
preserves an exclusive intent and original shared/private material, then uses
the existing shell snapshot reload, FD8 lock and exclusive host-policy lease.
It verifies all three pins and the same locked settings snapshot. Publication
changes only the private sibling, never shared budgets, pools, consumers, epoch
or ledger. It requires zero grants, pending requests and start reservations,
complete empty native owner/receipt inventory, and released local checks intents
with positive exact container absence. Configured external consumers currently
require their own idle-intent proof; their presence fails closed, preserving them.
This limitation does not change their shared-policy wire compatibility.

An uncertain submit or result uses `registration-policy-status`, with the
retained intent SHA256. `applied_observed` returns
`beforeRegistrationPolicySHA256`, `afterRegistrationPolicySHA256`, unchanged
shared `beforeSHA256`/`afterSHA256`, `settingsSHA256`, `epoch`,
`replayAllowed:false` and `runtimeQualificationProven:false`.
`inspect_required` never replays publication. A terminal receipt remains beside
the intent. These are policy receipts, not successful tests or GitHub readiness.

Fresh repository initialization publishes private authority against final active
shared bytes. Recovery never reports shared activation alone as repository-ready.
Interruption without a private policy still refuses repository work before token
minting, and requires the original initialization/review path to complete.
Changing helper materials invalidates local checks qualification normally;
registration policy operations do not promote it.
