# Consistency analysis

## Coverage

| Requirement | Invariants | Tasks | Gate rows |
|---|---|---|---|
| state-script-accepts-rejected-action-for-request | state-purpose-admits-rejected-in-processing-window, reject-continues-state-unchanged-mints-nothing | red-early-rejection-tests-for-state-request, remove-timing-rule-from-state-s-reject | aiken-suite-properties-format-registry-identity, deployed-identity-both-ways-naming-scripts-embedded |
| request-script-spent-by-contribute-accepts-state | request-purpose-admits-contribute-whose-matching-state | red-early-rejection-tests-for-state-request, request-purpose-admits-its-matching-reject-in | aiken-suite-properties-format-registry-identity |
| rejection-still-owes-owner-held-tip-positionally | refund-floor-held-in-early-windows-short | red-early-rejection-tests-for-state-request | aiken-suite-properties-format-registry-identity, body-reject-inside-processing-retraction-windows-early |
| rejection-leaves-state-datum-root-value-as | reject-continues-state-unchanged-mints-nothing | remove-timing-rule-from-state-s-reject, devnet-e2e-processing-retraction-window-rejects-through | aiken-suite-properties-format-registry-identity, product-builder-on-devnet, body-reject-inside-processing-retraction-windows-early |
| off-chain-reject-builder-builds-accepted-rejection | product-reject-builder-s-transaction-accepted-on | reject-builder-drops-its-timing-selection-deadline, devnet-e2e-processing-retraction-window-rejects-through | product-builder-on-devnet |
| published-conformance-evidence-shows-early-rejections-accepted | model-bound-early-rejections-agree-lean-untampered, reject-retract-refund-controls-keeps-its-evidence, workflow-carries-acceptance-checks-step-bodies-byte | reject-in-story-language-carries-placement-interpreter–reject-inside-processing-retraction-windows-untampered-rejects | conformance-unit-suite-running-book, body-reject-retract-refund-controls-unchanged, body-reject-inside-processing-retraction-windows-early |
| consumer-requirement-that-forbids-early-rejection-cardano | reject-before-deadline-consumer-requirement-consumer-requirement, workflow-carries-acceptance-checks-step-bodies-byte | reject-before-deadline-consumer-requirement-records-chain | body-generic-rows-reject-before-deadline-consumer |
| compiled-script-identity-repair-moves-regenerated-by | identity-moved-hash-equals-its-regenerated-manifest | read-new-state-hash-from-built-registry, update-naming-state-pin-regenerate-update-retirement | aiken-suite-properties-format-registry-identity, naming-suite-identity, blueprint-nix-build-quiet-no-link-print, nix-build-quiet-build-gate-root, deployed-identity-both-ways-naming-scripts-embedded |
| fold-update-stays-processing-window-state-script | update-timing-preserved-state-refuses-update-outside | request-purpose-admits-its-matching-reject-in | aiken-suite-properties-format-registry-identity |
| retraction-unchanged-insertion-or-read-owner-signed | retraction-refusals-acceptance-unchanged | remove-timing-rule-from-state-s-reject–remove-rejectability-predicate-wrapper-restate-properties-tests | aiken-suite-properties-format-registry-identity, body-reject-retract-refund-controls-unchanged |
| other-fold-rule-signer-rule-token-identity | reject-continues-state-unchanged-mints-nothing, retraction-refusals-acceptance-unchanged | remove-timing-rule-from-state-s-reject–remove-rejectability-predicate-wrapper-restate-properties-tests | aiken-suite-properties-format-registry-identity, off-chain-lint-build-unit-vectors, nix-develop-quiet-c-just-ci-standard |
| lean-model-constitution-consumer-s-requirement-rows | — | every task (path fence) | once |
| — | compiled-sizes-state-request-scripts-execution-units | record-compiled-sizes-execution-units-both-purposes | measurement receipt |

Every functional requirement has at least one invariant, one task and one gate row. Every invariant appears in a task.

## Terminology

The model's words are used throughout: reject, retract, fold, deposit, tip, obligations. Window names follow the constitution's retraction row: processing window, retraction window, after the windows. "Phase 1/2/3" appears only where existing code and tests use it.

## Contradictions found and how they are carried

| Finding | Where | Disposition |
|---|---|---|
| The validator refuses an update outside the processing window; Lean admits a fold in every window. | `registry/fold.ak`, `request.ak` against `Model.lean` | A separate code-against-model discrepancy, repaired by its own ticket. Kept unchanged in this bounded diff (fold-update-stays-processing-window-state-script), labeled current validator behaviour outside Lean, its correspondence claim held. |
| The consumer's forbids-early-rejection-singular-s-lean-allows forbids early rejection; Singular's Lean allows it. | reject-before-deadline-consumer-requirement | Unmet by ruling (`unmet-by-ruling`, operator ruling 2026-10-01); requirement preserved (consumer-requirement-that-forbids-early-rejection-cardano). |
| reject-and-retract-refund-controls's published requirement states the old timing as product text. | `conformance/rows.json` | Its two timing sentences are restated; its rejects stay placed after the windows. |
| The builder's documentation says it builds rejects "for Phase 3 requests". | `Reject.hs` | Restated with the selection change (reject-builder-drops-its-timing-selection-deadline). |

## Residuals and their dispositions

| ID | Residual | Evidence and its limit | Disposition |
|---|---|---|---|
| builder-reject-deposit-mismatch | The builder rejects every pending request, fresh ones too. One unprocessable request (a deposit that does not match) makes any builder reject refuse `deposit-mismatch`, as it already did for expired requests. | source: `registry/fold.ak` carriage checks, `TxBuilder/Reject.hs` selection; no live run | named limit (spec Holds and limits); selecting a subset or skipping unprocessable requests is a non-goal here, a candidate follow-up for the parent |
| prose-outside-the-fence-still-reads-the-old | Prose outside the fence still reads the old rule: an off-chain unit test's name ("treats the retract deadline slot itself as rejectable") and a retirement journey message ("phase 3 (rejectable)"). | source only; behaviour unaffected, the policy function and the journey's refusal are unchanged | non-goal: wording outside the fence, left as is |
| a-request-whose-datum-is-a-hash-rather | A request whose datum is a hash rather than inline is admitted by `Contribute` in the processing window, and the state's fold does not fold it (it folds inline request datums only). Such a spend is an exit with no obligation, which the model does not have. | source branches only (`request.ak` reads the datum the spend handler is given; `registry/fold.ak` `mkAction` folds inline datums). No compiled or live counterexample yet. Whether the datum's preimage is obtainable by a third party is not established. | unchanged by this repair (outside the processing window it has no matching action and stays refused). Raised to the parent as a separate story; no claim that it is harmless or covered |
| update-timing-outside-lean-fold-update-stays-processing | Update timing outside Lean (fold-update-stays-processing-window-state-script). | source and model inspection | separate ticket; correspondence claim held |

## Ambiguities left open

- Whether merging this repair is itself held by the consumer conflict, or only the consumer-integration claim is. The constitution holds the affected claim; the parent decides which.
