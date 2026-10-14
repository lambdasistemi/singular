# A fold admits a request only inside its processing window: the rulings

The operator's rulings of 2026-10-06 on the fold's processing window and on what a batch may consume, recorded with the story they decide, ported from the closed attempt on issue [#396](https://github.com/lambdasistemi/singular/issues/396) (branch `feat/396-fold-every-pending`, file `specs/396-fold-every-pending/ruling.md`, commit `4cb4a441`). Read the [spec](spec.md) for the stories and the [plan](plan.md) for the pull requests. The rulings are quoted as the operator gave them; this ticket implements them and does not reopen them.

## Story

As a registry processor, I fold every pending request whose processing window is still open, and the model tells me that a fold including a request past its deadline is refused `not-phase1`, as the chain refuses it, so the folder's selection is checked against the law and not against the validator alone.

## What was silent

The chain refuses every update whose transaction's validity interval is not entirely before the request's `submitted_at + process_time` (`not-phase1`, in the fold validator `onchain/lib/registry/fold.ak` and again in the request validator `onchain/validators/request.ak`). The model had no fold admission: a fold and a reject were exactly `Singular.exitStep`, and the constitution said so.

## Decision

Option A: the model gains the fold-time admission for every fold, single and batch. A fold including a request past `submittedAt + processTime` is refused `not-phase1`, as the chain refuses it. Inside the window nothing changes. The corpus carries an in-window batch, a batch with one expired request, and the boundary: an upper bound equal to the deadline is admitted, one past it is refused.

The alternative not taken was a narrower amendment, the batch question only, leaving the single fold without an admission; the model would then have said different things for a fold of one and a fold of many.

## A batch cannot consume what it created

The operator's second ruling of 2026-10-06, inside the same amendment.

As a folder, starting with key K unknown and two pending requests in ledger order, an insertion of K and then a termination of K, I fold once: the insertion settles, and the receipt names the termination `refused-by-law token-missing`. The next fold settles the termination from the live holding.

The chain cannot settle both in one transaction: the insertion delivers K's token to an output of the transaction, and the termination must burn it from an input. The model therefore distinguishes, in a batch, what is live from what the batch created, and refuses a request that consumes a holding or a custody entry created earlier in the same batch: `token-missing` for a holding (`insertActive` or `updateActive`, then `updateTerminal` or `deleteActive`), `not-booked` for a custody entry (`insertAbsent`, then `updateActive` or `deleteAbsent`). The names are the model's existing ones. The alternatives not taken were a published divergence between model and chain, and netting both requests, which needs a validator change.

## What changed on main since the rulings

Pull request 523 (the permanent bounded contract) retired five of the seven edges. The model now admits `insertActive` and `updateTerminal` only; every other edge is refused `edge-inadmissible`, and no step creates a custody entry. Consequences for the second ruling, stated here so that no reader has to infer them:

- The holding half applies unchanged: an `insertActive` followed by an `updateTerminal` of the same key in one batch is refused `token-missing`.
- The custody half names edges that no longer exist. A batch containing them is refused `edge-inadmissible` at that request, before any custody reasoning. The ruling's custody wording is therefore carried as a statement about the retired edges, not as model code; the plan asks the epic owner to confirm this reading in one question.

## Rulings carried from the epic

- Batch selection, option A (epic owner, 2026-10-09, for ticket [#518](https://github.com/lambdasistemi/singular/issues/518)): each pending request is judged on its own against the live state; at most one request per key per fold; included requests keep ledger input order; the longest fitting prefix is folded and the rest named. Its fourth condition assigns three residuals to this ticket: the model has no batch transaction, there is no distinct-key commutation theorem, and a same-key insertion then termination in one batch is excluded by #518's selection (`key-in-batch`) and must be enforced in model and validator here.
- Two vocabularies, never mixed (condition one of the same ruling): model refusal reasons are reported verbatim; selection reasons the model does not carry are named as processor policy and never appear as a model refusal.
- The request keeps its datum inline with no size cap; batch capacity is about nine requests on preprod's execution budget, unmeasured (ticket [#530](https://github.com/lambdasistemi/singular/issues/530)); rejection belongs to tickets #498 and #508; the request tag is ticket #529.
