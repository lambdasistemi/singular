# Two boundaries epic 18 owes in epic 17's combined revision

Per root NOTE-060. Coordination with epic 17 goes **through root**, not worker to worker.

## Boundary 1 — reference-input config read, and the rival registry

Epic 17 chooses a **reference-input config read** for retirement. The hazard root names is precise:

> **unspentness and authentic NFT possession alone do not prove that a referenced valid cage is
> THIS name's registry.**

A rival cage can be **entirely valid** — correctly minted, unspent, holding an authentic NFT — and
still not be the registry this name is bound to. Nothing in "valid" answers "whose".

**This is the concrete hook my canonical-service item was missing.** I had it split as:

- **(1) same-token forgery** — source-established, unexecuted: you cannot mint the canonical asset
  name without consuming the canonical seed;
- **(2) valid-rival service** — **open**, and untestable while it stayed abstract.

The reference-input read makes (2) testable at a **named boundary**: reference an otherwise-valid
rival cage that is not this name's registry, and observe whether the **official application**
accepts it.

**Scope, to be kept exactly:**

- The scenario exercises the **official application/SDK/native-policy path** performing a real
  operation. **Not** `Conformance.Authenticate` / `authenticateWeak` — a caller voluntarily invoking
  an identity predicate is the harness boundary already covered by #69, and it is **not** a
  substitute.
- **Do not replace it with same-token forgery.** Forgery is (1) and is a different claim.
- The exact representation is **resolved with epic 17 through root**, not chosen unilaterally here.

## Boundary 2 — admission is not allocation enforcement

Excluding processed `UpdateAction` from generic refund accounting **only admits delegated shapes**.
Admission is not enforcement, and the distinction decides which checks bind what:

| | question | what a check of it establishes |
|---|---|---|
| **compatibility / admission** | does the validator **permit** a delegated-shape transaction? | the shape is not rejected |
| **allocation enforcement** | is the **correct** allocation **compelled**? | a wrong allocation is refused |

A validator that admits every delegated shape and compels none passes admission checks completely.

### Which required M1 checks bind each

**Admission — established today:**

- **CG19** as currently executed observes admission only: crossed refunds **ACCEPTED**
  (`566ddc8079f0ab…`, bonds 5+3 refunded 2+4, aggregate 6000000 at the ceiling). Its same-run
  below-floor control shows the aggregate check is not inert — **that is an aggregate admission
  bound, not per-request enforcement.**

**Enforcement — required and NOT yet bound by any executed check:**

- **processed refunds** to the recorded owner — the consumer's `Registry.processBody`
  (goDormant/goConvicted/convict → `p.Mr` to the recorded owner);
- **checkpoint locking** — register/revive locking `p.D` into a checkpoint. Note this is the clause a
  blanket exact-refund repair would break, so it needs its own check, not a side effect of another;
- **folder tips** — `n * p.tip` to the folder (`Registry.stepFn`), which **no current check names**;
- **`Cage.delegated_is_registry`** selecting `delegatedRouting`, not `refundAll`.

**Related bound row:** CG06 — phase-2 retract returns **bond + tip**, registry untouched, bound in
CageSpec. That is an allocation enforcement obligation and is **bound elsewhere**, not executed here.

### What is needed

**An identified application enforcement boundary** for processed refunds, checkpoint locking and
folder tips. Until one is named, those three are **admission-only** and must be recorded as such —
not as satisfied by CG19's execution, which observed a different thing.

**Not commissioned by any of this:** no upstream checkpoint implementation, and no owner or stake
role.
