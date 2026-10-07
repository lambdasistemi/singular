# Finish the independent-user registry journey

The value is two users operating one registry from public history without
sharing files. Replay and command migration already landed; this list tracks
the remaining acceptance. Execute serially with the existing Sol, Muse and GLM
team under the owner. No parallel assignments or auditor seats.

## Setup and dependency

- [x] T001 Preserve the old branch and rebase onto main `23964e66`; regenerate conflicting speech companions in `docs/` (rebased head `fdc6523a`).
- [x] T002 Reconcile merged #419 and the current staffing instruction in `specs/381-registry-replay/{spec,plan,decisions}.md`.
- [ ] T003 Resolve the stopped #437 dependency, consume its published token-only interface, and record its exact revision in `specs/381-registry-replay/plan.md`. No copied creator identity file.

## US1 — Independent users join and operate (P1)

Independent check: real CLI receipts from separate empty homes and directories;
each user starts only with public registry information and their own wallet.

- [ ] T004 [US1] Replace pending actor setup with the real token-only interface in `tools/registry_two_actors.py`; trace every actor process and check foreign-directory hashes after each command.
- [ ] T005 [US1] Execute both actors' insert and terminate lifecycles and both directions of cross-actor folding in `tools/registry_two_actors.py`, including insertion folds using the public carried datum.
- [ ] T006 [US1] Execute wrong-controller update/terminate, cross-actor reject, wrong-owner reclaim and valid phase-2 reclaim in `tools/registry_two_actors.py`; record actual refusal reasons and exit codes.
- [ ] T007 [US1] Compare both actors' inspect roots to each fold's state datum in `tools/registry_two_actors.py`; run the deliberate foreign-file-open control and require its detection.

## US2 — Public history gives valid proofs or a named refusal (P1)

Independent check: provider history reaches the selected state root; proof
verification and deliberate history faults establish the boundary independently.

- [x] T008 [US2] Run and reconcile existing `offchain/e2e-test/Singular/Registry/E2E/ReplaySpec.hs` and `offchain/test/Singular/Registry/TrieStateContractSpec.hs` coverage for every-fold roots, mixed applied/rejected folds, input order and membership/non-membership proofs. Preserve the validator oracle for mixed folds; add only missing acceptance cases. Executed October 7: 48 replay and 36 capability examples passed; source binding and limits in [verification](verification.md).
- [ ] T009 [US2] Exercise withheld-fold and altered-request-edge provider responses through the actual actor CLI in `tools/registry_two_actors.py`; require `HistoryIncomplete` and `RootDoesNotChain` respectively, with no trie returned.
- [x] T010 [US2] Verify replay controls in `offchain/e2e-test/Singular/Registry/E2E/ReplaySpec.hs` detect wrong edges, corrupted proofs and missing history; retain exact commands and outcomes in `specs/381-registry-replay/verification.md`. Executed October 7: altered-edge and missing-history refusals and corrupted-proof rejection passed within the 48-example replay scope.

## Publication and completion

- [ ] T011 Compute all product row states from executed receipts in `tools/registry_two_actors.py`; remove the obsolete #419 pending dependency and keep harness controls in a marked appendix. Missing evidence remains visible.
- [ ] T012 Reconcile user instructions and historical mirror statements in `docs/consumer-onboarding.md`, `docs/singular-node.md`, `specs/324-indexer-view/plan.md` and `specs/362-separate-fold/spec.md`; regenerate affected speech companions.
- [ ] T013 Run the packaged two-actor journey and `nix develop --quiet -c just ci` on the final candidate; record candidate, Lean revision, commands, receipts and limits in `specs/381-registry-replay/verification.md`.
- [ ] T014 Update PR #433 using `.github/pull_request_template.md`, verify hosted required checks on that exact head, merge the completed ticket work and close #381 only when all required journey rows have executed successfully.

## Order and model binding

T001–T002 are complete. T003 precedes T004–T007 and T009. T008 and T010
can run while the dependency is stopped, still one worker at a time. Then finish
T011–T014. No partial harness is presented as the completed user story.

Lean revision: `bb9c21fa9f09eafb0cf8b69ee2ab3cd010762713`;
`Singular.step`, `exitStep`, `foldActions`, `buildFold` and public-fold-input
statements. No semantic change is planned. A mixed transaction is checked by
the compiled state validator; it has no whole-transaction Lean correspondence
claim. Public networks remain read-only.
