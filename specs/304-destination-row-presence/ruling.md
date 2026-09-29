# Ruling: omit the destination row on folds that deliver nothing

Issue #304. Operator ruling, 2026-09-29, verbatim:

> Omit it: Lean describes only outputs that actually exist; amend Lean before accepting the comparison.

Question it answers: a fold that sends no token to the requester (for example a fresh
absent insertion, which puts the token and deposit in custody) has no output at the
request's destination. The ruling selects: no destination row for such a fold. It does not
select a logical normalization or a new physical carrier.

## Story

As a conformance reader, I fold a fresh absent insertion and receive an output description
of the ledger outputs that actually exist, so that the suite cannot invent a destination
output or its datum to make a comparison pass.

## What changes

- The model's fold transaction carries a destination output only when the fold routes a
  token to the requester; every other fold has none.
- One statement over all seven edges: a fold's built outputs contain a destination output
  exactly when it routes a token to the requester. A mutant that restores the unconditional
  output must fail it.
- The exported driver corpus, its simulator mirror and the constitution's `tx` row follow.

## What does not change

Deposit recipients, phase windows, signer requirements, and the inline datum and commitment
of a delivering fold's destination output.
