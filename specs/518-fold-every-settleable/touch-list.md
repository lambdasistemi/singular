# Touch list

Every file this ticket edits, creates or deletes, so the merge order can be decided from what each pull request touches. Read the [plan](plan.md) for the pull requests. Base of pull request 1: `main` at `8a99415d`; the command-line split (#528) merged as `c6748950` before that branch's first push. Pull request 1 merged as `9d5f4c7a`, the base of pull request 2; the rows marked 2 and 3 use the paths at that head. Paths below are the paths at that base. A file not on this list that the work later needs is a question to the epic owner, forwarded to the desk, before it is edited.

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
| `offchain/cli/src/Singular/CLI/FoldRules.hs` | 1, 2 | edit | PR 1: delete `foldTarget`, `FoldTargetRefusal`, `renderTargetRefusal`; add the named-request guard, refusal wording and `spendsSelection`. `boundStartMs`, `fundedView` and `placedEdge` stay exported (`Reclaim` imports them). PR 2: the earlier single-request receipt fields leave `earlierReceiptFields` (the seven fields the data model names, plus the datum hash and datum bytes of a datum delivery) | none | none |
| `offchain/cli/src/Singular/CLI/Fold.hs` | 1, 2, 3 | edit | PR 2: `foldedFields` builds the receipt without the earlier single-request fields. PR 1: `foldPending` (it takes the application value first at this base) reads the live facts, calls the selection, makes one application step per request through the value, prints the list receipt; a termination under the neutral value becomes the exclusion `application-required` in place of the whole-command refusal; PR 3: many requests | none (the booking refusal is in the base) | #485 edits `Fold.hs` |
| `offchain/cli/src/Singular/CLI/Command.hs` | 1 | edit | the module header states "folds the one pending request"; the `--request` help text only if it changes. The documented-flags job compares the help with the pages | none | #485 edits `Command.hs` |
| `offchain/cli/src/Singular/CLI/Trace.hs` | 1 | edit, only if the narration needs a typed event for an exclusion | the narration must agree with the receipt | none | none |
| `offchain/cli/src/Singular/CLI/Session.hs` | 3 | edit | **collision.** `Expectation` (one key, edge and root pair becomes a list of transitions), `expecting`, `blankEntry` (the four scalar journal fields) and the prepared-line construction in `journalledSubmit`. PR 1 does not touch this file | none | **#485, #477, #493 own the state-directory and session layer** |
| `offchain/cli/src/Singular/CLI/Receipt.hs` | 3 | edit | **collision.** `JournalEntry` gains the transition list; its JSON instances read an earlier line as a list of one | none | #477 builds on this journal format after PR 3 |
| `offchain/cli/src/Singular/CLI/Reconcile.hs` | 3 | edit | **collision.** `observe` reads each key against its last transition; `rollBack` returns every included request and restores the root before | none | #477 builds on this after PR 3 |

## Open-datum package (`applications/open-datum/offchain/`)

The split moved the combined forms and their specs here. These rows are the only ones in the open-datum tree; the split's remaining work on the executable (the booking refusal edits `Entry.hs`) meets them.

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Entry.hs` | 1, 2 | edit | PR 1: the combined forms (`foldAfter`) read the new fold result and print the same list receipt; the partial stop names the request that stays pending and the exclusion reason. PR 2: `insert --fold` and `terminate --fold` stop printing the fold-derived duplicates (`liveOutput`, `envelope`, `released`, `deposit`) beside the list; they keep the booking, the fold transaction, the root and the key fields | none (the booking refusal is in the base) | #485 edits the entry commands |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Command.hs` | 1 | edit | the module header states "folds the one pending request"; the swap rule removes the sentence with the rule | none | none |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/FoldSpec.hs` | 1 | edit | delete the group that tests `foldTarget` and its refusals (the functions are deleted, so the suite would not compile); the replacements are in `cage-tests`, see the registry tests below | none | #485 |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/CommandRunSpec.hs` | 2 | edit | **added at the second amendment.** Reads `liveOutput` and `released` of receipts (the folded-output check); it reads the list instead, since the top-level fields are gone | none | none |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/RecoverySpec.hs` | 3 | edit | a pre-change journal line, chained transitions, observation and rollback for many | none | #477 |

## Tests in the registry package (`cage-tests`)

| path | PR | change | why | #528 open work | live slices |
|---|---|---|---|---|---|
| `offchain/test/Singular/Registry/FoldSelectionSpec.hs` | 1 | create | the selection: example, independence, one per key, vocabularies, capacity | none | none |
| `offchain/test/Singular/Registry/TxBuilder/SelectedFoldSpec.hs` | 1, 3 | create | the builder spends exactly the chosen requests among those pending | none | #471 |
| `offchain/test/Singular/CLI/FoldRulesSpec.hs` | 1, 2 | create, edit | **added at the amendment.** PR 1: the named-request guard, its refusal wording and `spendsSelection`, tested in the suite a hosted job runs; the old tests of the one-request rule sat in the open-datum `FoldSpec`, which no hosted job runs at the base (see the question that lists these files). PR 2: the rows that pin the earlier receipt fields pin their absence and the list | none | none |
| `offchain/test/Singular/CLI/CommandRunSpec.hs` | 2 | edit | **added at the second amendment.** Reads `liveOutput` and `released` of receipts (the folded-output check); it reads the list instead | none | none |
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
| `tools/demo1_cli_journey.sh` | 1, 2, 3 | edit | PR 1: an unsettleable request is left and named while an eligible one settles (the journey reads the new `excluded` list; the earlier receipt fields stay); PR 2: every read of a fold receipt's request, key, edge, envelope or output takes it from the settled list; PR 3: two actors book and one fold settles both. It runs `singular` for `registry fold` and `open-datum` for the entry commands | none | **#485, #381** |
| `tools/registry_two_actors.py` | 2 | edit | **added at the repair of the first hosted run.** The two-actor journey reads the request and the edge of a fold receipt at eight places (the live checks of the actor, reclaim, termination and cross-insertion legs, and the offline agreements); they now take both from the settled list. The first reader search looked for distinctive field names and missed it; the hosted jobs "Two actors insert and fold from the state token alone", "Two actors, a booking at another actor's state root fails the guard" and "Two actors, a faulted replay refuses RootDoesNotChain without a trie" failed on the first push | none | **#381** (the journey is its) |
| `tools/registry_two_actors_status.test.py` | 2 | edit | **added at the repair of the first hosted run.** The fixtures that stand for a fold receipt take the settled shape, and one new case binds the request and the edge to the booking and fails when both sides are absent. It runs inside the control job of the two-actor journey, before the development network starts | none | **#381** |
| `tools/cli_recovery_controls.sh` | 3 | edit | PR 3: interrupt a two-request fold and reconcile both | none (the recovery journeys through both binaries are in the base) | #477 |
| `docs/singular-node.md`, its `.speech.json` | 1, 2, 3 | edit | PR 1: the fold, its receipt, the two vocabularies, the capacity bound, the sentence "exactly one is pending". PR 2: the sentence that the receipt keeps its earlier fields becomes the statement that they are gone and where each fact is read now (the node guide says it, per the epic owner's condition of 2026-10-11) | none | none |
| `docs/cli-recovery.md`, its `.speech.json` | 3 | edit | recovery of a many-request fold | none | #477 |
| `docs/demo1-preprod.md`, its `.speech.json` | 2 (cut point) | edit | the sentence that a registry's fold takes every pending request | none | none |
| `docs/offchain-fold-responsibilities.md`, its `.speech.json` | 2 (cut point) | edit | the selection module is the owner of what a fold takes | none | #471 |
| `docs/offchain-api-reference.md`, its `.speech.json` | 1 | edit | **added at the amendment.** The page lists every module of the library and its counts, and the documentation check fails until they agree; the new `Singular.Registry.FoldSelection` changes both | none | **#471 moves modules; #528 edited the page** |
| `onchain-release/DEMO1.md`, its `.speech.json` | 2 (cut point), 3 | edit | the rehearsal command and what the fold does | none | none |
| `docs/audio/index.json`, `docs/audio/manifest.json`, the clips of the changed pages under `docs/audio/clips/` | 1, 2, 3 | edit, create | narration regenerated from the merged pages after the final rebase, never merged by hand (the standing authorization of the documentation skill) | none | **any lane that edits a page** (the index and manifest are shared and binary clips conflict) |
| `specs/518-fold-every-settleable/*` | 1 | create | this record | none | none |

Checked at the second amendment and not edited by pull request 2: `tools/cli_recovery_controls.sh` reads only the root of a combined insert and the request of a booking receipt, none of the removed fields (it gains rows in pull request 3); `tools/demo1_cli_controls_check.sh` reads no fold receipt (the controls it runs are in `conformance/lib/Conformance/Cli/Controls.hs`). If a writer finds a reader of a removed field in either, that is a question before the edit.

The repair of the first hosted run swept by what consumes a fold receipt instead of by field names: every file that reads the JSON printed by `registry fold`, `insert --fold` or `terminate --fold` was listed with a verdict (scripts, the conformance package, both test suites, the application package, the Demo 1 and recovery scripts, the site check and the narration tools). Only the two-actor journey script and its status test still read a removed field; the others already read the settled list, read only the kept fields, or read no fold receipt.

No file is deleted. No file outside this table is edited.

## Overlap with work the split owned

The command-line split merged as `c6748950` and its later branches were part of main by `8a99415d`; no overlap with unmerged work remains. The files that main changed after this branch's first base and that this branch also edits (the API reference page and its speech companion, `offchain/singular-registry.cabal`, the audio index and manifest) were resolved by the rebases, the narration being regenerated from the merged pages and never merged by hand.

Pull request 2 against the open pull requests at `9d5f4c7a`: none of its files is among the ten files of the common-flags change (#547, pull request 554), which edits the flag reader, the two `Command.hs` files, the two cabal files and the two test `Main.hs` files; pull request 2 adds no spec module and edits none of them. The audio index and manifest are shared with the Lean model change (#508): regenerated after the last rebase, never merged by hand. Checked by listing the files of every open pull request against the files of this one.

## Pull request 3 at `e7b55ac9`

Re-derived on 2026-10-13 against `main` at `e7b55ac9` after the desk's ruling on the session layer: of `Session.hs`, `Receipt.hs` and `Reconcile.hs`, only `Reconcile.hs` is also edited by another lane (#543, the bookkeeping retention work, which adds a comment to `liveReader` and a recovery evidence check in the tools and the flake). Pull request 3 is cut in two (see the [plan](plan.md)); the rows marked 3 above are replaced by these. Column **PR**: 3a (the fold over several requests, bound stays 1), 3b (bound 9, the sweep of readers, the two-actor devnet item, the node guide) or 3c (the executed interrupted fold and the other pages; the desk's cut of 2026-10-13). The bookkeeping work (#543) merged as `af16bad4` on 2026-10-13 and the branch is rebased onto main (create funding, #406, also merged: it added lines to `offchain/singular-registry.cabal`, `offchain/test/Main.hs` and `tools/demo1_cli_journey.sh`, and changed `Registry.hs` and `TxBuilder/Edges.hs`, neither a reader of a fold receipt by name). Its files, which this branch does not touch beyond `Reconcile.hs` in 3b, were `Reconcile.hs` (a comment above `liveReader`), `flake.nix` (the evidence collector, far from the recovery partition list), `.github/workflows/registry.yml`, `tools/cli_recovery_evidence_check.sh`, the deployment, recorder and terminal modules). Pushes go only from a branch rebased onto main. Shared with the page-from-chain lane (#503): `Command.hs`, `offchain/singular-registry.cabal`, `offchain/test/Main.hs` and `offchain/test/Singular/CLI/CommandRunSpec.hs`; edits there are additive only (new lines and entries, no reordering, renaming or reformatting). A file not on this list that the work later needs is a question to the epic owner before it is edited.

| path | PR | change | why | live lanes |
|---|---|---|---|---|
| `offchain/cli/src/Singular/CLI/Receipt.hs` | 3a, 3b | edit | 3a: the journal entry gains the optional list of fold transitions; 3b: the reading side, the fallback that reads an earlier line as a list of one and the agreement check between scalars and list | #477 builds on this format after 3a; #543 does not touch it |
| `offchain/cli/src/Singular/CLI/Session.hs` | 3a | edit | the expectation carries the transitions; `blankEntry` and the prepared line in `journalledSubmit` write the list and the scalars that mirror it | #541 changed it on main; #485, #477, #493 own the state-directory layer |
| `offchain/cli/src/Singular/CLI/Fold.hs` | 3a | edit | the bound seam; the plan and the result list their settled requests; the walk per prefix; one delivery readback per settled request; the journal transitions; `foldedFields` over the list | #485 |
| `offchain/cli/src/Singular/CLI/FoldRules.hs` | 3a | edit, only if a receipt builder needs the list shape | the guard, the spend check and `foldReceiptLists` already take lists | none |
| `offchain/cli/src/Singular/CLI/Trace.hs` | 3a | edit, only if narration needs it | a fold of several requests: every settled request appears once as seen and once as folded, and the receipt agrees | none |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Entry.hs` | 3a | edit | the combined forms read their own settled entry from the result's list (two places) | #485 |
| `applications/keri-stub/offchain/src/Singular/Application/KeriStub/Convict.hs` | 3a | edit | **new consumer since pull request 561 merged.** Its combined form reads its own settled entry from the result's list | the keri stub lane |
| `applications/keri-stub/offchain/src/Singular/Application/KeriStub/Register.hs` | 3a | edit | **added by the epic owner (A-021) after the writer of run 3a-2 found it.** The keri stub's `register --fold` is a third combined form reading the single-request fields; it reads its own settled entry through the same lookup and stops partial with the same wording | the keri stub lane |
| `offchain/lib/Singular/Registry/FoldSelection.hs` | 3a, 3b | edit | 3a: the provenance text of bound 1 says recovery reads one transition; 3b: bound 9 and the spec's provenance text | none |
| `offchain/test/Singular/Registry/FoldSelectionSpec.hs` | 3a, 3b | edit | the rows that pin the bound and the provenance text | none |
| `offchain/test/Singular/CLI/FoldRulesSpec.hs` | 3a | edit | the three rows that repeat the provenance text of bound 1 | none |
| `offchain/test/Singular/Registry/TxBuilder/SelectedFoldSpec.hs` | 3a | edit | rows at two and three chosen requests among more pending: exactly them, the validity bound the earliest deadline, each with the mutation that makes it fail | none |
| `offchain/test/Singular/CLI/CommandRunSpec.hs` | 3a | edit | command-run rows at bound 3 over two and three pending requests (one transaction, every settled entry, the prepared line with chained transitions, a lost race `stale-state`) | none |
| `offchain/test/Singular/CLI/JournalTransitionsSpec.hs` | 3a | create | a line written by main, a line of three chained transitions, a scalar tampered against its list | none |
| `offchain/test/Main.hs`, `offchain/singular-registry.cabal` | 3a | edit | register the new spec module | #485 and #471 edit the cabal file |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/RecoverySpec.hs`, `.../CLISpec.hs` | 3a | edit, mechanical | four literal journal entries name every field; the new field is added (the positional constructions of `Expectation` do not change) | #477 |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/RecoverySpec.hs` | 3b | edit | observation of many: each key against its last transition, the last root after, a pre-change line, rollback | #477 |
| `offchain/cli/src/Singular/CLI/Reconcile.hs` | 3b | edit | `observe` reads every transition; rollback names every request and restores the first root before; the scalar and list agreement | **#543** (a comment in `liveReader`) |
| `conformance/lib/Conformance/Cli/Controls.hs`, `conformance/test/Conformance/Support/CliControls.hs` | 3b | edit, only if a control reads the bound | the fixtures state bound 1 with a provenance of their own | #381 |
| `tools/demo1_cli_journey.sh` | 3b | edit | the assertions of bound 1 move to 9; two actors book concurrently and one fold settles both, each payout to its owner, with tampered receipts refused | #485, #381 |
| `tools/registry_two_actors.py`, `tools/registry_two_actors_status.test.py` | 3b | edit, only where a reader of the settled list assumes one entry or a fixture states the bound | the sweep of readers of the settled list at bound 9, by what consumes a fold receipt (the lesson of pull request 2) | **#381** |
| `tools/keri_stub_journey.sh` | 3b | edit, only where a reader of the settled list assumes one entry | **new reader since pull request 561 merged**; the same sweep | the keri stub lane |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/CommandRunSpec.hs` | 3b | edit, only where a reader of the settled list assumes one entry | the same sweep | #485 |
| `tools/cli_recovery_controls.sh` | 3c | edit | a new part for an interrupted two-request fold, added to the known parts | #543 adds a recovery evidence check beside it; #477 |
| `flake.nix` | 3c | edit | the hosted recovery partition list gains the partition of the new part | **#543** (its flake edit) |
| `docs/singular-node.md`, its speech companion | 3a, 3b | edit | 3a: the sentence that gives the reason for the bound; 3b: the bound, the whole behaviour, the limits | none |
| `docs/demo1-preprod.md`, `docs/offchain-fold-responsibilities.md`, `onchain-release/DEMO1.md`, `docs/cli-recovery.md`, their speech companions | 3c | edit | they state the bound of one and the first request that passes; the recovery page states recovery of many | #471 edits the responsibilities page |
| `docs/audio/index.json`, `docs/audio/manifest.json`, the clips of the changed pages | 3a, 3b | edit, create | regenerated by the tool after the last rebase, never merged by hand | any lane that edits a page |
| `specs/518-fold-every-settleable/*` | 3a | edit | this record | none |

Not touched: `offchain/lib/Singular/Registry/TxBuilder/Update.hs` and `Update/Context.hs` (the builder already folds a chosen set; the first run shows it with rows, and edits it only if a row fails), `offchain/lib/Singular/Registry/TrieState*` (the walk per prefix needs no new function), any workflow file (the new recovery part is hosted by the partition list in the flake, which the existing discovery and partition-check jobs read), `lean`, `onchain`, `naming-onchain`, `simulator/formal`.

Checked by reading, 2026-10-13: the only readers of the scalar journal fields are `Reconcile.hs`, `Session.hs`, `tools/cli_recovery_controls.sh` (the prepared line's key, edge and roots, and tampered copies of them) and `tools/demo1_cli_journey.sh` (tampered copies of the roots and the edge); the scalars keep their meaning for a fold of one and describe the fold as a whole for a fold of several, so none of these readers changes in 3a. The readers of the six single-request fields of the fold result (`fdRequest`, `fdKey`, `fdEdge`, `fdDelivery`, `fdDeadline`, `fdOwnerHex`) are `Fold.hs`, `Entry.hs` (open datum), `Convict.hs` and `Register.hs` (keri stub). The first sweep was a search cut at twenty lines and missed `Register.hs`; the complete sweep by those six fields over every Haskell file, at `8a1a0527` and at main `af16bad4`, lists exactly these four (confirmed independently by the desk, A-021). Other modules import `Singular.CLI.Fold` without reading the six fields (the two `Run.hs`, `FoldSpec.hs`, `WriteSpec.hs`, `Singular/CLI.hs`, `Reclaim.hs`, `Reject.hs`); a mechanical compile-driven adaptation of one of them is permitted by A-021 and journaled as a note line.

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
