# Starvation / takeover assessment — owner-level model mapping

**Requester story under assessment:** *As a requester, I want another willing processor to complete
my request even when one SPO keeps skipping it.*

**Status: mapping CORRECTED 2026-09-12T18:19Z and NOT complete. Execution scheduled, not yet run.**

> **An earlier version of this document concluded "only stale transactions and proofs" without
> qualification and called the mapping complete. Both are withdrawn.** M1's subject includes the
> **bound consumer**, not only Singular's naming abstraction, and the consumer — together with the
> current on-chain validators — carries **time**. See §"Time is part of the contract" below. The
> error was deriving from one layer and generalising across the boundary. Everything below is derived
from the accepted Lean; nothing here is execution evidence and none of it reduces debt.

Sources: accepted Singular Lean `13231f58833b8feb57f4b0f9b1117bfcfba0c07d`, tree `dd9e508b…`.
Bound consumer `14a64a4681d3e429fab5877062b5c476c2a4bfe2` — `Registry.stepFn` fold requires
`batch != []`, `R8_empty_fold_refused`.

## The question, answered at model level

> Do repeated adversary batches invalidate **only stale transactions and proofs**, or do they also
> **prevent the victim being processed from current state**?

**Within Singular's own abstraction, and only there: only stale transactions and proofs; the
request survives.** Two facts settle that narrow claim — **and it does not carry to M1**, because
the bound consumer and the concrete validators add time. Read this section with the next one.

**1. A request has no expiry.** `Model.lean:64-72` — `Request` carries `id`, `operation`,
`proposal`, `token`, `held`, `destination`, `authenticatedOrigin`. **No deadline, no TTL, no
timestamp.** Nothing in the model causes a request to lapse through the passage of time or through
other folds.

**2. Folding consumes only what it folds.** `Model.lean:143-144` —
`consume s id = { s with requests := s.requests.filter (·.id != id), applications := … }`. An
adversary batch of its own requests removes **exactly those ids**. The victim's request remains in
`s.requests`, unchanged.

**Cross-key isolation holds too.** `setEntry` (`:145-146`) rewrites only the entry for its own key:
`e :: s.entries.filter (·.key != e.key)`. So an adversary folding *other* keys leaves the victim's
entry — and therefore the `foldOne` insert preconditions
`(entry s r.proposal.key).value = none` and
`r.proposal.scope.contains (entry s r.proposal.key).incarnation`
(`Statements.lean:86-87`) — untouched.

**What does go stale:** a transaction already built against a superseded root. That is the modelled
behaviour, executed and confirmed: **CG10, stale fold against a superseded root → REFUSED.** The
remedy is mechanical — rebuild the proof against current state. The *request* did not become
unprocessable; a particular *transaction* did.

## Time IS part of the contract — the correction

Singular's `Model.Request` has no time fields. **The bound consumer and the current validators do**,
and M1's subject includes them.

**Consumer** (`Registry.lean`, bound `14a64a46`):

- `:168-175` — `Request` carries **`submittedAt : Slot`**
- `:255-260` — `inPhase1` is `now < submittedAt + p.process`; `inPhase2` spans
  `submittedAt + process <= now < submittedAt + process + retract`; `rejectable` includes the later
  boundary
- `:341-349` — `processOne` checks `inPhase1`; **`rejectOne` checks `rejectable` AND `userPostable`**
- `:389-399` — `retract` checks `inPhase2` and returns **bond+tip**

**Current on-chain** (`fe89e68`): `request.ak:50` destructures `submitted_at`; `:58-60` checks
`in_phase1` / `is_rejectable`; `validateRetract` and `state.ak mkAction` phase-check likewise
(`UpdateAction` versus `Rejected`).

**Therefore: a request may survive in the inbox and still become ineligible for ordinary processing
because time passes — even with disjoint attacker keys.** Survival of the UTxO is not
processability.

Four things that are **not** the same and must not be collapsed:

