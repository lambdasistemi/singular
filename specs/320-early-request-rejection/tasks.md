# Tasks

Stable IDs. A task is checked only after its slice is accepted at an exact commit.

## Planning

- [x] T001 Bind the issue, ruling, Lean blob and base; read the constitution, contributor instructions and pull request template.
- [x] T002 Record the root CI baseline at the base and classify its failure (research).
- [x] T003 Inventory every caller of the old rule and every identity pin it moves (research).
- [x] T004 Write the specification, plan, module, data and function models, quickstart and checklist.
- [ ] T005 Independent review of this planning commit by the persistent auditor.
- [ ] T006 Freeze the gate (plan, Gate) as the runtime gate with its hash, after the row-fence answer.

## S1 validators, identities and CG09

- [ ] T010 RED: early-rejection tests for the state and request purposes, and early refund-floor refusals, seen failing on the base for the stated reason (INV-01, INV-02, INV-04).
- [ ] T011 Remove the timing rule from the state's reject (INV-01, INV-05).
- [ ] T012 Request purpose admits its matching reject in any window; update timing kept (INV-02, INV-03).
- [ ] T013 Remove the rejectability predicate and wrapper. Restate the properties and tests that encoded the old rule (INV-07).
- [ ] T014 Regenerate the registry manifest. Update the witness and envelope pins to the regenerated state hash (INV-08).
- [ ] T015 Update the naming state pin, regenerate, update the retirement-custody pins, regenerate again (INV-08).
- [ ] T016 Record compiled sizes and the execution units of both purposes on a processing-window reject, before and after (INV-13).
- [ ] T017 CG09 records the chain's acceptance as held. The generic-rows CI expectation and `docs/consumer-conformance.md` state it. The consumer requirement text is unchanged (INV-11).
- [ ] T018 Drop `not-rejectable` from `docs/onchain-validator-owners.md` and the validator doc comments.

## S2 product builder

- [ ] T020 The reject builder drops its timing selection and deadline-bound validity (INV-09).
- [ ] T021 Devnet e2e: processing- and retraction-window rejects through the builder, with refund and unchanged state read back from the ledger (INV-05, INV-09).
- [ ] T022 Restate `requestPhase`'s documentation as a resuming client's choice of exit.

## S3 evidence in the story language

- [ ] T030 Every reject in the story language carries a placement. The interpreter realizes it and refuses a mismatch as setup failure. The book renders every placement, with a totality control over all of them (D-04).
- [ ] T031 CG23 places its rejects after the windows. Its CI assertion is byte-identical (INV-12).
- [ ] T032 Early-reject story and row: untampered rejects in the processing and retraction windows accepted by both, tampered short and other-address refunds refused by both, CI step asserting INV-10 (only if the row fence opens; otherwise record the named gap).

## Acceptance

- [ ] T040 Exact-head gate G0–G13 green, every checkpoint approved by the auditor, limits written into the pull request.
