# Data: what a rejection reads and writes

## Unchanged data

The request datum (`Request`, `onchain/validators/types.ak`), the state datum (`State`), the redeemers (`UpdateRedeemer`, `RequestAction`), the receipt format and the consumer's rows keep their shape. No field is added, removed or reordered. The repair changes which values are admitted, not how they are encoded.

## D-01 A reject's admission

A `Rejected` action paired with a request input is admitted by the state purpose for every validity range. The refusals that remain apply before and after the action, unchanged: `tip-coverage`, `deposit-mismatch`, `missing-action`, then the payment rules (`ReturnDeposit` floor `held − tip` to the request owner, positionally and by payee), and the modify judgement (`empty-fold`, `surplus-actions`, state continuation).

## D-02 The request's matching action

A request input spent by `Contribute` is folded by the state's `Modify` in transaction input order. A request is folded when it carries an inline request datum for this registry's token. Its matching action is the action that fold pairs with it. The request purpose admits the spend when:

- the validity range lies entirely in the processing window (as today), or
- the matching action is `Rejected` (new, any window).

It refuses otherwise. In particular it refuses a spend outside the processing window whose matching action is an update, and one with no matching action. Nothing the state does not fold is admitted outside the processing window. The admitted set therefore does not grow beyond the rejections Lean admits.

## D-03 Windows

Window boundaries are unchanged: processing `[submitted_at, submitted_at + process_time)`, retraction `[submitted_at + process_time, submitted_at + process_time + retract_time)`, after both from the retraction deadline on. The repair keeps the processing-window predicate (updates) and the retraction-window predicate (retractions). It removes the after-both-or-future-dated predicate.

## D-04 Reject placement in the story language

A reject in the story language carries one of three placements:

| Placement | Book reading | Realized as |
|---|---|---|
| in the processing window | "while the request can still be folded" | a validity interval inside the processing window |
| in the owner's retraction window | "while its owner can still retract it" | a validity interval inside the retraction window |
| after the windows | "after its owner's retraction window has closed" | a validity interval starting at or after the retraction deadline |

Every reject a story runs carries a placement, tampered or not. The story's validation, which runs before anything is submitted, refuses a story holding an unplaced reject, and the interpreter treats one as a setup failure. The exits stay `Fold | Reject | Retract`, so code outside this change that matches on them is untouched. A placement is a fact about the submitted transaction, not a tamper. The model's answer does not depend on it. The interpreter checks the built interval against the named window before submitting. A mismatch is a setup failure. The control that interpretation and rendering are total quantifies over every placement constructor. Placements add no receipt field. The run log states each placed reject as `placement: <row> reject <placement> validity=[<lo>,<hi>) window=[<from>,<to>) tx=<id>`, where `<placement>` is the first column above, and the transaction id in the receipt locates the same interval on chain.

## D-05 CG09's result

The CG09 receipt keeps its row id and requirement. The chain outcome is now `accepted`. The verdict is the existing `held-q002`: Singular's Lean and the consumer's theorem disagree, and the chain sided with Singular's Lean. The session records CG09 among its held rows. The row's control comes first: the same request's processing-window reject refunding the owner one lovelace short, refused and attributed to the state script, logged as `control: CG09 control: the same reject one lovelace short is refused (tx=<id>)`. Then the untampered reject, built with full-fold execution units (the refusal-sized units would let a budget failure pass for a rule refusal). The after-window acceptance is CG23's and the e2e's.

## D-06 Builder selection

The reject builder selects every request at this registry's request address that carries this registry's token and a request datum. It refuses to build when there is none ("no pending requests"). Its transaction carries a finite validity interval starting at the current tip, bound to no request's deadline. Refund outputs and the state continuation are as today.
