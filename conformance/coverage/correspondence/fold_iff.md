# Correspondence: `fold_iff` — Lean ⇄ acceptance story, under load

The second representative page (issue #80; NOTE-004/005). The first page
(`naming_occupied_key_refuses_duplicate.md`) shows the notation at its simplest; this one
renders the format **under load**: a universally quantified `Given`, both directions of an
`↔`, five conjuncts, two of them conditional. Source reading: the epic-18 owner's derivation
in `handoffs/80-correspondence-example-fold-iff.md`, independently verified here where the
page states facts (verification notes inline; disagreements surfaced, none silent).

**This page is not execution evidence and does not reduce debt** — the obligation it
renders is still unmapped and insufficient-layer in the committed record. Its
permissionless direction was settled design contradicted by the implementation; that defect
(epic 17, #79) is **repaired and landed**, and the repair is confirmed by execution (below).
It was never an undecided reading.

## 1. The pinned Lean claim

| field | value |
|---|---|
| qualified name | `Singular.Statements.fold_iff` |
| statement digest (sha256) | `0c335c6e6f3902a7b8c295112f74ccd70515cbdca4715846442828e69c3538f6` |
| source | `lean/Singular/Statements.lean:66-72`, `lean/` tree `dd9e508b…` (frozen) |
| proof status | `PROVED`, `debt: none` — proof status is recorded and is *not* implementation coverage |
| proof | `exact fold_ok s items mint net w t` — restates the `fold_ok` equivalence (`Singular/Lemmas.lean:299`, itself an unclassified obligation in the denominator) at the `step` interface |

The exact statement, verbatim:

```lean
theorem fold_iff (s : State) (items : List FoldItem) (mint : List Delta) (net : List ActionDelta)
    (w : Witnesses) (t : Result) :
    step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧
    foldItems s items = .ok t ∧ sameNet t.logical mint = true ∧
    (nonzero mint = true → w.representativeMint = true) ∧
    (actionNonzero net = true → w.applicationMint = true)
```

## 2. Faithful clause reading — every clause, no gist

An **equivalence**, universally quantified over *any* starting state `s`, *any* fold-item
list, *any* mint deltas, *any* action-asset net, *any* witness set, *any* result. Both
directions carry meaning.

Left to right — **necessity**: if a fold succeeds, all five hold. This
is what forbids the validator accepting a fold that violates one of them:

| # | Lean | reading |
|---|---|---|
| 1 | `w.nativeSpend = true` | a native spend witness was present |
| 2 | `foldItems s items = .ok t` | folding the items one after another from `s` succeeds and yields exactly `t` |
| 3 | `sameNet t.logical mint = true` | the representative deltas the fold logically implies equal, per asset, the transaction's mint field |
| 4 | `nonzero mint = true → w.representativeMint = true` | **conditional**: if the mint field is non-zero on some asset, the representative-mint witness is present; if the mint nets to zero, this clause requires nothing |
| 5 | `actionNonzero net = true → w.applicationMint = true` | **conditional**: likewise for the application action assets |

Right to left — **sufficiency**, and this is the direction that
establishes permissionlessness: if the five hold, the fold **succeeds**.
Nothing further may be required: no owner, no privileged folder, no
signature beyond the named witnesses. The right-hand side is the *complete*
precondition, and checking this direction is precisely what shows success
requires nothing else.

## 3. The story, in the same vocabulary

Vocabulary is Lean's: `State`, `FoldItem`, `Delta`, `ActionDelta`, `Witnesses`, `Result`,
`foldItems`, `sameNet`, `nonzero`, `actionNonzero`, `step` — each bound to its qualified
identity in the record when mapped.

```text
Feature: folding is exactly the five conditions — nothing more, nothing less

  Scenario: the fold biconditional, both directions
    Given any State s, any items : List FoldItem, any mint : List Delta,
      |    any net : List ActionDelta, any Witnesses w, any result t     # quantified, not chosen
      # direction ⇐ (the promise): nothing beyond these five may be required
    When step s (.fold items mint net w) is evaluated
    Then it is .ok t   if and only if   all five of:
      | 1 | w.nativeSpend = true                                        |
      | 2 | foldItems s items = .ok t                                   |
      | 3 | sameNet t.logical mint = true                               |
      | 4 | nonzero mint = true → w.representativeMint = true           |  # silent when mint nets to zero
      | 5 | actionNonzero net = true → w.applicationMint = true         |  # silent when net nets to zero

  Scenario exhibit (one concrete case, executed; exhibits, never replaces,
  the quantified property) — grounded in corpus case `S13d-fresh-insert-folded`
  (`lean/corpus.json` index 8, `result.accepted: true`):
    Given a one-item fold of queued certified Insert request 1 (outputId 2,
      | key 42) from an initialized state, with                                 |
      | 1 | w.nativeSpend = true                                                |
      | 2 | the item folding cleanly to t                                       |
      | 3 | mint [{rep42 scope0/policy8/reg1, +1}] equalling t.logical [{+1}]   |
      | 4 | nonzero mint, so w.representativeMint = true is present             |
      | 5 | action net [] so the clause is silent, applicationMint false        |
    When step runs the fold
    Then it succeeds — accepted in the corpus run — with all five conjuncts
explicitly present, the conditionals in firing (4) and silent (5) form.
    The arithmetic, shown so a reader need not re-derive it: `t.logical`
      is `[{rep42, +1}]` (the Insert implication), `mint` is `[{rep42, +1}]`,
      and `sameNet` checks `quantity a rep42 == quantity b rep42`, i.e.
      `1 == 1` → true; `nonzero mint` is true (`1 ≠ 0`), so clause 4 fires
      with its witness present; `actionNet` is `[]`, so clause 5 is silent
      with `applicationMint` false. The previous exhibit failed here with
      `1 == 0`; this one shows `1 == 1`.
    Check (one line, tested on this host — no `jq`/`python3` outside a dev
      shell is needed):
      `nix run --quiet nixpkgs#jq -- -c '.cases[] | select(.case.id ==
      "S13d-fresh-insert-folded") | {mint: .case.action.fold.mint,
      logical: .result.value.logical, accepted: .result.accepted}'
      lean/corpus.json`
      prints `mint` `[{rep42 scope0/policy8/reg1/key42, +1}]`, `logical`
      identical, `accepted: true`.
    And a rival story asserting "also the state owner must have signed" is FALSE here —
      that requirement is exactly what the converse forbids, and what F-002 records
      the compiled validator as wrongly demanding.

  Scenario zero-side (separate satisfiable case, model only — held on the
  consumer, see below):
    Given any State s with no requests, items [], mint [], net [], and
      | w.nativeSpend = true, representativeMint = false, applicationMint = false |
    When step runs the fold
    Then it succeeds in the model: 1 holds, 2 holds because `foldItems s []`
      is `.ok` with `logical` defaulting to `[]` (`Model.lean` empty equation
      plus `Result.logical` default), 3 holds vacuously (`sameNet [] []`),
      and 4–5 are silent with both mint witnesses absent. A zero mint alone
      implies no such result — every other precondition must be present.
    And the consumer side of this exact case is HELD, not established:
      empty folds on the imported partition were the consumer restriction
      held under Q-002 (CG11). **That ruling has since been given: empty
      processing batches are to be rejected** (approved 2026-09-12). The
      equation below remains an exact reading of the **pinned pre-revision**
      contract at `012e404`; the approved nonempty revision is **pending
      implementation** and is not shown here. No Insert is
      claimed to have zero net mint, here or anywhere on this page.
    Check: no corpus case covers it — of the 23 fold cases in
      `lean/corpus.json`, none has empty `items` (same `nix run … nixpkgs#jq`
      host command with `select(.case.action.fold.items == [])` prints
      nothing). The satisfiability above is therefore definitional
      (`foldItems` empty equation, `Result.logical` default, `sameNet`
      vacuous, `nonzero` false), stated as such, not executed evidence.
