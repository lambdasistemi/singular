# Fold every pending request: plan

Read the [spec](spec.md) for the stories and requirements. Base: main `9011ca17`.

## Strategy

The library's fold already speculates every pending request; it gains an explicit
selection, and the bound follows the selection. The command chooses that selection
purely, from the pending requests, the clock and the law, and carries a list through the
receipt, the journal and reconciliation. The model gains the fold's phase-1 admission so
the selection's deadline rule has a counterpart. The two-actor journey of #381 closes the
story once its harness, the join (#437) and public insertion inputs (#419) are on main.

Main is integrated by merge commit. #419 rewrites the envelope read in `Fold.hs`; this
ticket keeps that read behind one per-request function so the merge touches one call
site.

## Slices

| Slice | Delivers | Waits on |
|---|---|---|
| fold many | selection, subset fold, bound, receipt, journal, reconciliation, rollback, race refusal, docs, devnet evidence on one directory | nothing |
| model | fold admission in Lean, statements, corpus, consumers, constitution 1.13.0 | the operator's ruling on the amendment |
| two actors | the #381 journey books twice and folds once, separate `HOME`s | #433, #437, #419 merged; separate PR |

The first two ship in one PR; the third closes #396.

## Module rows

| Module | Responsibility after this ticket |
|---|---|
| `offchain/cli/src/Singular/CLI/FoldRules.hs` | Pure selection: which pending requests a fold takes, in input order, and why each other one is left; `foldTarget` and `SeveralPending` are gone. |
| `offchain/cli/src/Singular/CLI/Fold.hs` | Folds the selection: per-request inputs (envelope or holding) through one function each, one speculative walk over the batch, post-build checks over the batch, delivery checked per key, the receipt's lists. |
| `offchain/lib/Singular/Registry/TxBuilder/Update.hs`, `Update/Context.hs` | Build a fold over a given non-empty set of pending request outputs; the upper bound is the earliest deadline of that set. Folding every pending request stays available as the set of all. |
| `offchain/cli/src/Singular/CLI/Receipt.hs`, `Session.hs` | The journal line and the expectation carry a list of transitions; earlier lines read as a list of one. |
| `offchain/cli/src/Singular/CLI/Reconcile.hs` | Observes every included key; rollback reports every included request and restores the transaction's root before. |
| `offchain/cli/src/Singular/CLI/Entry.hs` | `insert --fold` and `terminate --fold` fold the same selection and report the same receipt. |
| `tools/demo1_cli_journey.sh`, `tools/cli_recovery_controls.sh`, `conformance/lib/Conformance/Cli/Controls.hs` | Read the list receipt; the journey books twice and folds once; the recovery controls interrupt a two-request fold. |
| `docs/singular-node.md`, `docs/cli-recovery.md`, `onchain-release/DEMO1.md` | State the batch fold; the one-pending rule is gone. Speech re-stamped. |
| `lean/Singular/Model.lean`, `Statements.lean`, `Driver.lean`, corpora, simulator mirror, conformance pins, `.specify/memory/constitution.md` | Model slice, after the ruling. |

## Data rows

- **Pending request.** Output reference, then either the decoded request with its deadline
  (`submittedAt + processTime`) or the decoding failure.
- **Exclusion.** `window-closed` (deadline at or before now plus the fold margin),
  `edge-unsupported`, `undecodable`, `refused-by-law` with the model's reason.
- **Selection.** Included requests in input order, non-empty for a fold; excluded requests
  with their exclusion. Every pending request is in exactly one of the two.
- **Fold transition.** Request output reference, key, edge, expected leaf, root before,
  root after. A batch's transitions chain: the first root before is the state's root, each
  root after is the next root before, the last root after is the new state's root.
- **Journal line.** The existing transaction fields plus the batch's transitions. A line
  with the earlier scalar key, edge and root fields is the batch of that one transition.
- **Fold receipt.** `folded`: per request, output reference, key, edge, owner, settlement
  (live output and envelope, or released holding and deposit), deadline. `excluded`: per
  request, output reference and exclusion. Then the transaction's root pair, validity
  bound and post-build decision.

## Function rows

| Name | Arguments | Result |
|---|---|---|
| `FoldRules.selectFold` | `nowMs :: Integer`, `marginMs :: Integer`, `lawAdmits :: [(Key, Edge)] -> Either Text ()`, `pending :: [(TxIn, PendingRequest)]` | `FoldSelection` |
| `FoldRules.renderExclusion` | `exclusion :: Exclusion` | `Text` |
| `Update.updateTokenSelected` | `cfg`, `view`, `snap`, `tid`, `addr`, `ctx`, `selected :: NonEmpty TxIn` | `IO ConwayTx` |
| `Reconcile.observe` | unchanged arguments | one verdict per included transition |

`lawAdmits` answers whether the model accepts the batch prefix; the command backs it with
the trie walk of the replayed tree.

## Model slice rows (after the ruling)

- `Request.submittedAt`: the submission time of the request itself, as its chain datum records.
- `FoldWitness`: only the transaction's finite validity upper bound, excluded. Admission
  reads every included request's own submission time; no separate time list can omit one.
- `foldAdmission`: `not-phase1` when the upper bound passes any request's
  `submittedAt + processTime`; admission precedes `foldBatch`'s refusals.
- Statements: `fold_batch_refuses_past_deadline`, `fold_admitted_in_window_is_fold_batch`,
  `fold_admission_boundary` (upper bound equal to the deadline admitted, one past
  refused).

## Limits carried

- No live conformance row compares a batch with `Singular.foldBatch`; the constitution's
  named limit stands and moves to a follow-up ticket.
- One directory carries the devnet evidence of slice one; separate directories are slice
  two.
