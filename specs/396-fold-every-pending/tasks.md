# Fold every pending request: tasks

Read the [plan](plan.md) for the module rows. Each slice is pushed when its gate is green.

## Slice: fold many

As Alice and Bob, booking together, I want one fold to settle both of us.

- [ ] fold-many-red: selection, receipt, journal and reconciliation properties stated over
  two and more requests, committed failing.
- [ ] select-every-foldable-request: the pure selection, its exclusions and their words;
  `foldTarget` and `SeveralPending` removed.
- [ ] fold-the-selection: the library builds over the selection with the earliest
  included deadline as bound; the command spends exactly the selection; `--request`
  refused unless included.
- [ ] list-receipt: one receipt shape listing folded and excluded requests, for
  `registry fold`, `insert --fold` and `terminate --fold`, and every reader of it.
- [ ] journal-many-transitions: the journal line carries the batch's chained
  transitions; earlier lines read as a batch of one.
- [ ] reconcile-every-included-request: observation and rollback over every included
  transition; a lost race refused `stale-state` and closed.
- [ ] devnet-fold-many: the Demo 1 journey books for two owners and folds once; an expired
  request is left and named; the recovery controls interrupt a two-request fold.
- [ ] docs-fold-many: the three pages state the batch fold, speech re-stamped.

## Slice: model

As a maintainer, I want the model to refuse a fold that includes a request past its
deadline, as the chain does.

- [ ] fold-admission-red: the three statements committed failing.
- [ ] fold-admission: `FoldWitness` and `foldAdmission` in the model; statements proved.
- [ ] fold-admission-consumers: driver corpus, theorem manifest and debt, simulator
  mirror, conformance pins, `tools/check_model.py`, constitution 1.13.0.

## Slice: two actors

As Alice and Bob in separate terminals, starting empty, I want to book together and see
one fold settle us both.

- [ ] two-actor-fold-many: the #381 journey books from both actors concurrently and folds
  once; each payout bound to its owner.
