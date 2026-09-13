# The smallest producer hook that makes the delegated consumer path enforceable

Returned to the desk for cross-epic arbitration. Epic 17 owns the product
representation; epic 18 owns the faithful adapter and its witnesses against this
contract. No stakeholder decision is needed — this is a faithful implementation of
the approved contract, not a new feature.

## The gap, stated without inflation

Today `validModify` enforces the root transition and an **aggregate** refund
envelope. **No consumer check is obliged to run at all.** There is no mandatory
authenticated consumer transition in the generic state.

Epic 18's rewritten answer argues that the trivial staking program — `True` on
withdrawal, failing other purposes — makes `runBody` false and therefore selects
`refundAll`. **That is not a source correspondence.** The model carries separate
`AuthMode`, `Plugin` and `ValueMode` parameters, and the bound primary
`registry-as-mpfs.md:200-270` explicitly calls `refundAll` an **idealisation**
rather than current per-user amount enforcement. Making that credential
registrable would still enforce no consumer semantics.

## The refinement already exists in the accepted model

`Registry.stepFn`'s fold arm requires `pl = s.plugin`: **the system state carries
the plugin script, and the fold must name it.** So the concrete contract is a
refinement of `s.plugin`, not an invention.

| element | contract |
|---|---|
| **pinning** | `State` carries the **plugin script hash**, set at bootstrap and preserved by `validModify` — exactly the mechanism already proven for `representative_policy`, including its refusal-on-alteration test |
| **invocation predicate** | every `Modify` that processes **or rejects** at least one request must invoke that script. **Including a nonempty zero-net fold** — that is the case an "only when value moves" predicate would silently skip |
| **unavoidable mechanism** | a withdrawal from the pinned script's credential in `tx.withdrawals`. The script then observes the whole transaction and cannot be bypassed, and the bypass coverage is mechanical: absent withdrawal → `validModify` refuses |
| **what the consumer enforces** | operation-specific routing: processed `register`/`revive` **locking** permitted (the generic validator must not forbid a script-credential destination the consumer requires), `goDormant`/`goConvicted`/`convict` refunds, rejected-request refunds, and the folder tip |
| **authentic source** | the consumer reads the request, the operation and the state from the transaction itself. **No caller-declared obligation total is trusted** — a declaration is authenticated against request/operation semantics or it is not used |
| **immutability** | the pinned hash is preserved across every `Modify`, and altering it refuses, so a fold cannot swap the consumer mid-life |

## What this costs, measured before migration

- `State` gains a **sixth field** → the state hash moves;
- through `naming.ak:202`'s `mpfs_state_hash` constant, the **application** hash
  moves, and through the `application_policy` parameter the **applied
  representative policy** moves with it;
- the SDK codec becomes six-field, a hard break exactly as the fifth field was;
- `retirement_custody` and `staking`'s own program are not on that chain;
- these consequences are to be **reported as built values**, not predicted.

## The exhibit that makes this real rather than prose

One legitimate consumer operation executed end to end on existing authorized
infrastructure, with three coherent counterparts:

1. **omitted hook** — withdrawal absent → `validModify` refuses;
2. **wrong allocation** — hook present, allocation wrong → the consumer script
   refuses;
3. **initially invalid** — the pinned script unsatisfied at bootstrap or
   preservation → refused.

Plus the mutation that removes the invocation predicate, after which the omitted
hook is accepted again.

## Fences carried into this contract

No KERI operations or economics encoded into naming. No registry owner, no
owner/stake bypass. No trusted caller-supplied obligation totals — an unchecked
`Bool` or a user-declared expected amount is not a check. No weakening of
rejection or recovery semantics. No upstream checkpoint-machine implementation.
Where a fact belongs to the consumer, its **verifying policy or script** is named,
or its authenticated evidence boundary is — never a declaration in place of one.

## Status

Interface returned for arbitration. The executable exhibit is commissioned at the
existing `%990` seat and follows the ABI, SDK, vectors, public-provenance path and
the connected controller/quorum recovery-retirement journeys already in flight. No
reciprocal waiting in either direction; no new seat, budget, upstream edit,
deployment or release.
