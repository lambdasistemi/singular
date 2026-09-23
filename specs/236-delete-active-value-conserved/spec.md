# Retire an active registration

Issue: https://github.com/lambdasistemi/singular/issues/236
Parent: https://github.com/lambdasistemi/singular/issues/209
Base: `7eba114be158a75669a72cd79649424d8a29ded0`

## Story

As a registry user, I retire an active registration and the node accepts the transaction.

## Observed

On the unnamed sequence, `deleteActive` for `sequence-direct` is rejected in phase 1 with `ValueNotConservedUTxO` before any validator runs. The receipt is `conformance/BOOK.md` line 476 at the base.

Supplied value lacks policy `37c5f765be64afca5e109e65fc0bd1512545f367f18bdc74f9ee6a43`, asset `73657175656e63652d646972656374` (`sequence-direct`). Expected value carries quantity 1 of that asset. The coin and every other asset agree.

Ledger rule (`validateValueNotConservedUTxO`, Mary `getConsumedMaryValue` / `burnedMultiAssets`): supplied is inputs plus positive mints; expected is outputs, fee, deposits, and the absolute value of negative mints.

`deltaOf` for edge 5 is `[(active, -1)]`, so the burn is in the mint field and is counted on the expected side. `dutiesFor` for edge 5 is empty, so the UTxO that holds the active token is not an input. The consumed side is the one that is short.

The book's sentence that the builder adds no burn does not match this receipt.

## Acceptance

- A control executes the builder and shows the active-token mint at `-1` with no input carrying that asset. The historical node receipt above is the same fact at the boundary.
- The builder spends the UTxO that holds the active token. The burn stays. Value conserves. No validator is weakened.
- A devnet receipt shows `deleteActive` accepted, and #229's generic sequence compares it with Lean as an agreeing step.
- The book's unsupported row for `deleteActive` is replaced by that agreeing step, regenerated from the receipt.

## Out of scope

`deleteAbsent` (#235). Lean. On-chain validators. The registration comparison in `conformance/lib/Conformance/Compare/Registration.hs`. `witnessTerminal` stays unsupported.

## Deviation

No gate-author seats. The gate is the verbatim CI commands in `gate.sh`, written by the ticket owner. Operator decision 2026-09-23.
