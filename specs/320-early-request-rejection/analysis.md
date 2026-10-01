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
| The consumer's R9 forbids early rejection; Singular's Lean allows it. | CG09 | Unmet by ruling (`unmet-by-ruling`, operator ruling 2026-10-01); requirement preserved (FR-07). |
| CG23's published requirement states the old timing as product text. | `conformance/rows.json` | Its two timing sentences are restated; its rejects stay placed after the windows. |
| The builder's documentation says it builds rejects "for Phase 3 requests". | `Reject.hs` | Restated with the selection change (T020). |

## Residuals and their dispositions

| ID | Residual | Evidence and its limit | Disposition |
|---|---|---|---|
| RS-1 | The builder rejects every pending request, fresh ones too. One unprocessable request (a deposit that does not match) makes any builder reject refuse `deposit-mismatch`, as it already did for expired requests. | source: `registry/fold.ak` carriage checks, `TxBuilder/Reject.hs` selection; no live run | named limit (spec Holds and limits); selecting a subset or skipping unprocessable requests is a non-goal here, a candidate follow-up for the parent |
| RS-2 | Prose outside the fence still reads the old rule: an off-chain unit test's name ("treats the retract deadline slot itself as rejectable") and a retirement journey message ("phase 3 (rejectable)"). | source only; behaviour unaffected, the policy function and the journey's refusal are unchanged | non-goal: wording outside the fence, left as is |
| RS-3 | A request whose datum is a hash rather than inline is admitted by `Contribute` in the processing window, and the state's fold does not fold it (it folds inline request datums only). Such a spend is an exit with no obligation, which the model does not have. | source branches only (`request.ak` reads the datum the spend handler is given; `registry/fold.ak` `mkAction` folds inline datums). No compiled or live counterexample yet. Whether the datum's preimage is obtainable by a third party is not established. | unchanged by this repair (outside the processing window it has no matching action and stays refused). Raised to the parent as a separate story; no claim that it is harmless or covered |
| RS-4 | Update timing outside Lean (KR-01). | source and model inspection | separate ticket; correspondence claim held |

## Ambiguities left open

- Whether merging this repair is itself held by the consumer conflict, or only the consumer-integration claim is. The constitution holds the affected claim; the parent decides which.
