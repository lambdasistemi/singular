# Registry association — the faithful repair, and what it costs across boundaries

> **REVISION 2, 2026-09-12T19:22Z — READ THIS FIRST.** The per-registry
> **representative parameterization described below is WITHDRAWN** and no consumer
> may migrate from it. It is defeated by a copied-policy rival: cage B bootstraps
> legitimately with its own token but sets `B.State.representative_policy` to A's
> honest applied policy, which `validateMint` (`state.ak:228-245`) admits because
> it destructures `representative_policy: _representativePolicy` and never
> constrains it. The comparison is against a copyable datum field, so it never
> reaches any derivation. `representative` therefore stays at **1 parameter** and
> `6f14bdea…` does not move. The current design is in **"Revision 2 — the
> token-identity carrier"** at the end of this file. Everything between here and
> there is retained as the record of a rejected approach.

For the desk to route to epic 18 before any consumer migration. Commissioned by
NOTE-061; design is mine, cross-boundary implications are returned here first.

## The finding: this is E-001 again, one field over

`Representative` in the accepted Lean is

```lean
structure Representative where
  registry : Nat
  key : Nat
  policy : Nat
  assetScope : Nat
  deriving Repr, BEq, DecidableEq
```

with `representative s key = { registry := s.config.registry, key,
policy := s.config.representativePolicy, assetScope := … }`, and `proposalNative`
requiring `p.registry == s.config.registry ∧
p.initial.representative.registry == p.registry`.

So **the registry is part of the representative's identity, structurally, with
decidable equality** — exactly as `policy` was. E-001 was the case where `policy`
had no concrete counterpart and a foreign-policy representative was accepted on
chain. `registry` has no concrete counterpart either. Same defect shape, one
field over, and it is a refinement gap rather than a product question: no Lean
change is needed or authorized.

**Correction to my own previous wording.** I wrote that retirement is "saved
today by the accident that it must spend a state". That is wrong and the desk is
right to strike it: spending an *arbitrary valid rival cage* binds nothing to
this name either, and an empty `Modify` succeeds today. Neither path has safety
evidence, and the absence of an executed rival attack is not safety. The claim
needs its own counterexample — epic 18 should try **both** the current `ddfc4e9`
spent path and the proposed reference mapping.

## Why no on-chain value distinguishes cages today

`applyBytesParam` applies **one** parameter to the representative program: the
application policy hash, which is global. Every cage therefore shares one applied
representative policy (`53828b96…` at `ddfc4e9`), and `State.representative_policy`
is bootstrapped to that same shared value. `expected_rep_policy` then compares
against whatever cage it happened to find. The representative asset name encodes
key and incarnation, not the registry. `NamingRecord` carries no registry.

## The repair: make the representative policy per-registry, as the model says

`policy := s.config.representativePolicy` is **per-registry by construction** —
it is a field of that registry's `Config`. The concrete refinement should match:
parameterize the representative validator by the registry identity in addition to
the application policy, so each cage's applied representative policy is its own.

Consequences, which are the point:

- a rival cage pins **its** policy, so an honest claim's representative token is
  not under it and `quantity_of(claim.output.value, expected, stored_rep) == 1`
  fails — the existing check starts doing the work it appears to do;
- `expected_rep_policy` may then read from a **reference input** safely, because
  the policy comparison itself now carries the registry binding. The phase-2 hold
  lifts on this repair, not before it;
- no identity field is invented and no interface is silently changed: the
  registry identity used is an **existing authentic value** — the cage token
  under `mpfs_state_hash`, which is seed-gated, unique per cage, and already the
  thing that authenticates the state.

Which exact bytes represent the registry — the cage token name alone, or the
state policy and name together — is the one sub-decision I want epic 18's
canonical-service view on before it is fixed, because it is the value consumers
must reproduce.

## Cross-boundary implications, returned before migration

| surface | effect |
|---|---|
| `representative` validator | parameters **1 → 2** (application policy, registry identity). Unapplied hash `6f14bdea…` changes |
| applied representative policy | **no longer one value** — one per registry. The component tuple's `53828b96…` becomes a *per-cage* derivation, and any consumer holding it as a constant breaks |
| `State.representative_policy` | unchanged in type and position; its bootstrap value becomes the cage's own applied policy |
| SDK | must derive the applied policy per cage: `applyBytesParam` gains a second application. `cfgRepPolicy`/`bootStateFromCfg` change shape |
| `naming.ak:202` `mpfs_state_hash` | unchanged by this repair alone (it pins the state *script*, not a cage) |
| `application` | unchanged unless the registry bytes must be read there |
| `retirement_custody`, `staking`, `request` | not on this chain |
| epic 18 companion `7816305` | needs the per-cage derivation, not a constant policy |

