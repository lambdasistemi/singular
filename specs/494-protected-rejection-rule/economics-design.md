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
| A termination can be rejected, can expire, and has an owner | A termination carries the singular tag, and no application tag. It has no refund address, cannot expire, cannot be retracted, and cannot be rejected |
| Booked time written by the booker, unchecked | Booked time is the upper end of the booking transaction's validity interval, which may be at most δ wide |
| Parameters "never changed by a fold" | Every parameter is fixed at creation. A Singular registry has no authority that could change one |
| Tip chosen per request, with no floor | A registry-pinned minimum tip is checked at booking, and the requester may offer more |

Terminology (operator): Singular has no controller concept. The application is the controller. It authorizes a registration through its application tag, governs the singular tag at the destination it names, and consents to a termination by releasing that tag from its custody. A registration request carries a **refund address**, its owner field.

## Registry parameters (all fixed at creation; no authority can change them)

| Parameter | Meaning |
|---|---|
| R, registration cost | Lovelace donated to the treasury for each successfully registered key. Never refunded once the key is registered. |
| t_min, minimum tip | The one pinned number: the floor on the tip a requester declares, checked at booking. The processor takes exactly the declared tip. It lives in the state's existing fee-pin field, which it replaces: the old fee pin is retired and the state keeps its shape (ruled on 15 October 2026). Sized from measured costs: fee per byte, script execution, the reference read of the state, and the refund output. |
| δ, maximum booking width | Upper bound on the width of a registration's booking validity interval; δ < W_p. |
| W_p, processing window | A registration may be folded only in [s, s + W_p). |
| W_r, reclaim window | The refund address may retract only in [s + W_p, s + W_p + W_r). |
| Application tag policy, token policies, registry identity | As today. |

The paper states the envelope each parameter was sized for: ledger fee parameters, inclusion delay and output minimums at creation. Outside it, a pending request may wait without bound, and new bookings may offer more than t_min. The answer to a changed ledger is a new registry, and nothing migrates to it.

## The two requests

The request policy, the minting policy that mints a booked request's trie-ready tag, refuses any request whose contents are not exactly the following ("dirty requests"). The carrier ada is set by the ledger (the minimum for the output holding the token) and declared by the requester; the registry pins no carrier amount (ruled on 14 October 2026).

| | Registration | Termination |
|---|---|---|
| Holds exactly | R, tip ≥ t_min, the ada its token output needs (carrier ada), the application tag | the singular tag, tip ≥ t_min, the ada its output needs |
| Application tag | bound to (register, key, refund address, destination); its asset name is the hash of the payload plus a nonce | none: the application's consent to a termination is the release of the singular tag from its custody |
| Trie-ready tag | minted only with the application tag present; its asset name is the hash of the operation plus a nonce | minted only with the singular tag present; same asset name rule |
| Refund address | yes | none |
| Booked time | s = U, the upper end of the booking interval [L, U), U − L ≤ δ | none |
| Exits | fold, retraction, rejection | fold only |

How a termination is booked: the key's token lives at the destination its registration named, under the application's custody. The application's rule releases it into a termination request:
- cardano-keri releases it on a verified duplicity proof, which anyone may post;
- open-datum releases it on its envelope's control signature.

Singular checks that the application tag is present for a registration, never the application's rule. Singular does not police where else the application tag is minted. Everything the fold checks for a termination is fixed at booking. The tag policies allow a burn at any time with no further condition, for both kinds of request. A rejection by anyone must be able to burn a registration's tags, and a booked termination, which has no other exit, must not be stranded.

## The tags

- The trie-ready tag proves that a request can be judged against the Merkle trie, positively (a fold) or negatively (a rejection). It is minted when a request is booked, only with its precondition present (the application tag for a registration, the singular tag for a termination), and burned when that request is spent, by any exit: fold, retraction or rejection. There is no trie-ready tag without a pending request and no pending request without its trie-ready tag.
- The application tag proves that the payload is authorized to enter. It exists for registrations only. It has the same life as the trie-ready tag of its registration: minted at booking and burned by every exit, never returned to anyone. A termination carries none.
- Asset names: the application tag's is the hash of the payload plus a nonce; the trie-ready tag's is the hash of the operation plus a nonce; the operation contains the payload.
- The singular tag is minted at the destination by a registration fold and burned by the termination fold.
- Tag flow per exit:
  - registration fold: burns the trie-ready tag and the application tag, and mints the singular tag at the destination;
  - registration rejection and retraction: burn the trie-ready tag and the application tag;
  - termination fold: burns the trie-ready tag and the singular tag.
