# Generic-to-consumer support interface — source-bound mapping and proposal

Owner-level investigation per NOTE-091. Read at ddfc (`/code/singular-e17-accept`, `ddfc4e9`).
**Correcting my own earlier "NONE": the picture is more precise, and partly better, than I reported.**

## 1. Existing enforcement entrypoints, and what necessarily invokes them

| validator | purpose | invoked for the consumer fold by |
|---|---|---|
| `state.ak` `validator state()` | `mint(MintRedeemer, PolicyId, Transaction)` | registry bootstrap (`Minting(seed)`) / `Migrating` |
| | `spend(...)` → `Modify(actions) -> validModify(...)` | **the fold. This is the entrypoint.** |
| `request.ak` `validator request(statePolicyId, cageTokenName)` | `spend(...)` | each consumed request input |
| `staking.ak` | `withdraw` only | never registrable (Q-004) — not an enforcement path |

**Nonempty zero-net batches still reach the refund branch.** `validModify` gates on
`let n = list.length(owners)`, not on net value: `n = 0 -> True`, otherwise the refund arithmetic
runs. So a nonempty zero-net fold **is** checked — the branch is owner-count-driven, which is the
right shape for the consumer's case.

## 2. What is observed and checked TODAY — corrected

### Processed refunds — **destinations enforced, amounts only aggregate**

`sumRefunds` (`state.ak:151-164`) walks refund outputs **in order against `orderedOwners`**:

```aiken
expect address.VerificationKey(vkh) = output.address.payment_credential
expect vkh == owner
```

**Per-request destination IS enforced, positionally.** My earlier "no enforcement" was wrong.

The **amounts** are bounded only in aggregate (`:212-218`):

```aiken
let owed        = totalInputLovelace - tx_fee - n * tip
let maxRefunded = totalInputLovelace - n * tip
expect totalRefunded >= owed
expect totalRefunded <= maxRefunded
```

This exactly explains CG19: bonds 5+3 refunded **2+4**. Each owner received *an* output at the right
address — destinations passed — while **no owner received *their* bond**, and the aggregate 6000000
sat inside `[owed, maxRefunded]`. **"Crossed refunds" means crossed amounts, not crossed
destinations.**

### Folder tips — **arithmetically reserved, destination NOT enforced**

`n * tip` appears in **both** bounds, so the tip is *withheld from the refundable pool*. But **no
output names the folder.** The tip is reserved and then unaccounted: nothing requires it to reach
anyone.

### Checkpoint locking — **NONE**

`grep -c checkpoint` over the generic validators returns **0**. There is no term, no observable, and
nothing to attach to.

## 3. The missing interface, precisely

The generic partition observes **owners** (a `List<Pair<VerificationKeyHash, Int>>`) and **lovelace
per output**. It has **no notion** of:

- **which bond belongs to which owner** — the `Int` in the pair is used for `n` and ordering, not
  as a per-owner amount obligation;
- **the folder's identity** — no parameter, redeemer field, or datum field names it;
- **a checkpoint destination** — absent entirely.

**So the hook is: `validModify` must be able to compare a per-owner expected amount and a named
folder destination.** Today it can express neither, and the consumer's economics live in
`Registry.processBody` / `stepFn` on the other side of a boundary that carries no such values.

**This is the concrete interface requirement for epic 17, routed through root** — not a naming
change, and not KERI economics imported into naming.

## 4. Minimum in-scope executable consumer adapter/fixture

**Smallest thing that allows AND requires the checks:**

- **allows**: the fold must carry, per processed request, an **expected refund amount** and — once —
  a **folder destination**. Whether that rides in the redeemer's action list (where `owners` already
  travels) or in `State` is epic 17's representation choice.
- **requires**: `sumRefunds` compares **per-owner amount**, and one output is checked against the
  folder destination. Aggregate bounds stay as the outer envelope.

**Fixture** (in-scope, consumer-shaped, no upstream checkpoint machine):

1. two processed requests, **differing recorded owners and differing bonds** — CG19's retained
   **shape** (5+3), since its body is missing;
2. a **register or revive** in the same batch, so checkpoint locking has an observable **independent
   of the refunds**;