| state | condition |
|---|---|
| **pending UTxO retention** | the request still exists |
| **processability** | `inPhase1` still holds |
| **phase-2 retraction** | `inPhase2`, returns bond+tip |
| **later rejectability** | `rejectable` **and** `userPostable` |

**No expiry semantics is invented here** — all of it is read from the existing consumer and the
actual boundary. And **no promise that every operation kind shares an exit**: `userPostable`
matters, and **Insert-only retraction versus completion-only retirement custody remains a separate
binding to resolve faithfully.**

## What this does NOT establish — the stakeholder's point stands

**Validator admission is not block inclusion.** Everything above says the victim's request remains
*admissible* when a willing processor includes it. **Nothing in a validator can compel an SPO to
include a transaction in a block.** A finite successful takeover does not prove eventual inclusion,
and no clause in the accepted model addresses block production.

So the answer to the requester story is **conditional, and the condition is outside Singular**:
*another willing processor can complete the request from current state* — **provided some producer
willing to include it gets to make a block.** That is a property of the chain's producer set, not
of this registry.

**The empty-batch repair does not change this**, exactly as the stakeholder said: a hostile producer
submits a nonempty batch of its own requests and omits the victim. **Not queue fairness, not
censorship resistance, not guaranteed inclusion.**

## Expiry and recovery — CORRECTED

An earlier version said the "if it expires" branch has no model antecedent. **Wrong**: it has one in
the consumer and in the concrete validators, above. What Singular's *abstraction* omits, the bound
contract supplies.

The exits are **phase-dependent**, not uniform: `inPhase2` retraction returning **bond+tip**, and
rejection guarded by **`rejectable` AND `userPostable`**. `withdraw_iff` (`Statements.lean:57-64`,
refund to `r.proposal.refundAddress`, exact and per request) is one exit, not the only one.

Still not invented here, and still the rule: derive from the existing consumer and the actual
boundary, never author the semantics.

## Assumptions stated

- **Timing:** no modelled time. Request survival is independent of elapsed time and of other folds.
- **Inclusion:** assumed adversarial for the SPO under test and **not assumed** for the wider
  producer set — the willing-processor premise is an input to the story, not a guarantee derived
  from it.
- **Key disjointness:** the adversary folds keys disjoint from the victim's. Overlapping keys are a
  **separate case** — an adversary folding the victim's *own* key could change that entry's
  incarnation, and whether the victim's `scope` still contains it is then the question. **Not
  assessed here; named as the next case.**

## Execution — scheduled, bounded, no fifth slot

To run **within existing workers at a safe boundary**, not displacing compiled/refinement work.
**Every leg carries its timing assumption explicitly.**

1. Victim request admitted; adversary folds **N** nonempty batches of its own requests on **disjoint
   keys**.
2. Victim's transaction built against the **pre-adversary** root → expect **REFUSED**, attributed as
   stale-root (the CG10 shape). Attribution, not a bare non-zero.
3. Victim's transaction **rebuilt against current state** by a **different** processor, **while
   still `inPhase1`** → expect **ACCEPTED**, refund and tip following the contract. This is the
   willingness-and-inclusion-while-processable leg.
4. **Past the process-window end**: the same victim once `inPhase1` no longer holds → expect the
   **prescribed refusal or exit**, attributed. Record which of the four states applies — retention,
   processability, phase-2 retraction (`inPhase2`, bond+tip), later rejectability (`rejectable` AND
   `userPostable`).
5. **Boundary controls** at each phase edge — `submittedAt + process` and
   `submittedAt + process + retract`. The edges are where an off-by-one lives, and a trace that only
   samples the middle of each window would not find one.
6. **Overlapping-key variant**, distinct case: adversary folds the victim's **own** key, changing
   that entry's incarnation; whether the victim's `scope` still contains it is the open question.

**Carry into any result:** the **no-guaranteed-inclusion** limitation, and the actual timing
assumptions. A green trace shows admissibility when included; it never shows an SPO can be compelled
to produce a block.

Until these execute, this document is a **mapping, not evidence**.
