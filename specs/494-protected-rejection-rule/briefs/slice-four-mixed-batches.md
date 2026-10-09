# Coder brief, slice four: mixed batches

The whole of slice four for the commit owner, with its terminal condition. The binding, the rulings
and the limits are in the [mandate](../mandate.md); the call surface is in the
[functions model](../functions-model.md); the batch semantics are in the
[evidence contract](../contracts/rejection-evidence-contract.md); the proof is the [gate](../gate.md).
Slices one and two are on the branch; slice three is independent of this one.

## Story

As a processor building one batch, I fold Bob's insertion of a fresh key and reject Carol's insertion
of the same key in the same batch, and the model accepts the batch because Carol's request is judged on
the state Bob's fold left; with Carol's request first the model refuses, because at that point her
request is still foldable.

## Rulings this slice implements

The operator's words, verbatim; the rest of the rulings are in the [mandate](../mandate.md).

A batch is judged on the state its earlier actions left:

> Each action is judged against the state left by preceding actions in the same ordered batch.
> Rejection evidence binds that intermediate registry state/root.

The batch rests on the two admission rulings of slice two:

> Authenticated incompatibility with the current lifecycle state permits immediate rejection even
> when a later transition could make the request eligible.

> expiry-only rejection after both the processing and owner's reclaim windows end ... The expiry
> threshold is therefore submission time plus processing duration plus reclaim duration.

## Seat

| Field | Value |
|---|---|
| Role | commit owner for slice four, launched only at coding release |
| Launcher | `/home/paolino/.local/bin/muse --approve`, working directory `/code/singular-issue-494` |
| Runtime root | `<ticket owner root>/commit-owner-4`; your journal is its `STATUS.md` |
| Auditor | GLM, mute, beside you; you never address it |
| Commit authority | Local commits only, one patch with `stg`; no push, no rebase, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. No `Co-Authored-By`, no
attribution. Plain words, no coined abbreviations.

## The task

Port the earlier attempt's ordered batch design as the functions model states it.

1. Failing control first: add the two corpus scenarios above (fold then reject accepted; reject then
   fold refused) and an empty batch refused; they fail on the branch as it stands because the
   question does not exist. Keep that output as the RED bundle.
2. Add the action type, the one-action and ordered-action functions (the engine) and the mixed-batch
   function with its three refusals (empty batch, empty interval, net-mint mismatch).
3. Move the all-reject batch onto the engine and delete slice two's own loop in the same change, so one
   admission path remains.
4. State and prove the slice-four statements: a rejection in an accepted batch passed admission on the
   prefix state; a foldable request cannot be rejected at any position; an empty batch is refused; the
   all-reject batch runs exactly the engine.
5. Add the driver's mixed-batch question to the declared batch questions, its serialization and corpus
   rows, and the transport support; re-pin the surface digest. No live row is added: no mixed
   transaction is built here, so a live mixed batch is published uncovered.
6. Regenerate every copy the change moves, extend the restatement table, add the mixed-batch row to the
   constitution and complete the 1.15.0 entry.

## Checkpoints

Journal `REVIEW-REQUESTED` with commit and evidence path, and continue, at: the RED bundle; the engine
and statements green; the question, corpus and transport green; the final head.

## Gate

The slice-four rows of the [gate](../gate.md), once per candidate on a clean committed tree. No devnet.

## Terminal condition

Stop at the first of: every slice-four gate command exits as the gate states on a clean committed head
(`CANDIDATE-GREEN`); a question the mandate cannot decide (user story per option, `BLOCKED`); capacity
(`COMPLETE capacity-limit` with a handoff). Touch nothing under the files this ticket must not touch.
