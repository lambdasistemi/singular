# #87 slice 1 — frozen invariant statements and mappings

Frozen by the epic owner from source at base `5bd7c79dd64fd9c7ec872f1c20ab2f5e075366ad`, before the
driver encodes anything. The driver implements these; it does not restate, widen, or reinterpret them.

## Authority — corrected 2026-09-12

An earlier version of this file said changing a statement here "requires an owner ruling". **That
was wrong** and claimed authority the epic owner does not have.

The epic owner may **fix a transcription** or **explain an implementation mapping** against
unchanged source and rulings. Changing **hypotheses, quantified domain, conclusions, refusal
expectations, or the enforcement actor** requires an **OPERATOR** ruling, escalated through a
concrete user story — as `code-the-design` already states. Neither the driver nor the epic owner
may move any of those.

## I-1 — Ownerless authority

**Provenance, stated honestly.** The authority for I-1 is the **explicit operator ownerless-registry
ruling**, checked against the full modeled `State`, `Config`, `Witnesses` and `Action` definitions.

An earlier version of this freeze cited a grep over `lean/Singular/Model.lean` for owner/End/migration
tokens returning nothing, and called that "independently verified". **An empty grep is not proof of
role absence** and must not be promoted to a compiled invariant check. A role can exist under any
name — which is exactly how the `State.stake_script` hook escaped an owner-word inventory earlier in
this epic. The grep is a weak corroborating observation. **The ruling is the authority.**

**Compiled claim.** No reachable path through the compiled validators grants registry-owner authority
to terminate, migrate, or seize a registry. Unmodeled `End`, migration, `Sweep` and burning routes
must not restore inherited destructive authority.

**Expected against today's artifact: REFUTED — and that is correct.** Epic 17 has not landed the
repair; `state.ak`'s `End` calls `validateOwnership` then burns the registry token, and
`validateMigration` calls it on predecessor state. Slice 1 run now is a **RED witness of a known
defect**. It is not a harness failure, and it is not completed #87. Keep this initial known-defect
RED **separate** from definitive repaired-artifact acceptance.

**Absence of a modeled transition is not permission to invent one.** Do not encode a replacement
lifecycle to make a check pass.

**Preserved, untouched:** legitimate application and name controllers, request and refund
requirements, and ordinary funding witnesses keep their own clauses. **Do not invent a ban on a
registry creator funding or signing.**

## I-2 — Supported fold

`Singular.Statements.fold_iff`, verbatim at this base:

```lean
theorem fold_iff (s : State) (items : List FoldItem) (mint : List Delta) (net : List ActionDelta)
    (w : Witnesses) (t : Result) :
    step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧
    foldItems s items = .ok t ∧ sameNet t.logical mint = true ∧
    (nonzero mint = true → w.representativeMint = true) ∧
    (actionNonzero net = true → w.applicationMint = true)
```

**It is an `↔`. Both directions are binding.**

- **Left-to-right — necessity.** A successful fold implies all five conjuncts.
- **Right-to-left — sufficiency.** The five conjuncts imply success. **This direction establishes
  permissionlessness**: nothing beyond these five may be required. A validator demanding an extra
  signature, an owner, or any sixth condition violates this direction while satisfying the first.
  A harness checking only necessity would pass a validator that refuses everything, and would not
  detect a re-introduced owner check.

**The two trailing conjuncts are implications, not conjunctions** — `nonzero mint → representativeMint`
and `actionNonzero net → applicationMint`. Encoding them as unconditional requirements overconstrains
and yields a **false REFUTED**.

### This is an abstract theorem; it needs an explicit mapping

`step` is a function over the **modeled** `State`. `fold_iff` is **not** a theorem about every
possible ledger context or every byte sequence a script could receive.

The driver must supply an **explicit mapping from the theorem's abstract inputs to compiled inputs**,
together with the relevant **ledger and representation prerequisites** — which encodings correspond
to well-formed abstract states, and which do not.

**Do not treat sufficiency as demanding success for arbitrary malformed encodings.** A validator
rejecting a malformed datum is not violating `fold_iff`; the abstract theorem says nothing about
inputs outside its domain. Encoding it that way manufactures a false REFUTED and would send epic 17
after a defect that does not exist.

**Preserve the exact theorem. Do not silently add assumptions** to make the mapping convenient.
Escalate genuine ambiguity with the smallest concrete story, and continue independent
import/identity/instrumentation work while it is pending.

## Disposition vocabulary — not interchangeable

`#blaster` discharge is **`SMT-VALID (no proof term)`**, never `KERNEL-PROVED`. Finite CEK executions
are **`TESTED`**, and the quantified obligation **remains debt**. A bounded result is reported with
its limits, never promoted to universal equivalence.

## Identity triple — all three, every record

| Field | Value at dispatch |
|---|---|
| Commit | `5bd7c79dd64fd9c7ec872f1c20ab2f5e075366ad` (snapshot; **not** definitive) |
| Toolchain | `onchain/aiken.toml` *documents* `v1.1.16` / plutus `v3` — **prose, unverified**; the build must report its own version |
| `BuiltinSemanticsVariant` | Selected by **Plutus language + major protocol**, not by era alone. Configured target is **PV10 + V3**, so bind **`defaultFunSemanticsVariantC`** explicitly (plutus `e5bec6ae`: `vanRossemPV`=11; `mkDynEvaluationContext` selects C when `pv < vanRossemPV`, E from van Rossem). An earlier version of this table said "post-Conway -> E", copied from the skill era table, which omits the intra-era van Rossem boundary — that was a commissioning defect. PV11+ requires E; mismatch or unsupported target is `COULD-NOT-EVALUATE`. Query the live protocol version per decisive run; never assume it. |

Two of three is `COULD-NOT-EVALUATE`, not "probably fine".

## Pinned toolchain

- `Lean-blaster` `01240b37e3d89dd7c5de13400327b93ba069ecea`
- `PlutusCoreBlaster` (pinned) `17cee18a2058790bca36282d82c19146587fb2d1`
- `CardanoLedgerApiBlaster` — reachable via prior-art flake, **not independently confirmed**; confirm
  or record as blocking debt.
