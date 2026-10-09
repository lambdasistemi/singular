# Touch list

Every file this ticket edits, creates or deletes, so the merge order can be decided from what each pull request touches. Read the [plan](plan.md) for the two pull requests. Base: `main` at `8a99415d`; the command-line split (#528) merged as `c6748950` before this branch's first push. Paths below are the paths at that base. A file not on this list that the work later needs is a question to the epic owner, forwarded to the desk, before it is edited.

Columns: **PR** is the pull request that touches it, under the cut the epic owner ruled on 2026-10-11 (1: selection, builder, command change, the devnet item for an excluded request and the page describing `registry fold`; 2: the receipt readers that read the new fields and the other pages; 3: many requests per fold, the former pull request 2). **#528 open work** says whether the split still has work on the file after the base: *none*, or the branch of the split that still edits it (the overlap table at the end names them). **Live slices** names another lane whose files this row meets. Rows marked *added at the amendment* were not in the reviewed set `b7c77ae6`; the reason is in the row.

Where the code lives at this base: the registry's command-line modules are the public library `registry-cli` of `offchain/singular-registry.cabal`, source directory `offchain/cli/src/`; their module names and paths did not change. The open datum's entry commands, parser, executable and specs left that directory for the package `open-datum` under `applications/open-datum/offchain/`.

## Registry library

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `offchain/lib/Singular/Registry/FoldSelection.hs` | 1 | create | the pure selection, both reason vocabularies and the capacity bound | none | #471 moves library modules into new components: the module follows its owner |
| `offchain/lib/Singular/Registry/TxBuilder/Update.hs` | 1, 3 | edit | PR 1: build over one chosen pending request instead of all; PR 3: over several, validity bound the earliest deadline | none | #471 moves it; #519, #358 and #496 share the fold builder, ordered after this ticket |
| `offchain/lib/Singular/Registry/TxBuilder/Update/Context.hs` | 1, 3 | edit | the pending-request query takes the chosen set; the upper bound reads it | none | same as above |
| `offchain/singular-registry.cabal` | 1, 3 | edit | expose the new module in the main library; register the new spec modules of the `cage-tests` suite | none (the booking refusal is in the base) | #485 edits the same file; #471 reshuffles it |

## Registry command line (`registry-cli`, `offchain/cli/src/`)

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `offchain/cli/src/Singular/CLI/FoldRules.hs` | 1 | edit | delete `foldTarget`, `FoldTargetRefusal`, `renderTargetRefusal`; add the named-request guard, refusal wording and `spendsSelection`. `boundStartMs`, `fundedView` and `placedEdge` stay exported (`Reclaim` imports them) | none | none |
| `offchain/cli/src/Singular/CLI/Fold.hs` | 1, 3 | edit | PR 1: `foldPending` (it takes the application value first at this base) reads the live facts, calls the selection, makes one application step per request through the value, prints the list receipt; a termination under the neutral value becomes the exclusion `application-required` in place of the whole-command refusal; PR 3: many requests | none (the booking refusal is in the base) | #485 edits `Fold.hs` |
| `offchain/cli/src/Singular/CLI/Command.hs` | 1 | edit | the module header states "folds the one pending request"; the `--request` help text only if it changes. The documented-flags job compares the help with the pages | none | #485 edits `Command.hs` |
| `offchain/cli/src/Singular/CLI/Trace.hs` | 1 | edit, only if the narration needs a typed event for an exclusion | the narration must agree with the receipt | none | none |
| `offchain/cli/src/Singular/CLI/Session.hs` | 3 | edit | **collision.** `Expectation` (one key, edge and root pair becomes a list of transitions), `expecting`, `blankEntry` (the four scalar journal fields) and the prepared-line construction in `journalledSubmit`. PR 1 does not touch this file | none | **#485, #477, #493 own the state-directory and session layer** |
| `offchain/cli/src/Singular/CLI/Receipt.hs` | 3 | edit | **collision.** `JournalEntry` gains the transition list; its JSON instances read an earlier line as a list of one | none | #477 builds on this journal format after PR 3 |
| `offchain/cli/src/Singular/CLI/Reconcile.hs` | 3 | edit | **collision.** `observe` reads each key against its last transition; `rollBack` returns every included request and restores the root before | none | #477 builds on this after PR 3 |

## Open-datum package (`applications/open-datum/offchain/`)

The split moved the combined forms and their specs here. These rows are the only ones in the open-datum tree; the split's remaining work on the executable (the booking refusal edits `Entry.hs`) meets them.

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Entry.hs` | 1 | edit | the combined forms (`foldAfter`) read the new fold result and print the same list receipt; the partial stop names the request that stays pending and the exclusion reason | none (the booking refusal is in the base) | #485 edits the entry commands |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Command.hs` | 1 | edit | the module header states "folds the one pending request"; the swap rule removes the sentence with the rule | none | none |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/FoldSpec.hs` | 1 | edit | delete the group that tests `foldTarget` and its refusals (the functions are deleted, so the suite would not compile); the replacements are in `cage-tests`, see the registry tests below | none | #485 |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/RecoverySpec.hs` | 3 | edit | a pre-change journal line, chained transitions, observation and rollback for many | none | #477 |

## Tests in the registry package (`cage-tests`)

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `offchain/test/Singular/Registry/FoldSelectionSpec.hs` | 1 | create | the selection: example, independence, one per key, vocabularies, capacity | none | none |
| `offchain/test/Singular/Registry/TxBuilder/SelectedFoldSpec.hs` | 1, 3 | create | the builder spends exactly the chosen requests among those pending | none | #471 |
| `offchain/test/Singular/CLI/FoldRulesSpec.hs` | 1 | create | **added at the amendment.** The named-request guard, its refusal wording and `spendsSelection`, tested in the suite a hosted job runs; the old tests of the one-request rule sat in the open-datum `FoldSpec`, which no hosted job runs at the base (see the question that lists these files) | none | none |
| `offchain/test/Main.hs` | 1 | edit | register the three new specs | none | none |

## Conformance

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `conformance/test/Conformance/Support/FoldSelection.hs` | 1 | create | the selected batch asked of the model's `foldBatch`, with the same-key control | none | none |
| `conformance/test/Main.hs` | 1 | edit | register it | none | none |
| `conformance/conformance.cabal` | 1 | edit | list the new test module | none | none |
| `conformance/lib/Conformance/Cli/Controls.hs` | 2, 3 | edit | read the list receipt; controls for an excluded request, for many | none | #485, #381 |
| `conformance/test/Conformance/Support/CliControls.hs` | 2, 3 | edit | the same, in the unit fixtures | none | #485, #381 |

## Scripts and pages

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `tools/demo1_cli_journey.sh` | 1, 3 | edit | PR 1: an unsettleable request is left and named while an eligible one settles (the journey reads the new `excluded` list; the earlier receipt fields stay); PR 3: two actors book and one fold settles both. It runs `singular` for `registry fold` and `open-datum` for the entry commands | none | **#485, #381** |
| `tools/cli_recovery_controls.sh` | 2, 3 | edit | PR 2: the list shape; PR 3: interrupt a two-request fold and reconcile both | none (the recovery journeys through both binaries are in the base) | #477 |
| `tools/demo1_cli_controls_check.sh` | 2 | edit, only if its rows read a fold receipt | the controls follow the shape | none | #485 |
| `docs/singular-node.md`, its `.speech.json` | 1, 3 | edit | the fold, its receipt, the two vocabularies, the capacity bound, the sentence "exactly one is pending" | none | none |
| `docs/cli-recovery.md`, its `.speech.json` | 3 | edit | recovery of a many-request fold | none | #477 |
| `docs/demo1-preprod.md`, its `.speech.json` | 2 | edit | the sentence that a registry's fold takes every pending request | none | none |
| `docs/offchain-fold-responsibilities.md`, its `.speech.json` | 2 | edit | the selection module is the owner of what a fold takes | none | #471 |
| `docs/offchain-api-reference.md`, its `.speech.json` | 1 | edit | **added at the amendment.** The page lists every module of the library and its counts, and the documentation check fails until they agree; the new `Singular.Registry.FoldSelection` changes both | none | **#471 moves modules; #528 edited the page** |
| `onchain-release/DEMO1.md`, its `.speech.json` | 2, 3 | edit | the rehearsal command and what the fold does | none | none |
| `docs/audio/index.json`, `docs/audio/manifest.json`, the clips of the changed pages under `docs/audio/clips/` | 1, 2, 3 | edit, create | narration regenerated from the merged pages after the final rebase, never merged by hand (the standing authorization of the documentation skill) | none | **any lane that edits a page** (the index and manifest are shared and binary clips conflict) |
| `specs/518-fold-every-settleable/*` | 1 | create | this record | none | none |

No file is deleted. No file outside this table is edited.

## Overlap with work the split owned

The command-line split merged as `c6748950` and its later branches were part of main by `8a99415d`; no overlap with unmerged work remains. The files that main changed after this branch's first base and that this branch also edits (the API reference page and its speech companion, `offchain/singular-registry.cabal`, the audio index and manifest) were resolved by the rebases, the narration being regenerated from the merged pages and never merged by hand.

## Shared surfaces

| surface | touched |
|---|---|
| cabal files | touched: `offchain/singular-registry.cabal`, `conformance/conformance.cabal` |
| nix apps and checks | not touched: the existing apps (`cage-tests`, `conformance-appendix-tests`, `demo1-cli-check`, the recovery apps) already run what changes |
| workflows | not touched |
| registry command-line modules | touched: `FoldRules`, `Fold`, `Command` (header), `Trace` (conditional); PR 3 adds `Session`, `Receipt`, `Reconcile` |
| open-datum package | touched: `Entry.hs`, `Command.hs` (header), the specs `FoldSpec.hs` (PR 1) and `RecoverySpec.hs` (PR 3) |
| library modules | touched: the new `FoldSelection`, `TxBuilder/Update`, `TxBuilder/Update/Context` |
| Lean | not touched |
| validators and blueprint | not touched |
| state-directory and session layer (#485, #477, #493) | PR 1 and PR 2 not touched; PR 3 touches `Session.hs`, `Receipt.hs`, `Reconcile.hs` as listed, for the journal's transition list only |
| funding and publication layer (#471, #406, #478, #479, #491) | not touched, except that #471 moves the library modules listed above |
| command-line split (#528) | the base contains it; the overlap table above lists what it still owns |