```

Non-vacuity obligation this page fixes for the future story: each conditional's antecedent
(clauses 4, 5) must be **reached** by at least one generated case, and the zero side must
also be exercised — a mint that nets to zero with the witness **absent** must still succeed
when every other fold condition holds, because clause 4 asserts nothing there. A suite
that only ever tests non-zero mints genuinely exercises clause 4 (the antecedent holds,
so the consequent is really required) — what it leaves untested is narrower and exact:
the zero-net / no-witness branch, where the antecedent is false.

## 4. Implementation boundary — where this must be checked, and what is known today

| clause | implementation boundary | status |
|---|---|---|
| per-request checks (1, 3, 4, 5 as exercised per action) | `mkAction` (`onchain/validators/state.ak:71`), driven per input by `validModify` (`state.ak:162`) | partially exercised by merged CG rows |
| frame conditions (output tip, process/retract times, recomputed root, credential, lovelace, token) | `validModify` body (`state.ak:162-196`) | partially exercised by merged CG rows |
| 2 | `foldItems` sequencing vs the on-chain fold | exercised for single-item folds; multi-item sequencing not isolated |
| **converse: nothing else required** | `state.ak` dispatches `Modify(actions) -> validModify(…)` with **no ownership check**; the site carries the comment *"Permissionless fold (issue #79, Defect 1): Modify must NOT require the owner"* | **repaired and landed**; confirmed by execution — CG20 `accepted`, verdict `agrees-with-model`, tx `4142f7d6…`. Historically **REFUSED** pre-#79 — both halves by execution |

Empty-fold note, read directly: the fold accumulates over `inputs` carrying
actions as state and discards the tail (`let (expectedNewRoot, _, …)` at
`state.ak:185`), so with no matching request input the recomputed root is
the starting root and an empty `Modify` validates. That is the mechanism
behind CG11's observed acceptance, and what cardano-keri's audit described.

Verification notes for this table (renderer's, per NOTE-004's "tell me where you disagree").
Pins below bind to **two different commits, and the distinction matters**:
**historical** facts (the pre-#79 owner gate, the zero-side exhibit's reading of the pre-revision
contract) were read at worktree base `012e404`; **current** facts (the post-#79 `Modify` dispatch)
are read at `6fd02c7ed6602153de71a555298337cb89443447` — a commit pin, verified to carry that dispatch,
not the movable `main` label. Each statement below says which it is.

- **Verified directly, current source:** `onchain/validators/state.ak` dispatches
  `Modify(actions) -> validModify(state, input, policyId, cageToken, tx, actions)` with **no
  ownership check**, the site carrying the comment *"Permissionless fold (issue #79, Defect 1):
  Modify must NOT require the owner"*. `validateOwnership` survives only on other branches, and
  those are what the operator's no-owner ruling and epic 17's ownerless repair remove.
  **The #79 defect is repaired and landed.**

  **Historical, and kept as history:** before that repair a witness set satisfying all five clauses
  existed whose fold the compiled validator refused (owner unsigned) — an implementation defect per
  epic 17's `A-002`. Our own runner supplied the owner signature on every fold, which is why no row
  observed it: recorded, not defended. The design was never in doubt — this theorem's sufficiency
  direction and `specs/protocol/spec.md:117` ("no native owner, privileged requester or privileged
  folder gate") both state permissionlessness.

  **Confirmed by execution, both halves:** regression row **CG20 failed pre-#79 and is `accepted`
  post-#79**, verdict `agrees-with-model`, tx `4142f7d6…`, candidate `1d98d51a`, `dirty:false`.
  The contradiction is closed. **The coverage debt is not**: this page still renders an obligation
  that is unmapped and insufficient-layer. Producer acceptance is **outstanding** — `fe89e68` is now
  submitted for owner acceptance, superseding `617e434` as the candidate under review — and that is
  a **producer-acceptance** boundary, not statement or coverage debt.
- **Mapping obligation added by this page:** the conditionals (4, 5) need a reachable
  antecedent case and a zero-side case in the future story; neither exists in any merged row
  today (rows always supply both witnesses). That is mapping/execution debt, tracked in the
  record like every other row.

## 5. What is *not* modeled, stated so a reader is not misled

- No **proof encodings**: no `ProofStep`, no `Fork`/`Branch`/`Leaf`. The Merkle proof is a
  representation refinement beneath `foldItems` — the subject of the separate `excluding()`
  divergence.
- No **fees, tips, bonds or refund routing** — `.fold` has no value accounting at all.
- No **submitter condition** — its absence *is* the permissionless claim, and is the point.

## 6. Settled design, open repair

Whether the registry is permissionless is not undecided: this
theorem's sufficiency direction and `specs/protocol/spec.md:117` both
state it, and epic 17's `A-002` identified the owner gate in the
compiled validator as an implementation defect assigned to #79. **That
repair has landed, and CG20 pins the fixed behaviour by execution.**
What remains open is the coverage debt around this obligation and final
producer acceptance (`fe89e68` submitted, superseding `617e434`) — the
debt and the evidence, never the design question. This page renders the theorem as stated and will not
be adjusted to fit the code.

## 7. Machine anchors

```json
{
  "obligation": "Singular.Statements.fold_iff",
  "statementSha256": "0c335c6e6f3902a7b8c295112f74ccd70515cbdca4715846442828e69c3538f6",
  "vocabulary": {
    "step": "Singular.Model.step",
    "fold": "Action.fold",
    "foldItems": "Singular.Model.foldItems",
    "sameNet": "Singular.Model.sameNet",
    "nonzero": "Singular.Model.nonzero",
    "actionNonzero": "Singular.Model.actionNonzero",
    "Witnesses": "Singular.Model.Witnesses"
  },
  "evidence": {
    "checkId": "none yet — rows CG01-CG05/CG10-12 exercise folds generically but no row is bound to this identity",
    "resolvedContradiction": "F-002: pre-#79 spend demanded the owner before Modify dispatch (implementation defect per A-002). REPAIRED AND LANDED: Modify dispatches to validModify with no ownership check. Confirmed by execution both halves — CG20 REFUSED pre-#79, accepted post-#79 (agrees-with-model, tx 4142f7d6, candidate 1d98d51a). Design was always settled; coverage debt remains open and producer acceptance is outstanding"
  },
  "recordStatus": "unmapped, insufficient-layer — this page is correspondence, not coverage"
}
```
