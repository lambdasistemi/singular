# Fold every pending request: ruling

The operator's ruling of 2026-10-06 on the fold's processing window, recorded with the
story it decides. Read the [spec](spec.md) for the stories and the [plan](plan.md) for the
slices.

## Story

As a registry processor, I fold every pending request whose processing window is still
open, and the model tells me that a fold including a request past its deadline is refused
`not-phase1`, as the chain refuses it, so the folder's selection is checked against the
law and not against the validator alone.

## What was silent

The chain refuses every update whose transaction's validity interval is not entirely
before the request's `submitted_at + process_time` (`not-phase1`,
`onchain/validators/registry/fold.ak`). The model had no fold admission: a fold and a
reject were exactly `Singular.exitStep`, and constitution 1.12.0 said so.

## Decision

Option A, amendment 1.13.0 of the constitution: the model gains the fold-time admission
for every fold, single and batch. A fold including a request past
`submittedAt + processTime` is refused `not-phase1`, as the chain refuses it. Inside the
window nothing changes. The corpus carries an in-window batch, a batch with one expired
request, and the boundary: an upper bound equal to the deadline is admitted, one past it
is refused.

The alternative not taken was a narrower amendment, the batch question only, leaving the
single fold without an admission; the model would then have said different things for a
fold of one and a fold of many.

## A batch cannot consume what it created

The operator's second ruling of 2026-10-06, inside the same amendment.

As a folder, starting with key K unknown and two pending requests in ledger order, an
insertion of K and then a termination of K, I fold once: the insertion settles, and the
receipt names the termination `refused-by-law token-missing`. The next fold settles the
termination from the live holding.

The chain cannot settle both in one transaction: the insertion delivers K's token to an
output of the transaction, and the termination must burn it from an input. The model
therefore distinguishes, in a batch, what is live from what the batch created, and refuses
a request that consumes a holding or a custody entry created earlier in the same batch:
`token-missing` for a holding (`insertActive` or `updateActive`, then `updateTerminal` or
`deleteActive`), `not-booked` for a custody entry (`insertAbsent`, then `updateActive` or
`deleteAbsent`). The names are the model's existing ones. The alternatives not taken were a
published divergence between model and chain, and netting both requests, which needs a
validator change.