- The supply of the trie-ready tag equals the count of pending requests; the supply of the application tag equals the count of pending registrations.
- Burning is free: the tag policies allow a burn with no condition. This is safe because a tag exists only in a request output at the Singular script hash, and that output can be spent only through the request validator, which enforces the exit and requires the request's tags to be burned in the same transaction, so that no exit carries a live tag out. The exit rules belong to the request validator's spend, not to the burn branch of a tag policy.
- An output at the request address that lacks the trie-ready tag is not a request. Anyone may spend it. A trie-ready tag is minted only with its precondition present, so a genuine request always holds the tags its kind requires, and the sweep reaches only outputs that are not requests. A tagged output leaves only through one of its exits.

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
| Registration folded | R | tip | none | the singular tag with its carrier ada |
| Registration rejected | nothing | tip | R and carrier ada | nothing |
| Registration retracted | nothing | nothing | everything the request held, tip included, except the two tags | nothing |
| Termination folded | everything except the tip | tip | none | none |

Every exit burns the trie-ready tag; the exits of a registration also burn the application tag; the termination fold also burns the singular tag.

A fold of n registrations and m terminations donates at least n·R plus the sum, over the m terminations, of (held − tip).

## The rejection rule

- A rejection reads the registry state output as a reference input. It checks that the referenced output carries this registry's exact state token (policy and name) and reads the root from that output's datum.
- It spends only the requests it rejects, and burns each rejected request's trie-ready tag and application tag. It spends no state token, and this is checked.
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
   - on rejection, each refund address receives at least the sum, over its distinct rejected requests, of (held − tip) in lovelace;
   - on retraction, it receives everything the request held except the two tags, which are burned.
7. Registration charge: every accepted fold that registers n keys donates at least n·R. R is returned on rejection and retraction, and never after a successful registration.
8. Terminations are unrejectable: in every reachable state, no rejection of a termination request carrying its key's genuine token is admitted, on either ground.
   - The mismatch half follows from `biconditional_supply_sync` (Statements.lean) once the token held in a pending request is counted in supply.
   - The expiry half holds by definition, since a termination has no expiry.
9. At most one termination per key is pending. This follows from token uniqueness across custody and pending requests (`active_witness_unique`, Statements.lean, extended).
10. Only a booked termination folds, and a booked termination carries its key's genuine singular tag. (Restated on 15 October 2026: a termination carries no application tag. The application's consent is the release of the singular tag from its custody, which lies outside Singular's scripts.)
11. A booked termination can be folded at any later time. This holds as long as some folder accepts its tip and ledger fees stay inside the envelope the tip was sized for.
12. Across a batch, what the processors can take is at most the sum of the tips. This needs a balance relation with no outside funding.
13. t_min covers the measured cost of every supported exit processed alone, refund output included, within the stated fee envelope. This is conditional on the measurements.

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
   - A termination carries the singular tag, the tip and the carrier ada, with no refund address and no time.
   - Both carry the trie-ready tag, with its provenance; a registration also carries the application tag, and a termination carries none.
   - Asset names: the application tag's is the hash of the payload plus a nonce, the trie-ready tag's the hash of the operation plus a nonce.
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
   - Termination burns the trie-ready tag and the singular tag and donates held − tip.
   - The donation is at least n·R plus the terminations' donations.
7. **Theorems 1–13, with negative controls:**
   - the old state-spending rejection path;
   - a fake, foreign or stale referenced state;
   - an overlapping state spend;
   - a live member inside a rejection batch;
   - a repeated input or a reused refund;
   - a dirty request, or hidden surplus;
   - a forged trie-ready tag, singular tag or application tag, a trie-ready tag minted for another operation or nonce, and a termination that holds an application tag;
   - a backdated booking or one wider than δ;
   - a termination stranded by a check made at fold time;
   - one donation counted for many keys.
8. **Correspondence**, to be done separately:
   - validators and conformance rows;
   - measured fees, output minimums and batch capacity.

## Open items (not decided)

The fate of a registration's application tag on a successful fold is decided: it is burned, never returned, so no restitution output exists and t_min covers none.

1. Adapting open-datum (`applications/open-datum`). Today it releases the token inside the terminating fold and pays the deposit to its control signer. The decision moves the release to booking, and the deposit payment must be reconciled with the treasury donation. Its application tag policy must allow a burn at any time (an application tag exists for registrations only).
2. Adapting cardano-keri. Its model reaps the token, then refunds a go-request to the reaper and pays the convictor a reward. That differs from the decided termination, so a correspondence design is needed.
3. Values: R, t_min and δ, measured on the target network and chosen per registry. The carrier minimum is a ledger figure, not a registry parameter.

Closed by ruling. The relation between the old fee pin and the minimum tip (15 October 2026): the fee pin is retired and the minimum tip replaces it, in the same state field. The source of the carrier amount (14 October 2026): the ledger sets it and the requester declares it; the model makes no claim about the ledger minimum, which the ledger enforces when the output is created.
