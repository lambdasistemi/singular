# Q-002: the literal "no signature of any kind" criterion for LT04

To: ticket owner (ticket-77). From: commit-owner-2. Status: FILED —
proceeding under the narrow interpretation below unless overruled.
Evidence attached (Over exhibit, final code).

## The criterion as written

Issue #74 (commit-owner brief): LT04 "spends a real custody UTxO with
**no signature of any kind**", "carries no required signers at all",
"funded, witnessed and submitted by a fresh non-privileged party".

## What the implementation demonstrates (frozen shape)

`rowOVComplete` asserts, from the built bytes before submit:

- `reqSignerHashesTxBodyL` is EMPTY (no required signer — no party's
  approval rides the transaction, controller and quorum included);
- the completing key is fresh from bytes (in none of the
  controller/quorum sets);
- the witness set is exactly the fee-input owner's key (input
  ownership, see below).

What it does NOT demonstrate (and cannot, see below): a transaction
with an empty witness set.

## Why the literal reading is impossible on Cardano

A completion spends a fee-paying input (lovelace conservation: fees
must come from somewhere). A payment-key-owned input requires its
owner's vkey witness — a protocol rule, not a policy choice (missing
witness = phase-1 `MissingVKeyWitnessesUTXOW`, no script runs). The
only witness-free fee sources would be a script-owned fee input
(spending it needs its validator to pass — moving the witness from a
key to a script, not removing authorization mechanics) or fee
abolition (protocol change, out of scope). Conservation mechanics are
not approval: the witness authorizes nothing beyond ownership of the
consumed fee input (custody, state, burn and withdrawal need no
signature and check none).

## Lean standing (no change requested or made)

`finishRetirement`'s executing witness is exactly `nativeSpend` and
`representativeMint` — no required signers, no quorum signers. The
ledger witness set is unmodeled (as everywhere in the model: folds
likewise carry fee-payer witnesses). The implementation matches the
model exactly (native spend: fees; representative mint: the burn;
signers: none). No Lean change is needed or proposed.

## Proposed narrow interpretation (for owner ruling)

"No signature of any kind" ⟹ no required-signer authorization by any
party (controller/quorum approval especially); the sole witness is
the fee-input owner's key, mechanically identified as exactly that
(and as outside every route) from the transaction bytes. If the owner
rejects this reading, the alternative within the criterion is a
script-owned fee input (witness set still nonempty — scripts witness
too), and the literal empty-witness-set reading is unimplementable on
this ledger.

## Evidence to attach (post-run)

- Completion txid + `reqSignerHashes == []` (row assertion).
- Witness set == exactly the fee-input owner's key (reader
  VERIFIED-COMPLETE check).
- Fee-input owner outside controller/quorum sets (row + reader).
- The phase-1 rule citation for missing witnesses (node text if
  obtainable from a probe, else the ledger spec reference).

## Attached evidence (Over exhibit, real devnet)

- `retirement-exhibit.log`: `OV-complete-permissionless-completion-
  accepts: accepted tx=d970f418...` with `required signers empty,
  fee paid and witnessed by fresh key 0x915b5072... (in none of the
  route sets)` (row assertion from built bytes, pre-submit).
- `reader-run-over2.log`: `VERIFIED-COMPLETE ... complete=d970f418...
  burn=0x52657042... root=0x563862be...->0x4e4fd962...` — the
  independent reader confirms required signers empty, witnesses ==
  exactly the fee-input owner, and that owner outside every route
  (otherwise `verifyCompletion` refuses).
- The witness set therefore contains exactly one vkey witness (the
  fee-input owner's); required signers contain zero. No
  controller/quorum key witnesses or requires anything.