3. an output the **folder** receives, distinguishable from change.

## 5. Controls that would establish the contract

| control | expectation |
|---|---|
| honest allocation | **ACCEPT** — exact bond to each owner, tip to the folder |
| **crossed amounts, aggregate-correct** (the 5+3→2+4 shape) | **REFUSE, attributed** — this is the case today's aggregate check **cannot** see |
| **tip withheld** — `n * tip` reserved, no folder output | **REFUSE** — today this passes |
| **omitted hook** — the new comparison removed from `validModify` | the honest case still accepts **and the crossed case now accepts**, proving the check was load-bearing |
| checkpoint deposit refunded instead of locked | **REFUSE** — the case a blanket exact-refund repair introduces |

**A test-only always-true witness cannot certify enforcement.** The omitted-hook control is the one
that makes the others mean anything: if removing the comparison changes nothing, the comparison was
decoration — the exact failure this epic found twice today.

## Responsibility

**Epic 18**: the witnesses — that the gap is real, and that the controls discriminate.
**Epic 17**: the representation and the generic product change, through root.
**Neither**: upstream checkpoint implementation, KERI economics in naming, any owner or stake role.

---

# CORRECTIONS — 2026-09-12T19:30Z

Four errors, all mine, all verified at source before correcting.

## C1. A caller-supplied expectation is not enforcement — this is the big one

I proposed that the fold "carry a per-request expected refund amount and a folder destination."
**That is not enforcement. It relocates the trust to the caller.** An attacker changes *both* the
declared expectation and the output, and the comparison passes.

**What is actually needed:** what **authenticates** each obligation — from the **request**, the
**operation**, and the **bound consumer transition** — and what **necessarily invokes** that
consumer check, including for a nonempty zero-net batch. **The generic `validModify` entrypoint is
not itself an identified consumer hook**, and naming it as the surface did not answer the question.

**Added control:** a **forged-obligation** case — declared expectation and output moved together —
alongside wrong-output and omitted-hook. Without it the other two pass a caller-trusting design.

## C2. The amount IS observed today — it is the wrong amount

`mkAction` (`state.ak:129-130`) appends `Pair(requestOwner, inputLovelace)`. **The `Int` is each
input's lovelace.** `sumRefunds` then destructures it away as `Pair(owner, _)` — **the data is
present and discarded.** My "used for `n` and ordering, not an amount" was wrong.

But an observed amount is not the required one: **that `Int` is the deposit**, not the processed
operation's required refund. `Cage.delegated_is_registry` selects `delegatedRouting` — **processed
register/revive LOCK funds while other operations refund.** So a blanket per-processed-request
refund, layered on the current aggregate envelope, **can still reject legitimate locking.**

**Required instead:** trace the **operation-specific equations** and name the exact **generic
boundary that both permits and requires** the bound application checks.

## C3. `Migrating` is refused, not supported

`state.ak:30` — `Migrating(_) -> fail`. My entrypoint table listed it beside `Minting(seed)` as a
mint purpose. **It is a refused purpose at ddfc.** Corrected.

## C4. "Nonempty zero-net reaches the refund branch" holds only under an assumption

`mkAction` appends an owner **only when `inputLovelace > 0`** (`:129`). So a **nonempty batch whose
inputs carry no lovelace yields `n = 0`** and takes the `0 -> True` branch — **no refund check at
all.**

The claim is therefore conditional on **positive input lovelace**, and I stated it unconditionally.

## C5. And the recurring one: absence of a word is not absence of a hook

I wrote "checkpoint locking — NONE" on the strength of `grep -c checkpoint` returning 0. **Source
absence of the word is not proof of absence of an indirect application hook.** This is the same
error as the empty `owner` grep and the stale `types.ak` comment — third time today, and the only
reason it keeps landing is that a zero count *looks* like a measurement.

The NONE stands only as **"no direct term found by name"**, pending the operation-specific trace
above.

## Superseded, retained

The section above this one is kept as superseded evidence: its positional-destination finding and
its aggregate-amount finding were confirmed correct by root and remain the basis of the gap.
