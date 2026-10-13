# Coder brief, slice two: rejection needs evidence

The whole of slice two for the commit owner, with its terminal condition. The binding, the rulings
and the limits are in the [mandate](../mandate.md); the facts a rejection carries are in the
[data model](../data-model.md); the call surface is in the [functions model](../functions-model.md);
the released contract is in the [evidence contract](../contracts/rejection-evidence-contract.md); the
proof is the [gate](../gate.md). Slice one is merged into the branch before you start.

## Story

As a requester, I see the model refuse a rejection of my foldable request, whatever evidence the
processor supplies, and accept a lawful rejection with its evidence, so that paying for processing
cannot be turned into a cancellation that collects my tip.

## Rulings this slice implements

The operator's words, verbatim; the rest of the rulings are in the [mandate](../mandate.md).

A lifecycle mismatch permits immediate rejection:

> Authenticated incompatibility with the current lifecycle state permits immediate rejection even
> when a later transition could make the request eligible.

Expiry follows both windows:

> expiry-only rejection after both the processing and owner's reclaim windows end ... The expiry
> threshold is therefore submission time plus processing duration plus reclaim duration.

A request naming an excluded edge is rejectable at once:

Epic owner ruling of 9 October 2026, as an application of the first ruling: an excluded edge has no
successor at any leaf, so a request naming one is incompatible with every current state and is
rejectable at once with the lifecycle evidence.

## Seat

| Field | Value |
|---|---|
| Role | commit owner for slice two, launched after the rebased plan is reviewed |
| Launcher | `/home/paolino/.local/bin/muse --approve`, working directory `/code/singular-issue-494` |
| Runtime root | `<ticket owner root>/commit-owner-2`; your journal is its `STATUS.md` |
| Auditor | Grok, mute, beside you from your first run; you never address it |
| Commit authority | Local commits only, one patch with `stg`; no push, no rebase, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and
no attribution in any commit. Plain words, no coined abbreviations.

## The task

Port the earlier attempt's rejection design (branch `feat/protected-rejection`, `a7224021`, read with
`git show`) onto the two-edge model, as the data and functions models state it. Its differences are
listed in the data model: the evidence carries no separate registry identity; a fold's question is not
widened. Do not weaken, drop or reorder a refusal reason. The earlier proofs were written for toolchain
4.25.0; the toolchain is now 4.27.0, where an impossible `Except` equation is closed with
`exact nomatch h`, as `lean/Singular/Lemmas.lean` and `lean/Singular/Statements.lean` now write it.

1. Failing control first. Port the historical scenario (an empty registry and an approved insertion of
   key 5 for owner 42, destination 99, deposit 2,000,000, tip 1,000,000, rejected with no signers) to the
   base API and run it on the unchanged base: it must report the rejection accepted, state unchanged, no
   mint, deposit-only refund. Keep that output as the RED bundle.
2. Add the registry identity to a configuration and to a request, the reason, evidence and witness
   types, the rejection admission and the extended exit admission, and the per-request witnesses of an
   all-reject batch, each as the functions model states. Keep the admission order of the data model.
3. State and prove the slice-two statements of the functions model, from standard axioms only.
4. Export the corpus: the truth table cell by cell for the two admitted edges and one row per
   excluded tag; the three time positions (before the processing end, inside the reclaim window, at
   the expiry threshold, with the one-instant boundary either side); every refusal reason; unknown
   against Absent; the historical scenario refused after the change.
5. Transport and harness. Decode a rejection question with its booked metadata and evidence; refuse
   one without them and evidence attached to another exit. The harness allocates the registry identity
   while acting, reads the booked time from the request datum and builds mismatch and expiry evidence.
   Principle VII of the constitution, added on main, applies to this code: the question builders take
   their inputs explicitly, anything that holds the allocated identity has a named owner, a bounded
   lifetime and a stated concurrency contract beside it, and no thread or hidden environment read is
   added. The pull request body maps these.
6. Re-base the lawful rows: the running book, the refund controls, the generic rows and the batch
   harness place their rejects after both windows with expiry evidence. Edit their workflow assertions
   only as that requires. The dedicated early-rejection row and the generic session's unmet
   consumer-requirement row are slice three: leave them as they are.
7. Regenerate every copy the change moves, as in slice one, and extend the restatement table.
8. Restate the rejection row, the outcome-class row and the reconciliation in the constitution's 1.16.0
   entry.

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and evidence path, and continue, at: the RED bundle; the
admission and statements green; the corpus and transport green; the lawful rows green; the final head.

## Gate

The slice-two rows of the [gate](../gate.md), once per candidate on a clean committed tree. The devnet
rows run on the hosted checks; run locally the two rows you edited most, once. The early-rejection row
is red at this head by design and is not part of this slice's gate.

## Terminal condition

Stop at the first of: every slice-two gate command exits as the gate states on a clean committed head
(`CANDIDATE-GREEN` with commit and receipts); a question the mandate cannot decide (file it with the
user story of each option and journal `BLOCKED`); capacity (`COMPLETE capacity-limit` with a handoff).
A proof that does not port: restate it only if the two-edge model makes the earlier wording false, and
record which and why in the receipt; never weaken the property. Touch nothing under the files this
ticket must not touch.
