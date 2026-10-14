# Touch list

Every file this ticket edits, creates or deletes, so the merge order can be decided from what each pull request touches. Read the [plan](plan.md) for the four pull requests. Base: main `38c7fbc1`. A file not on this list that the work later needs is a question to the epic owner, forwarded to the desk, before it is edited.

Columns: **PR** is the pull request that touches it (1 the within-batch rule in the model; 2 the window in the model; 3 the builder, selection and receipt; 4 the compiled-validator evidence). **Change** says edit, create or regenerate; a regenerated file is derived, written by the command in its row, and never edited or merged by hand, at a rebase least of all. **Collides with** names a live lane whose files this row meets, measured on 2026-10-14 from the lane's branch or open pull request: **494** is the protected rejection lane (draft pull request 615), **503** the registry page lane (draft pull request 628), **491** the wallet preparation lane, **495**, **529** and **506** the other validator and Lean lanes in the desk's serial order (their branches carry plans only, so their rows are what their plans name). Pull requests 516 (#471), 384 (#233) and 597 (a workflow change) share no file with this list. Command-line modules are under `offchain/cli/src/Singular/CLI/` and keep their module names after the command-line split (#528).

## Files shared with a live lane

| lane | files of this list that the lane also edits or plans to edit |
|---|---|
| 494, pull request 615 (today) | `lean/Singular/Model.lean`, `Statements.lean`, `Lemmas.lean`, `Driver.lean`; `lean/Main.lean`, `DriverMain.lean`, `M1Main.lean`; the five corpora and `lean/theorem-debt.json`; `simulator/core.mjs`, `actions.mjs`, `gate.mjs`, `stories.json`, `corpus.json`, `identity.json`, `index.html` and the byte mirror under `simulator/formal/`; `tools/check_model.py`, `tools/check_m1_transport.py`; `conformance/lean/DriverTransport.lean`, `conformance/test/Conformance/Support/DriverTransport.hs`, `ObservedTx.hs`, `conformance/app/Conformance/Run/Live.hs`, `conformance/lib/Conformance/Lean/Registration.hs`, `Retirement.hs`; the coverage `record.json`, `base-record.json`, `test_inventory.py`, `test_leanscan.py`; `conformance/rows.json`, `conformance/BOOK.md`, `.github/workflows/conformance.yml`; `docs/theorems.md`, `README.md`, the constitution; the audio index and manifest. Its slices eight to ten rewrite the fold model |
| 503, pull request 628 | `docs/singular-node.md` with its speech companion and the audio index and manifest (today); `tools/demo1_cli_journey.sh`, `onchain-release/DEMO1.md` and the registry page docs (its later slices) |
| 491 | `CLI/Fold.hs`, `CLI/FoldRules.hs`, `TxBuilder/Update/Context.hs`, `tools/demo1_cli_journey.sh`, `tools/demo1_cli_controls.sh`, `onchain-release/DEMO1.md`, `offchain/singular-registry.cabal`, `offchain/test/Main.hs` |
| 495, 529, 506 (plans) | the model and the validators in the desk's serial order: `lean/Singular/Model.lean` and the corpora; `onchain/lib/shared.ak`, `onchain/lib/registry/fold.ak`, `onchain/validators/request.ak` (not edited here); the test modules `deposit_exits.tests.ak`, `permanent_boundary.tests.ak`, `onchain/lib/registry_fixtures.ak` and `tools/m1_boundary.py` |

## Lean sources

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `lean/Singular/Model.lean` | 1, 2 | edit | PR 1: the created-holdings rule in `foldBatch`. PR 2: `Request.submittedAt` and its serialization, the fold witness, the window predicate, the admission, the fold arm of `exitAdmission`, the batch under a witness | 494 (requests, rejection, fold in slices eight to ten), 495, 529, 506 |
| `lean/Singular/Lemmas.lean` | 1 | edit | `foldBatch_inv`: repair the proof; its statement stays, so its identity stays | 494 |
| `lean/Singular/Statements.lean` | 1, 2 | edit | the new statements; restate `fold_batch_cons`, `admitted_exit_is_the_exit`, `admission_refuses_first`; repair `booked_at_most_once` and the batch-of-one statement; keep `fold_batch_claimed_mint_by_kind_key` verbatim (a conformance anchor reads it) | 494 |
| `lean/Singular/Driver.lean` | 2 | edit | `Scenario.foldWitness`, `admissionWitness`, `runSurface`, `scenarioJson`, `runFoldBatch`, `BatchScenario` | 494 |
| `lean/Singular/M1.lean` | 1, 2 | edit | compatibility names for the new definitions; `excluded_fold` keeps its statement, since the fixed edge set is checked before the window, and needs a new proof; `excluded_batch_head` may need its simp set | 506 (not 494 today) |
| `lean/Singular/M1Driver.lean` | 2 | edit, only if a new driver definition is exposed | abbreviations follow the driver | none |
| `lean/Main.lean` | 1, 2 | edit | the generic corpus program: the batch rows (the pair is now refused; use two keys), the digests typed by hand, the fold rows under a witness | 494 |
| `lean/DriverMain.lean` | 1, 2 | edit | PR 1: rows for every same-key pair, the digest constants. PR 2: a witness on every fold and fold-batch row; rows for the boundary, an expired request, a batch in and past its window, no witness | 494 |
| `lean/M1Main.lean` | 1, 2 | edit | PR 1: the accepted anchor on two distinct keys, the refused pair, the expectation in `check`, the printed counts. PR 2: a witness on the fold rows | 494 |

The statement audit (`lean/Singular/Audit.lean`, `M1Audit.lean`) discovers statements by name and is not edited.

## Derived model artifacts

| path | PR | change | why and command | collides with |
|---|---|---|---|---|
| `lean/corpus.json`, `lean/driver-corpus.json` | 1, 2 | regenerate | `python3 tools/check_model.py --export` after `lake build`; the digests typed into the scenario sources are fixed first, so the export runs twice | 494; any lane that edits Lean |
| `lean/naming-corpus.json`, `lean/lifecycle-corpus.json` | 1, 2 | regenerate | source hashes only; same command | 494; any lane that edits Lean |
| `lean/m1-corpus.json` | 1, 2 | regenerate | `python3 tools/check_m1.py --export` | 494 |
| `lean/theorem-debt.json`, `lean/m1-theorem-debt.json` | 1, 2 | regenerate | the statement digests and manifest; same commands | 494 (the first), 506 |
| `simulator/formal/*` (the byte mirror) | 1, 2 | regenerate | `cp lean/Singular/*.lean lean/*.lean lean/*theorem-debt.json simulator/formal/` | 494; any lane that edits Lean |
| `simulator/corpus.json` | 1, 2 | regenerate | `cp lean/corpus.json simulator/corpus.json` | 494 |
| `simulator/identity.json` | 1, 2 | regenerate | `node simulator/identity.mjs` | 494 |
| `simulator/index.html` | 1, 2 | regenerate | `node simulator/build.mjs` | 494 |
| `applications/open-datum/corpus.json`, `applications/open-datum/ledgers.json` | 1, 2 | regenerate, only if `just application-model` reports drift | `lake -d applications/open-datum --keep-toolchain exe open-datum-application write applications/open-datum` | 494 changes `corpus.json` today |

## Checkers and the simulator

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `tools/check_model.py` | 1, 2 | edit | PR 1: the created reader in `model_batch_refusals` and `fold_batch_expectation`. PR 2: the fold-admission reason in the driver vocabulary; a fold row without a witness is `unsupported` | 494 |
| `tools/check_m1.py` | 1, 2 | edit | the hard-coded counts and the accepted anchor | none today; 506 |
| `tools/check_m1_transport.py` | 1, 2 | edit | the batch anchor; `foldWitness` on fold questions | 494 |
| `simulator/core.mjs` | 1, 2 | edit | PR 1: the created rule in `foldBatch`. PR 2: `submittedAt` in the strict request schema; the admission mirrors | 494 |
| `simulator/actions.mjs` | 2 | edit | requests emit `submittedAt` | 494 |
| `simulator/gate.mjs` | 1, 2 | edit | the fold block asserts admission and created holdings; the required refusals list and the corpus evidence check take the new reasons | 494 |
| `simulator/stories.json` | 2 | edit | every request object carries `submittedAt` | 494 |
| `simulator/page.mjs`, `simulator/page-body.html`, `tools/browser-check.mjs` | 2 | edit, only if the playable fold is made witness-aware | the page's fold answers as the model does | none |

## Conformance

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `conformance/lean/DriverTransport.lean` | 2 | edit | read `submittedAt` on a request; accept `foldWitness` on a fold scenario and a fold batch | 494, 529 |
| `conformance/test/Conformance/Support/DriverTransport.hs` | 2 | edit | the carried keys of the scenario and batch questions include `foldWitness` | 494 |
| `conformance/app/Conformance/Run/Live.hs` | 2, 4 | edit | PR 2: the fold witness off the built transaction, the request's submission time off its datum. PR 4: the dedicated row's steps | 494, 495, 529 |
| `conformance/app/Conformance/Run/Fold.hs` | 4 | edit | the fold built with an explicit upper bound past one deadline (the field `fsUpper` exists) | none |
| `conformance/test/Conformance/Support/ObservedTx.hs` | 2 | edit, only if `LiveStep` gains a field | the observed step | 494 |
| `conformance/lib/Conformance/Fold/KeyedMint.hs`, `conformance/lib/Conformance/Lean/Registration.hs`, `conformance/lib/Conformance/Lean/Retirement.hs` | 1, 2 | edit, only if a statement they pin is restated | their anchors | 494 (the last two) |
| `conformance/coverage/record/record.json` | 1, 2 | regenerate | the discovered population: sorted `name@statementSha256`, rebuilt from the inventory function (no emitter command exists) | 494, 506 |
| `conformance/coverage/record/base-record.json` | 1, 2 | edit | only the restated identities already in it, as a reviewed baseline move paired with a row in `m1-scope-retirement.md` | 494 |
| `conformance/coverage/tests/test_inventory.py`, `conformance/coverage/tests/test_leanscan.py` | 1, 2 | edit | the fixed counts (67 / 54 / 121 and its siblings) | 494 |
| `conformance/coverage/m1-scope-retirement.md` | 1, 2 | edit | the record of baseline moves | none today |
| `conformance/rows.json`, `conformance/BOOK.md` | 2, 4 | edit, one sentence each | the retraction-window row note and the book's "separate tracked discrepancy" sentence, stale once the model refuses; PR 4 adds the live row's entry if the suite's mechanism requires it | 494 |
| `.github/workflows/conformance.yml` | 4 | edit | CI change in this ticket: the new row is appended to the existing batch job's `run` command, so no job and no required check is added | 494 |
| `conformance/test/Conformance/Support/FoldAdmission.hs` | 3 | create | the library check asked against the model's question at the boundary and one past, with the failing control | #518's sibling `FoldSelection.hs` is in the same directory (merged) |
| `conformance/test/Main.hs`, `conformance/conformance.cabal` | 3 | edit | register the new module | none |

The conformance control readers of the receipt (`conformance/lib/Conformance/Cli/Controls.hs`, `conformance/test/Conformance/Support/CliControls.hs`) no longer mention `window-closed` and are not edited.

## Application model

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `applications/open-datum/lean/OpenDatumApplication/Statements.lean` | 1 | edit | the proof that unfolds `foldBatch` for a `key-exists` fact and the uses of `foldBatch_inv` | none |
| `applications/open-datum/lean/OpenDatumApplication/ProofSupport.lean` | 1 | edit, only if `foldBatch_inv` is restated | its uses | none |
| `applications/open-datum/lean/OpenDatumApplication/Driver.lean` | 2 | edit, only if the application's request reader must carry `submittedAt` | the new field has a default, so earlier constructions compile unchanged | none |

## Registry library and command line

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `offchain/lib/Singular/Registry/FoldAdmission.hs` | 3 | create | the two pure functions, mirroring the model's names | none |
| `offchain/lib/Singular/Registry/FoldSelection.hs` | 3 | edit | merged by #518: `judgeAlone` calls the library check at the probe bound; `ReasonWindowClosed` becomes the model refusal `not-phase1` with source `model-refusal`; `window-closed` is deleted from the reason list, `exclusionName` and `exclusionSource` | none |
| `offchain/lib/Singular/Registry/TxBuilder/Update.hs`, `offchain/lib/Singular/Registry/TxBuilder/Update/Context.hs` | 3 | edit | the entry points (`updateTokenSelected` among them) refuse before returning a transaction; the bound is read from the built body | 491 (`Update/Context.hs`: funding) |
| `offchain/lib/Singular/Registry/TxBuilder/ConnectedFold.hs` | 3 | edit | it repeats the upper-slot logic and must refuse the same way | none |
| `offchain/singular-registry.cabal` | 3 | edit | expose the new module; register the new spec | 491, 503 |
| `offchain/cli/src/Singular/CLI/FoldRules.hs` | 3 | edit | the post-build check (`postBuildCheck`, `postBuildDecision`, `foldWindow`) calls the library; the client refusals the model has no word for stay; the legacy combined closed-window message (`combineWindowClosedMessage`) follows the new reason | 491 |
| `offchain/cli/src/Singular/CLI/Fold.hs` | 3 | edit | the post-build decision call site, `foldPendingBounded`, the exclusion handling that tests the reason name (line 666 on the base); the receipt names the request | 491 |
| `offchain/test/Singular/Registry/FoldAdmissionSpec.hs` | 3 | create | the library check: the boundary, many requests, the first offender named, the within-batch pair | none |
| `offchain/test/Singular/Registry/FoldSelectionSpec.hs`, `offchain/test/Singular/Registry/TxBuilder/SelectedFoldSpec.hs` | 3 | edit | merged by #518: the window rule and the builder refusals take the new reason and the library check | none |
| `offchain/test/Singular/CLI/FoldRulesSpec.hs` | 3 | edit | the group "a window-closed named cause keeps every other exclusion" and the post-build groups follow the library and the new reason name | 491 |
| `offchain/test/Main.hs` | 3 | edit | register the new spec | 491 |

`offchain/cli/src/Singular/CLI/Entry.hs` and `offchain/test/Singular/CLI/FoldSpec.hs`, which the first plan listed, became open-datum files in #528 and do not mention the window; they are not edited.

## Scripts, pages and governance

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `tools/demo1_cli_journey.sh` | 3 | edit | one assertion: `fold_selection_excluded` (line 1926 on the base) reads the reason `not-phase1` and the source `model-refusal`; its failing control stays | 503 (later slices), 491 |
| `tools/demo1_cli_controls.sh` | 3 | edit, only if it reads the exclusion name | the reason name | 491 |
| `tools/cli_recovery_controls.sh` | 3 | edit, only if it reads the exclusion name | the reason name | none |
| `docs/theorems.md`, `docs/theorems.speech.json` | 1, 2 | edit, restamp | the register: the set of names, the declaration count and the changed digests (a check ties them to the manifests) | 494, 506 |
| `README.md`, `README.speech.json` | 1, 2 | edit, restamp | the proved-declaration counts a check ties to the manifests | 494; any lane that edits Lean |
| `docs/singular-node.md`, `docs/singular-node.speech.json` | 3 | edit, restamp | the policy list (line 179 on the base) loses `window-closed` and the sample receipt (line 200) names `not-phase1`; the two vocabularies and the boundary change | 503 |
| `docs/cli-recovery.md`, `onchain-release/DEMO1.md`, each with its `.speech.json` | 3 | edit, only if the page states the fold's window rule or the receipt reasons | the same sentences | 503, 491 |
| `docs/audio/index.json`, `docs/audio/manifest.json`, the clips of the changed pages under `docs/audio/clips/` | 1, 2, 3, 4 | regenerate | narration for the pages above (the standing authorization of the documentation skill) | **any lane that edits a page**: 494, 503; the index and manifest are shared and binary clips conflict |
| `.specify/memory/constitution.md` | 1, 2 | edit | one minor amendment per model pull request (1.16.0, 1.17.0): sync impact report, the translation rows, the footer | 494, 495, 506: the version number and the top report |
| `specs/519-fold-admission/*` | 1 | create | this record | none |

## Validator tests and evidence

| path | PR | change | why | collides with |
|---|---|---|---|---|
| `onchain/validators/deposit_exits.tests.ak` | 4 | edit | the exact boundary under an excluded upper bound, a different submission time per request, an open bound, an expired reject beside an in-window update | 495, 529 |
| `onchain/validators/duplicate_insert.tests.ak` or a new `onchain/validators/fold_window.tests.ak` | 4 | edit or create | the four same-key pairs with their reasons and the reason precedence | 495 |
| `onchain/lib/registry_fixtures.ak` | 4 | edit | a submission-time parameter and a bound constructor, both with defaults so earlier tests, including the open-datum application's, are unchanged | 495, 529 |
| `onchain/validators/permanent_boundary.tests.ak` | 4 | edit | export the new labelled contexts | 495, 529 |
| `tools/m1_boundary.py` | 4 | edit | evaluate the new labels against the compiled bytes; the fault control must fail them; counts derived from discovered labels | 495, 529 |

No file is deleted. No validator source file, no blueprint and no script identity entry is edited: `onchain/validators/**/*.ak` other than the test files above, `onchain/lib/**` other than `registry_fixtures.ak`, `onchain/script-identity.json`, `onchain/permanent-contract.json`, `naming-onchain/`, `applications/open-datum/onchain/`. No file outside this table is edited.

## Shared surfaces

| surface | touched |
|---|---|
| cabal files | touched: `offchain/singular-registry.cabal`, `conformance/conformance.cabal` (PR 3) |
| nix apps and checks | not touched: the existing apps (`model-check`, `simulator-check`, `cage-tests`, `conformance-appendix-tests`, `demo1-cli-check`, `application-model`) already run what changes |
| workflows | touched in PR 4 only: one `run` command of `conformance.yml`; no job is added, so no required-check change is owed |
| Lean | touched by PR 1 and PR 2 |
| validators and blueprint | source and blueprint not touched; tests, the fixtures module and the boundary checker touched by PR 4 |
| command-line modules | touched by PR 3: `FoldRules`, `Fold` |
| state-directory and session layer | not touched |
| funding and publication layer (#491, #471) | not touched; #491 edits the same command modules (see above) |
| audio index and manifest | touched by every pull request that edits a page; regenerated at each rebase from the merged pages |
