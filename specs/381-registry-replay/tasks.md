# Finish the independent-user registry journey

The value is two users operating one registry from public history without
sharing files. Replay and command migration already landed; this list tracks
the remaining acceptance, in the four runs the [mandate](mandate.md) orders. One
source writer works at a time, under the October 9 staffing ruling, and the
frozen gate decides each run's end.

## Done before this stack

- [x] T001 Preserve the old branch and rebase onto main `23964e66`; regenerate conflicting speech companions in `docs/` (rebased head `fdc6523a`).
- [x] T002 Reconcile merged #419 and the staffing instruction in `specs/381-registry-replay/{spec,plan,decisions}.md`.
- [x] T008 [US2] Run and reconcile `offchain/e2e-test/Singular/Registry/E2E/ReplaySpec.hs` and `offchain/test/Singular/Registry/TrieStateContractSpec.hs` for every-fold roots, mixed folds, input order and proofs. Executed October 7: 48 replay and 36 capability examples passed; scope and limits in [verification](verification.md).
- [x] T010 [US2] Verify replay controls detect wrong edges, corrupted proofs and missing history; retained in [verification](verification.md).
- [x] prepare-empty-actor-harness Make a private creator registry and start Alice and Bob with empty homes, tracing every process, with all fourteen product requirements published as pending.
- [x] verify-component-actor-controls Check two actors' public-fact decisions at component level, with five wired faults that each turn a named check red; align the fixture with public carried datums.
- [x] T012 Reconcile user instructions and historical mirror statements in `docs/consumer-onboarding.md`, `docs/singular-node.md`, `specs/324-indexer-view/plan.md` and `specs/362-separate-fold/spec.md`; regenerate affected speech companions.

## Stack and dependency

- [x] T003 Consume the published token-only interface: joining by state token merged in issue 501, and the managed state directory is PR 525. The branch is stacked on PR 525 at `026576268e916c964426d4a4be304d35544d9816`, recorded in [plan](plan.md) and the [mandate](mandate.md). No copied creator identity file.
- [x] stack-on-managed-state-ticket Rebase the nine commits of this ticket onto PR 525, keeping the previous tip as `archive/e371-381-before-485-stack-20261009`.

## Run one: docs baseline, token-only actors, isolation (US1, P1)

Independent check: real CLI receipts from separate empty homes; each user starts
only with the state token, a wallet and the provider address.

- [ ] clear-docs-baseline Regenerate the six stale narration clips and the speech stamp of `docs/singular-node.md`, and remove the seven orphan clips, in one commit that contains nothing else.
- [ ] T004 [US1] Replace pending actor setup with the real token-only commands in `tools/registry_two_actors.py`; the creator and both actors use the managed state, with no directory option; trace every process; no assertion reads a home or state directory.
- [ ] guard-detects-foreign-open Run the foreign-open control after a passing positive run and require the guard, and only the guard, to fail the run.
- [ ] each-actor-inserts-and-folds [US1] Each actor proves a key absent, books its insertion, folds it, and reads it active, from its own replay.
- [ ] add-journey-hosted-jobs Add the journey job and its control job to `.github/workflows/registry.yml`, and the control to `flake.nix`, modelled on the existing two-actor control.

## Run two: cross-actor folds and refusals (US1, P1)

- [ ] T005 [US1] The other actor folds each termination, and each insertion, from public data, in both directions, including insertion folds using the carried datum.
- [ ] only-the-controller-updates-or-terminates [US1] The other actor's update and terminate are refused by name, with the root and pending requests unchanged.
- [ ] T007 [US1] Compare both actors' inspect roots to every fold's state root.

## Run three: reject and reclaim across actors (US1, P1)

- [ ] T006 [US1] Execute cross-actor reject of an expired request, wrong-owner reclaim and the valid reclaim inside the window; record the actual refusal names and exit codes.

## Run four: history faults, report and publication (US2, P1)

- [ ] T009 [US2] Withheld fold history through the actor's command refuses `HistoryIncomplete` with no trie; a replay that maps one edge wrongly, in a control build, refuses `RootDoesNotChain` with no trie.
- [ ] T011 Compute all fourteen row states from the executed receipts in `tools/registry_two_actors.py`; the two rows that read the registry page stay pending on issue 503; keep harness evidence in a marked appendix.
- [ ] reconcile-onboarding-join-statement Correct the statement in `docs/consumer-onboarding.md` that joining by state token is pending under issue 437, regenerating its speech companion and narration.
- [ ] T013 Run the packaged journey and `nix develop --quiet -c just ci` on the final candidate; record candidate, Lean tree, commands, receipts and limits in `specs/381-registry-replay/verification.md`.
- [ ] T014 Update PR 433 from `.github/pull_request_template.md` with the words "stacked on PR 525", verify the hosted required checks on the exact head, and hand the head to the desk for the merge slot. Close issue 381 only when every required journey row has executed.

## Order and model binding

Run one precedes the rest; runs two to four each start when the run before has all
its checkpoints approved. Lean tree: `16ee2d4a4233130460b7e36daffbe6f2b8b9a8ef`;
`Singular.step`, `exitStep`, `foldActions`, `buildFold` and the public-fold-input
statements. No semantic change is planned. A mixed transaction is checked by the
compiled state validator; it has no whole-transaction Lean correspondence claim.
Public networks remain read-only.
