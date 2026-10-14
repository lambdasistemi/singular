# Singular registry economics, as decided

Decided on 13 October 2026, after the review of the first draft of the economics paper; the operator ruled each point of the review. This page is the design the Lean model states and the paper explains. It replaces the earlier design, with its bond, processor split, booking root and termination fee.


## Story

As a requester, I book a registration knowing what it costs:
- If it succeeds, I pay the registration cost to the treasury and the tip to whoever processes it.
- If it fails, I get everything back except the tip.
- If I cancel it in the reclaim window, I get everything back, the tip included.

Nobody can cancel my live request. Nobody can make a termination fail once it is booked.

As a reviewer, I can check every claim against a Lean theorem. Where the paper makes no promise (spam, delay, priority, fee changes), it says so.

## What changed from the first draft

| First draft | As decided |
|---|---|
| Bond carried by every request, forfeited on a fault proved at the booking root, split between the prover and the treasury | No bond, no split, no booking root |
| Termination fee donated to the treasury | No termination fee. A successful registration pays a registration cost R to the treasury instead |
| Rejection spends the registry state output | Rejection reads the state output by reference and never spends it. Rejections are batchable. Only folds spend the state output |
| A termination can be rejected, can expire, and has an owner | A termination carries the key's token and the application's approval. It has no refund address, cannot expire, cannot be retracted, and cannot be rejected |
| Booked time written by the booker, unchecked | Booked time is the upper end of the booking transaction's validity interval, which may be at most δ wide |
| Parameters "never changed by a fold" | Every parameter is fixed at creation. A Singular registry has no authority that could change one |
| Tip chosen per request, with no floor | A registry-pinned minimum tip is checked at booking, and the requester may offer more |

Terminology (operator): Singular has no controller concept. The application is the controller. It authorizes every operation through its approval and governs the token at the destination it names. A registration request carries a **refund address**, its owner field.

## Registry parameters (all fixed at creation; no authority can change them)

| Parameter | Meaning |
|---|---|
| R, registration cost | Lovelace donated to the treasury for each successfully registered key. Never refunded once the key is registered. |
| t_min, minimum tip | Checked at booking. Sized from measured costs: fee per byte, script execution, the reference read of the state, and the restitution output. |
| δ, maximum booking width | Upper bound on the width of a registration's booking validity interval; δ < W_p. |
| W_p, processing window | A registration may be folded only in [s, s + W_p). |
| W_r, reclaim window | The refund address may retract only in [s + W_p, s + W_p + W_r). |
| Application approval policy, token policies, registry identity | As today. |

The paper states the envelope each parameter was sized for: ledger fee parameters, inclusion delay and output minimums at creation. Outside it, a pending request may wait without bound, and new bookings may offer more than t_min. The answer to a changed ledger is a new registry, and nothing migrates to it.

## The two requests

The request policy, the minting policy that tags a booked request, refuses any request whose contents are not exactly the following ("dirty requests").

| | Registration | Termination |
|---|---|---|
| Holds exactly | R, tip ≥ t_min, the ada its token output needs (carrier ada), the application approval | the key's active token, the application approval, tip ≥ t_min, the ada its output needs |
| Approval bound to | (register, key, refund address, destination) | (terminate, key, destination) |
| Refund address | yes | none |
| Booked time | s = U, the upper end of the booking interval [L, U), U − L ≤ δ | none |
| Exits | fold, retraction, rejection | fold only |

How a termination is booked: the key's token lives at the destination its registration named, under the application's custody. The application's rule releases it into a termination request:
- cardano-keri releases it on a verified duplicity proof, which anyone may post;
- open-datum releases it on its envelope's control signature.

Singular checks the application's approval, not the application's rule. Everything the fold checks for a termination is fixed at booking. The application's approval policy must allow burning its approval at any time with no further condition. Otherwise a booked termination, which has no other exit, could be stranded.

## Every exit

A registration's windows, measured from its booked time s:

| From | To | Fold | Retraction (signed by the refund address) | Rejection |
|---|---|---|---|---|
| s | s + W_p | yes | no | only on a current mismatch |
| s + W_p | s + W_p + W_r | no | yes | only on a current mismatch |
| s + W_p + W_r | forever | no | no | by anyone, on expiry or mismatch |

Where the value goes:

| Exit | Treasury | Processor | Refund address | Destination |
|---|---|---|---|---|
| Registration folded | R | tip | approval (open item: returned or burned) | the active token with its carrier ada |
| Registration rejected | nothing | tip | R, carrier ada, approval | nothing |
| Registration retracted | nothing | nothing | everything, tip included | nothing |
| Termination folded (active token and approval burned) | everything except the tip | tip | none | none |

A fold of n registrations and m terminations donates at least n·R plus the sum, over the m terminations, of (held − tip).

## The rejection rule

- A rejection reads the registry state output as a reference input. It checks that the referenced output carries this registry's exact state token (policy and name) and reads the root from that output's datum.
- It spends only the requests it rejects. It spends no state token, and this is checked.
- Rejection is removed from the fold's action list entirely. Only folds spend the state output.
- Rejections batch: one transaction may reject many requests against one referenced state output, with one shared validity interval.
  - Each request is consumed and refunded once.
  - Refunds are summed per refund address.
  - Evidence is checked for every member.
- A fold that lands first invalidates the rejections in flight. They are rebuilt; this starvation is accepted. A rejection that loses the race is invalid and pays no fee.
- Grounds:
  - a current lifecycle mismatch, against the referenced state;
  - expiry, at or after s + W_p + W_r.

  A live registration that can still be folded is never rejected. A termination is never rejected.

