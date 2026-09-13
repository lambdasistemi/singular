# The consumer hook: `ran` is `staking.ak`, and it is inert by construction

**This supersedes my previous version entirely. Its central claim was wrong.** The superseded text
is at `handoffs/authenticated-obligation-answer.SUPERSEDED.md`.

## What I got wrong

**1. Posting is not validation.** I called the request datum "authenticated" because a spender
cannot rewrite it. **Creating an output at a script address does not execute that script.** A poster
chooses its initial datum freely. Immutability-after-posting says nothing about validity-at-posting.
**So the forged-obligation control stands, and must be a validly posted, coherent but
consumer-invalid operation/allocation case** — not a datum rewrite, which only tests ledger input
integrity.

**2. The fold never checks the request address.** `state.ak:90-101` — `mkAction` inspects **any**
input whose inline datum parses as `RequestDatum` with a matching `requestToken`:

```aiken
when input.output.datum is {
  InlineDatum(datum) ->
    if datum is RequestDatum(request): CageDatum { … if requestToken == tokenId {
```

**No address comparison.** A caller-controlled **public-key** input carrying that datum shape
qualifies, so **`request.spend` is not necessarily invoked** and the parameterized request validator
I called the "authenticity root" **is never reached**. t87b's span uses exactly such a fake
public-key request input — that fixture was the standing reminder, and I read past it.

**3. Generic `Operation` is not the consumer's operation set.** It is Insert/Delete/Update **of
bytes** — not `register`/`revive`/`goDormant`/`goConvicted`/`convict`. Branching on it cannot
identify those semantics. And `inputLovelace` is the **deposited** value, not a processed refund.
Folder identity remains absent.

## The concrete counterpart of `ran` — the answer

`Cage.lean:126` — `runBody (pl : Plugin) (ran : Bool) … = if ran then pl.body … else cageOnlyBody …`
and `:131-134` — `routeValue .delegatedRouting => acc''` versus `.refundAll => … refunds ++ [(r.owner, r.op.bond p)]`.

**`ran` is "the plugin hook ran".** `Cage.lean:121` names its concrete counterpart outright:
`Plugin.trivial` is **"`staking.ak` as shipped"**.

**`staking.ak` at ddfc, in full:**

```aiken
validator staking {
  withdraw(_redeemer: Data, _account: Credential, _tx: Transaction) { True }
  else(_) { fail }
}
```

**Only `withdraw`. `else(_) { fail }` means the staking credential can never be registered** — the
same fact CG14/CG15 recorded as could-not-execute (`MissingScriptWitnessesUTXOW` without the
witness, cert-purpose `CekError` with it) and that Q-004 observed.

**So the shipped hook cannot run.** That is a source fact about `staking.ak`.

**But do not promote it further than it goes.** Inability to register the shipped trivial withdrawal
script does **not** by itself instantiate the abstract model's independent `ValueMode` as
`refundAll`, and does **not** prove all concrete payment behaviour. The bound primary
`registry-as-mpfs.md:200-220` calls `refundAll` an **idealisation**, and says its no-lock theorem
concerns the **model's `routeValue`** — not the current `validModify`. My earlier version chained
"hook inert → `refundAll` → `refundAll_never_locks`" and turned a **model inference into a source
proof**. Withdrawn.

**What survives is the source-level finding, which is enough:** there is **no demonstrated necessary
authenticated consumer transition** during a fold. The hook that would supply one cannot run, and
nothing else consults one.

## The missing interface, named exactly

**NONE — and not for want of a field.** The intended vehicle exists, is named, and is **inert by
construction**: a hook whose credential cannot be registered can never run, so no authenticated
consumer transition is ever consulted during a fold.

**Smallest in-scope implementation:** a mechanism by which the consumer's plugin body **necessarily
runs** during a fold — i.e. `staking.ak` (or its replacement) becoming registrable **and** its
execution being **required**, not merely permitted, for a processed request. Both halves are needed:
registrable-but-optional leaves `ran = false` reachable, which is the current state with extra steps.

**Epic 17 owns the representation**, routed through root. Not commissioned: the upstream checkpoint
machine, KERI economics in naming, owner privilege, new economic terms, or a user decision.

## What survives from the superseded version

The narrow observations, which root confirmed useful: `owners` carries each input's lovelace and
`sumRefunds` discards it; `tip` is per-request and checked `== stateTip`; refund **destinations** are
enforced positionally; an owner is appended only when `inputLovelace > 0`, so a **zero-lovelace
request skips the refund branch entirely**.

## Controls

- **forged-obligation — RETAINED**: a validly posted, coherent, consumer-invalid operation/allocation.
- **public-key request input**: an input carrying `RequestDatum` at a non-script address — does the
  fold accept it? t87b's span suggests yes.
- **wrong-output**: crossed amounts, aggregate-correct — must refuse.
- **omitted-hook**: the crossed case starts passing again.
- **zero-lovelace bypass**: processed request with no lovelace must not silently skip the branch.