**This supersedes the component tuple's single applied representative policy.**
The accepted `ddfc4e9` component keeps its stated limits and its evidence; it is
simply not the final M1 tuple, which was already recorded.

## Division of labour I propose, so nothing waits vaguely

- **epic 17 (me, `%990` seat):** the Lean-faithful concrete repair — the
  representative parameterization, the state bootstrap, `expected_rep_policy`'s
  reference-input extension once the binding holds, the SDK derivation, and the
  controls: an otherwise-valid **rival cage** with a different
  `representative_policy` refused, a **forged reference** refused, honest
  controller and quorum retirement initiation passing with no empty `Modify`, and
  a mutation removing the registry binding that lets the rival cage through;
- **epic 18 (through the desk):** the canonical registry-identity representation
  consumers must reproduce, the executed rival-cage counterexample against **both**
  the current `ddfc4e9` spent path and the reference mapping, and the consumer
  application/plugin enforcement of processed refunds, checkpoint locking and
  folder tips — the rows my worker's `file:line`-or-`NONE` map is about to report
  as unenforced in Singular.

Permissionless submission, true name/controller authority, and the absence of any
registry-owner role are preserved throughout. No upstream checkpoint machine, no
stake-owner restoration, no fee invented.

---

# Revision 2 — the token-identity carrier

Supersedes the parameterization scheme above. Two constraints shape it, both from
the desk and both binding:

1. **the association must be checked against the supplied state's own unforgeable
   token identity, never against a field the supplier chose** — B cannot forge A's
   cage token, but B can copy any datum value;
2. **the accepted naming datum keeps its FOUR fields and the fixed wire contract.**
   No new `NamingRecord` field, and a caller-supplied registry label is not
   authenticated by being present.

The model already resolves where it belongs: registry is a field of
**`Representative`**, and `Representative` is concretely *(policy, asset name)*.
So the carrier is the **representative asset name**, which today is

```aiken
fn representative_name(control_hash: ByteArray) -> ByteArray {
  bytearray.concat(bytearray.concat(#"526570", control_hash), #"00")
}                       // 0x526570 ‖ control(28) ‖ incarnation(1) = 32 bytes
```

— exactly 32 bytes, and it encodes `key` and `assetScope` but **not `registry`**.
That is the same omission shape as E-001: an abstract field with no concrete
counterpart.

## The four questions the desk asked, answered concretely

| | |
|---|---|
| **carrier** | the representative asset name, re-derived as `0x526570 ‖ blake2b_224(registry_asset_id ‖ control_hash) ‖ incarnation`. 32 bytes, unchanged length, no datum change |
| **`registry_asset_id`** | the **full native asset identity** of the cage token: state policy id ‖ cage token name, using the production `Data`/asset encoding — never a textual hex convention. Exact type, order and bytes are published through the desk before any consumer migrates |
| **creation check** | at the insert fold, which already proves which cage is acting by its own connectivity: the minted representative's name must equal that derivation over the **spent state's own authenticating token** |
| **preservation** | the name is part of the token; it cannot change while the token exists. Nothing to enforce per transition |
| **check on retire** | recompute the name from the **supplied state's own authenticating token** and require equality with the claim's `stored_rep`. Copied-policy B now fails on the token, not the field, because B's cage token differs from A's. E-001's policy comparison keeps doing its own job on top |

Cost is two `blake2b_224` calls — at the fold and at the retire. That is the cheap
end; it is **not** the declined option of applying parameters to a program on
chain.

## What this moves, and what it does not

- **every representative asset name changes.** The correspondence document, the
  wire vectors covering representative names, and epic 18's identity table all
  rebind. Say so before consumers migrate;
- `representative` stays at **1 parameter**; `6f14bdea…` does **not** move;
- the naming datum's four fields, the fixed wire contract, `retirement_custody`,
  `staking` are untouched;
- `request`'s **unapplied** program is unchanged; its **applied** identity moves
  whenever the state-policy parameter moves in the combined revision — the two are
  reported separately from now on.

## Still epic 18's, unchanged

The canonical representation consumers reproduce; the executed rival-cage
counterexample against **both** the current `ddfc4e9` spent path and the reference
mapping; and the consumer-side enforcement of processed refunds, checkpoint
locking and folder tips.
