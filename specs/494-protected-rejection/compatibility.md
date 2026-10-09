# Model delivery compatibility and merge hold

As a request owner, a lifecycle-compatible request must remain protected from
permissionless rejection until processing and reclaim windows have both ended.
The model proves this; the current live acceptance story expects the opposite.

The operator's 2026-10-08 Lean-only boundary permits necessary non-on-chain
compatibility repairs, but forbids validator work, weakened public evidence,
check bypasses and downstream dispatch. PR #508 therefore remains held.

The retained initial hosted failures belong to commit
`4ee2082b34b81201b4d079ca0bcc3075f0371598`. The follow-up repairs:

- Offline Haskell replay forwards rejection evidence and mixed-batch bounds.
- Live questions carry the timestamp read from the booked request datum,
  the existing allocated registry identity and the allocated request reference.
  No rejection witness is fabricated.
- Inventory tests account for twelve additional statements, retaining all
  59 helper declarations.
- The fold simulator carries the added metadata in its schemas and examples;
  its identity and generated page are rebuilt. No protected-exit UI is claimed.
- The theorem speech companion and changed audio are regenerated; formatting
  failures in the model scripts are repaired without changing model behavior.

Local checks passed: conformance executable build; 86 targeted transport
examples; theorem coverage gate tests; conformance formatting; model checker
with 79 compiled declarations; simulator corpus parity and failure controls.
These are author checks, not fresh independent review or hosted live acceptance.
The Opus model review remains preserved and does not cover this follow-up.

## Concrete blocked story

`earlyRejection` in `conformance/lib/Conformance/Edge/Programs.hs` still requires
six agreeing outcomes and says an untampered rejection must succeed while the
request can still fold or its owner can still retract. The initial hosted
[early-rejection job](https://github.com/lambdasistemi/singular/actions/runs/37755208632/job/113237957521)
submitted transactions before failing on missing model request metadata.

For these compatible requests, no valid mismatch or expiry evidence can justify
that acceptance under `live_compatible_request_protected`. Updating transport
cannot make the contrary ledger behavior conform. Validator implementation is
required, belongs to #495, and is forbidden by the current boundary. The
existing public story and checks are preserved; no pass is claimed.

No on-chain source was edited. #494 and epic #498 remain unaccepted. Preserve
this lane for restructuring #507/#504; resume on-chain implementation only under
new authority. A future model merge would not establish ledger protection.
