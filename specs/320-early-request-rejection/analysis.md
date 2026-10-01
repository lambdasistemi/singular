# Consistency analysis

## Coverage

| Requirement | Invariants | Tasks | Gate rows |
|---|---|---|---|
| FR-01 | INV-01, INV-05 | T010, T011 | G1, G5 |
| FR-02 | INV-02 | T010, T012 | G1 |
| FR-03 | INV-04 | T010 | G1, G11 |
| FR-04 | INV-05 | T011, T021 | G1, G7, G11 |
| FR-05 | INV-09 | T020, T021 | G7 |
| FR-06 | INV-10, INV-12, INV-14 | T030–T032 | G8, G9, G11 |
| FR-07 | INV-11, INV-14 | T017 | G10 |
| FR-08 | INV-08 | T014, T015 | G1, G2, G3, G4, G5 |
| KR-01 | INV-03 | T012 | G1 |
| KR-02 | INV-06 | T011–T013 | G1, G9 |
| KR-03 | INV-05, INV-06 | T011–T013 | G1, G6, G13 |
| KR-04 | — | every task (path fence) | G0 |
| — | INV-13 | T016 | measurement receipt |

Every functional requirement has at least one invariant, one task and one gate row. Every invariant appears in a task.

## Terminology

The model's words are used throughout: reject, retract, fold, deposit, tip, obligations. Window names follow the constitution's retraction row: processing window, retraction window, after the windows. "Phase 1/2/3" appears only where existing code and tests use it.

## Contradictions found and how they are carried

| Finding | Where | Disposition |
|---|---|---|
| The validator refuses an update outside the processing window; Lean admits a fold in every window. | `registry/fold.ak`, `request.ak` against `Model.lean` | A separate code-against-model discrepancy, repaired by its own ticket. Kept unchanged in this bounded diff (KR-01), labeled current validator behaviour outside Lean, its correspondence claim held. |
| The consumer's R9 forbids early rejection; Singular's Lean allows it. | CG09 | Held; requirement preserved unmet (FR-07). |
| CG23's published requirement states the old timing as product text. | `conformance/rows.json` | Its two timing sentences are restated; its rejects stay placed after the windows. |
| The builder's documentation says it builds rejects "for Phase 3 requests". | `Reject.hs` | Restated with the selection change (T020). |

## Ambiguities left open

- Whether merging this repair is itself held by the consumer conflict, or only the consumer-integration claim is. The constitution holds the affected claim; the parent decides which.
