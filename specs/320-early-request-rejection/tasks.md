# Tasks

Stable IDs. A task is checked when its own evidence exists at an exact commit, with that evidence and its limits stated beside it. A checked task is not whole-ticket acceptance: the full root CI, S2, S3 and the held questions remain open.

## Planning

- [x] T001 Bind the issue, ruling, Lean blob and base; read the constitution, contributor instructions and pull request template.
- [x] T002 Record the root CI baseline at the base and classify its failure (research).
- [x] T003 Inventory every caller of the old rule and every identity pin it moves (research).
- [x] T004 Write the specification, plan, module, data and function models, quickstart and checklist.
- [x] T005 Independent review of the planning commits: the first review blocked on per-invocation counts, fixed forward; the later reviews approved the final planning head 9462beb.
- [x] T006 Row scope answered: one new Singular-sourced row and CG23's timing words (gate page, The rows change).
- [x] T007 The S1 runtime gate is derived from the gate page (sha256 dde548c8…) and versioned forward, with every version kept: the first, then a raised cap and a candidate-bound CG09 receipt, then the two doc speech companions in the fence, then a cap for the INV-03 state witness.

## S1 validators, identities and CG09

- [x] T010 RED: early-rejection tests for the state and request purposes, and early refund-floor refusals, seen failing on the base for the stated reason (INV-01, INV-02, INV-04). Commit 89d0ec9: G1 fails on the unchanged validators. The state-purpose and refund-floor tests fail with the `not-rejectable` guard trace in both windows. The request-purpose tests, in both action orders, fail on the request script's timing expectation. No setup or decoding failure.
- [x] T011 Remove the timing rule from the state's reject (INV-01, INV-05). Commit db9354b; G1 green at 4d8772d. Compiled evidence only for the windows; the live early reject is CG09's (T017).
- [x] T012 Request purpose admits its matching reject in any window; update timing kept (INV-02, INV-03). Commit db9354b; G1 green at 4d8772d. Two mutations (admit on any reject, admit on the first action) each fail the two-request request-purpose test with identity consistent. Commit d4e2eea adds the state-side witness: an update outside the processing window is refused with `not-phase1` as the first reason, its in-window twin accepted, and a mutant without the guard fails the four out-of-window refusal tests and the existing `modify_in_phase2`, and nothing else. The in-window twin still passes. The update-timing rule is current validator behaviour outside Lean, under the fold-correspondence hold. Outside the processing window an unpaired request is refused; inside it, admission is as before.
- [x] T013 Remove the rejectability predicate and wrapper. Restate the properties and tests that encoded the old rule (INV-07). Commit db9354b; G1 green at 4d8772d.
- [x] T014 Read the new state hash from the built registry blueprint, set the witness and envelope pins to it, then regenerate the registry manifest. The witness pin moves the witness and open-datum hashes, so the regeneration comes after it (INV-08). Commits 1441883, cf923bd, 14ee6d6 (a derived envelope-digest pin first missed, caught by G1, repaired forward). G1 and G5 green at 4d8772d.
- [x] T015 Update the naming state pin, regenerate, update the retirement-custody pins, regenerate again (INV-08). Commits fcae162, 58740e1, 024231f; G2 and G3 green.
- [x] T016 Record compiled sizes and the execution units of both purposes on a processing-window reject, before and after (INV-13). Base sizes come from cached base blueprints matched to the base manifest in both directions. Units come from the compiled test run and the CG09 receipt, not ledger-evaluated per purpose.
- [x] T017 CG09 records the chain's acceptance as held, after its refused one-lovelace-short control on the same request, with full-fold units. The G10 step body and `docs/consumer-conformance.md` state it. The consumer requirement text is unchanged (INV-11, INV-14). Commit e9102fb; the CG09 row alone at 4d8772d, on a clean tree: accepted and held, never agreement, with its short refund refused and attributed to the state script. The whole generic-rows session (G10) has not run.
- [x] T018 Drop `not-rejectable` from `docs/onchain-validator-owners.md`, the validator doc comments and the conformance comments that state the old rule as fact. CG09's public text states the requirement in words (acfd508); the presentation check and G4 pass at acfd508.
- [x] T019 The deployed identity check compares the naming scripts' compiled code with the registry's current state hash and the current retirement-custody hash. It is seen failing on the stale naming pin before T015 (INV-08). Commit a060e07; G5 refused at the stale pin before any devnet, then green at 4d8772d. Limit: it checks that the hash bytes are present in the compiled code, not how the constant is used.

## S2 product builder

- [x] T020 The reject builder drops its timing selection and deadline-bound validity (INV-09). Commit 6b22215: every pending request of the registry is selected; validity is finite from the current slot and bound to no deadline. Off-chain lint, component build and unit suite pass at 6640f4a. The vectors check was not run in this slice, so G6 is not claimed as a whole. One unprocessable request now blocks every builder reject, in any window.
- [x] T021 Devnet e2e: processing- and retraction-window rejects through the builder, each interval asserted inside its window, refund and unchanged state read back from the ledger. "rejects a phase-3 request" keeps its name (INV-05, INV-09). Commit 6640f4a; G7 at 6640f4a: 25 examples, 0 failures, both built intervals inside their windows, the phase-3 case unchanged. No live run against the old builder was made. The processing-window case reaches the request script's processing-window arm; the matching-action path runs live in the retraction-window and phase-3 cases.
- [x] T022 Restate `requestPhase`'s documentation as a resuming client's choice of exit. Commit 6b22215, documentation only; the classifier is unchanged.

## S3 evidence in the story language

- [x] T030 Every reject in the story language carries a placement. The interpreter realizes it and refuses a mismatch as setup failure. The book renders every placement, with a totality control over all of them (D-04). Commit fb63107: story validation refuses an unplaced reject, the interpreter checks the built interval before submitting and logs each placement, and the book renders all three placements. G8 at ada8d8f: unit suite and running book, six chapters, 0 failures.
- [x] T031 CG23 places its rejects after the windows. Its CI assertion is byte-identical (INV-12). Commit fb63107; G9 at ada8d8f runs the reviewed CG23 step and passes; the workflow's CG23 step is unchanged from the base.
- [x] T032 CG24: untampered rejects in the processing and retraction windows accepted by both; tampered short and other-address refunds refused by both; the exact rows change; the dispatcher, book chapters, row count and published counts; the G11 step body (INV-10, INV-14). Commit fb63107 (format-only follow-up ada8d8f); G11 at ada8d8f: six steps in order, every comparison agrees, three placements inside each window, refusals attributed to the state script by hash. The workflow's CG24 step equals the gate page's body. Live refusal reasons are not observed on chain; the compiled tests name them. The whole generic-rows session (G10) and root CI have not run.

## Acceptance

- [ ] T040 Exact-head gate G0–G13 green, every checkpoint approved by the auditor, limits written into the pull request.
