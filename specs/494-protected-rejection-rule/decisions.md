# Protected rejection: the rulings and what they decide

This page records every operator ruling that governs ticket 494, in the operator's
words, and the model readings that follow from them. It carries forward, unchanged in
meaning, the rulings and the historical counterexample recorded for the earlier model
candidate (pull request 508). Nothing here re-asks a ruling.

## The requester story and the behavior it reproduces

As a requester with an approved insertion for an unknown key, I want a permissionless
processor unable to cancel it and collect its tip without an allowed rejection
condition, so that paying for processing does not enable arbitrary cancellation.

The earlier candidate reproduced the defect at model revision
`6efe1f119a2332484e690b4c128c4bc5fd4d689b` with an empty registry and an approved
insertion of key 5 for owner 42, destination 99, deposit 2,000,000 and tip 1,000,000.
The insertion folds to Active. The same request can instead be rejected with no signers,
unchanged registry state, no mint and a deposit-only refund to the owner, while the
modelled inputs exceed the modelled outputs by the tip.

The tree this ticket starts from (the two-edge model, byte-identical in `lean/Singular/Model.lean`
at `e3c9ab01` and at `e7b55ac9`) has the same defect:
its `exitAdmission` answers no refusal for `Exit.reject`, so the same scenario is
accepted. The scenario is therefore the failing control of the first coding slice that
changes rejection, and it is kept as historical behavior: it is run against the base
model before the change (it must report the rejection accepted) and against the changed
model after it (it must report the rejection refused). It is model evidence only; it
is not a ledger attack and does not prove any validator behavior.

## Ruling: a lifecycle mismatch permits immediate rejection

The operator answered "reject" to the story of Alice active on a key and Bob requesting
an insertion for it, a request that deletion could later make possible, with the
processor taking the tip. The ruling, verbatim:

> Authenticated incompatibility with the current lifecycle state permits immediate
> rejection even when a later transition could make the request eligible.

Refund amounts are unchanged by it, and it does not resolve ticket 361 (the unresolved
owner-sum versus positional refund discrepancy). It does not select the state used in a
mixed batch (see the third ruling), an expiry boundary (see the second), or any further
reason.

## Ruling: expiry follows both windows

The operator answered "yes" to expiry-only rejection after both the processing and the
owner's reclaim windows end, so that the owner keeps the opportunity to reclaim the
deposit and tip. The ruling, verbatim:

> expiry-only rejection after both the processing and owner's reclaim windows end ...
> The expiry threshold is therefore submission time plus processing duration plus
> reclaim duration.

With submission 10000, processing duration 1000 and reclaim duration 500 the threshold is
11500. An expiry-only rejection must not execute before it: its whole validity interval
lies at or after the threshold. This does not delay the separately authorized mismatch
rejection of the first ruling, and refund amounts remain unchanged.

## Ruling: a batch is judged on the state its earlier actions left

On 8 October 2026 the operator answered "yes, the batching work should be closed on its
effects" for two insertions of the same initially unknown key: fold the first, then
reject the second against the updated state. The ruling, verbatim:

> Each action is judged against the state left by preceding actions in the same ordered
> batch. Rejection evidence binds that intermediate registry state/root.

An earlier successful action may create the lifecycle mismatch that authorizes a later
rejection. A rejection preserves the intermediate state it saw, so later actions see
every earlier successful transition. This is a required mixed-batch property of the
model, not a claim that a batch builder or a batch acceptance exists.

## Scope confirmation

The operator required proof of rejectability, assigned malformed-deposit and address
pollution research to ticket 500, and directed the model work to proceed. Exactly two
grounds authorize rejection: a lifecycle mismatch and expiry. No other reason is
authorized. A provider failure, a missing processor-supplied input, an invalid proof and
a generic script failure are never evidence that a request is inadmissible.

## Readings that follow from the two-edge model

The base model admits only registration (`insertActive`) and permanent termination
(`updateTerminal`); five older edge tags remain in wire order solely to represent
refused actions. Three readings follow and are recorded here so the coding slices do not
choose them silently.

| Reading | What the model states | Status |
|---|---|---|
| Mismatch is the model's own transition table | A request is lifecycle-compatible exactly when `Singular.transition` gives a successor for its edge at the key's leaf. Registration is compatible only at an unknown key; termination only at an Active key. Unknown and the stored Absent state are different leaves. | Follows from the first ruling and the base model. |
| A request naming an excluded edge is incompatible at every leaf | `transition` is empty for the five excluded tags, so a mismatch rejection of such a request is admitted for any leaf. The request can never fold, so waiting for expiry protects nobody. | Ruled by the epic owner on 9 October 2026 as an application of the first ruling, not a new operator decision: such a request is incompatible with every current state and is rejectable at once with the lifecycle evidence. |
| Refusals other than the lifecycle are not grounds | A request with a wrong approval, a short deposit or a missing token is refused by a fold but is not thereby rejectable early; only mismatch and expiry are. | Follows from the scope confirmation. |

## Decision: what the public suite shows until the validators change

Once the model refuses an in-window rejection of a foldable request, the required check
named "early rejection inside the windows" cannot agree between model and chain, because
the validators (ticket 495) still accept it. The operator ruled on 9 October 2026 for the option
that merges this ticket alone, ahead of ticket 495 (option B).

| Row | Model | Chain | Published as |
|---|---|---|---|
| Rejection at once, with lifecycle evidence, of a request that cannot be folded | accepts | accepts, owner refunded | agreement (green) |
| Rejection, inside the windows, of a foldable `insertActive` request for a key not yet registered | refuses | accepts | unmet by ruling, never counted as passing |

A tripwire turns red unless ticket 495 changes the validators so that the second row agrees, and
ticket 495's acceptance includes that flip. The row books a foldable insertion because the insertion
the standing row books today names an edge the two-edge model excludes, which is rejectable at once
and would leave the row without its subject.

## Ruling: the economic design

On 13 October 2026 the operator adopted a bond, a booking-root forfeit, a split between the proving processor and the treasury, the tip paying
the processor on every rejection, the return of the bond on expiry and a termination fee, and ordered the model and a paper before anything
else. After the review of the paper's first draft the operator ruled every point again, and that design was withdrawn: no bond, no split, no booking root and no
termination fee; a registration cost donated to the treasury on a successful registration; rejection by reference read, batchable, never spending the state output;
terminations that carry the token and the application tag and can be neither rejected, retracted nor expired; a pinned minimum tip; the booked time the upper end of a bounded
booking interval; every parameter fixed at creation. The [design](economics-design.md) is the decided text; the [plan](economics-plan.md) rebuilds the model on it, and
the paper is written after the model, on 14 October 2026 by the operator's order.

## What is carried forward unchanged from the earlier candidate

The earlier candidate was reviewed twice by an independent model and its design is the
reference the first coding slice ports onto the two-edge model: evidence is an
authenticated logical read, not Merkle proof bytes; rejection and retraction both read the
request's booked submission time; evidence binds the registry's abstract identity, the
complete configuration including the intermediate root, and the complete request; an
empty batch is refused; all-reject batches share the mixed-batch engine. The data model
page names each of these; any difference from the earlier candidate is listed there.