## What the paper may state

Each statement becomes a result only once its definitions and proofs exist in Lean. Until then the paper marks it as pending.

1. Every fold preserves every registry parameter. Today's preservation (`onlyRootChanged` in Model.lean), extended to R, t_min and δ.
2. No accepted rejection or rejection batch spends the registry state output or changes the registry (map, token supply). This must hold for every accepted transaction, not just for what the builder produces.
3. A rejection ordered before a fold cannot invalidate that fold through the state output. Whole-fold validity also needs disjoint other inputs.
4. A registration that can still be folded is not rejected before expiry. This is today's `live_compatible_request_protected` (Statements.lean), lifted to the reference-read rejection. With the booked-time rule, expiry comes no earlier than W_p + W_r after the booking's actual inclusion.
5. No rejection without current-state evidence: today's `rejection_without_evidence`.
6. Refund floor:
   - on rejection, each refund address receives at least the sum, over its distinct rejected requests, of (held − tip), approvals included;
   - on retraction, it receives everything the request held.
7. Registration charge: every accepted fold that registers n keys donates at least n·R. R is returned on rejection and retraction, and never after a successful registration.
8. Terminations are unrejectable: in every reachable state, no rejection of a termination request carrying its key's genuine token is admitted, on either ground.
   - The mismatch half follows from `biconditional_supply_sync` (Statements.lean) once the token held in a pending request is counted in supply.
   - The expiry half holds by definition, since a termination has no expiry.
9. At most one termination per key is pending. This follows from token uniqueness across custody and pending requests (`active_witness_unique`, Statements.lean, extended).
10. Only terminations carrying the application's approval fold.
11. A booked termination can be folded at any later time. This holds as long as some folder accepts its tip and ledger fees stay inside the envelope the tip was sized for.
12. Across a batch, what the processors can take is at most the sum of the tips. This needs a balance relation with no outside funding.
13. t_min covers the measured cost of every supported exit processed alone, restitution output included, within the stated fee envelope. This is conditional on the measurements.

## What the paper must not claim

- A flood price, or any spam deterrence beyond the spent R. Valid folds of junk keys still take turns on the state output; R mitigates this and does not prevent it.
- That nothing delays a fold, that malicious folds are excluded, or that any request is included, prioritized or served within a bound.
- An exact or always-positive processor wage. An optimal value of R, t_min or δ.
- That the parameters stay sufficient after the ledger's fee parameters or output minimums change.
- Key ownership, squatting protection, or any cardano-keri guarantee as a property of Singular. Those belong to the application.
- That the deployed validators implement any of this, without conformance evidence.

## Lean additions, in dependency order

1. **Transaction vocabulary.**
   - Output references and their presence in the current UTxO set, so that "a reference to a spent output is refused" can be stated.
   - Reference inputs alongside spending inputs.
   - The exact state token identity (policy and name).
   - Actual input and output values, with native assets.
   - The donation field (a zero amount omits it), the ledger fee, and a balance relation scoped to these transactions.
2. **Parameters** R, t_min and δ, with preservation.
3. **Request types.**
   - A registration carries the refund address, the destination, s, R, the tip and the carrier ada.
   - A termination carries the active token, the tip and the carrier ada, with no refund address and no time.
   - Both carry the approval and the request-policy tag, with its provenance.
   - The exact-contents predicate, with the declared tip separated from the held value.
4. **Booking transitions.**
   - Registration booking: the validity interval no wider than δ, and s = U.
   - Termination booking: the token moves from application custody into the request.
   - The supply invariant spans custody and pending requests until the burn.
5. **Rejection.**
   - The reference-read rejection batch: state-token check, no state spend, distinct inputs, one interval, per-member admission.
   - Refunds of held − tip, summed per refund address.
   - The rejection arm is removed from the fold.
   - Terminations are excluded by construction (no expiry) and by theorem (mismatch is impossible).
6. **Fold.**
   - The processing window for registrations and no window for terminations; today's on-chain gate applies to both, and the termination must lose it.
   - Routing of R, the tip and the carrier.
   - Termination burns the active token and the approval and donates held − tip.
   - The donation is at least n·R plus the terminations' donations.
7. **Theorems 1–13, with negative controls:**
   - the old state-spending rejection path;
   - a fake, foreign or stale referenced state;
   - an overlapping state spend;
   - a live member inside a rejection batch;
   - a repeated input or a reused refund;
   - a dirty request, or hidden surplus;
   - a forged tag, token or approval;
   - a backdated booking or one wider than δ;
   - a termination stranded by a check made at fold time;
   - one donation counted for many keys.
8. **Correspondence**, to be done separately:
   - validators and conformance rows;
   - measured fees, output minimums and batch capacity.

## Open items (not decided)

1. Registration approval on a successful fold: returned to the refund address, as today, or burned like the termination's. If returned, its output is a restitution cost that t_min must cover.
2. Adapting open-datum (`applications/open-datum`). Today it releases the token inside the terminating fold and pays the deposit to its control signer. The decision moves the release to booking, and the deposit payment must be reconciled with the treasury donation. Its approval policy already allows pure burns.
3. Adapting cardano-keri. Its model reaps the token, then refunds a go-request to the reaper and pays the convictor a reward. That differs from the decided termination, so a correspondence design is needed.
4. Values: R, t_min, δ and the carrier minimum, measured on the target network and chosen per registry.
5. The relation between the existing fee pin (`maxFee`) and the minimum tip t_min: both are pinned and checked, and no statement assumes how they relate. It is settled when the validators are made to agree with the model.
