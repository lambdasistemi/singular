# Correspondence: `fold_iff` — Lean ⇄ acceptance story, under load

The second representative page (issue #80; NOTE-004/005). The first page
(`naming_occupied_key_refuses_duplicate.md`) shows the notation at its simplest; this one
renders the format **under load**: a universally quantified `Given`, both directions of an
`↔`, five conjuncts, two of them conditional. Source reading: the epic-18 owner's derivation
in `handoffs/80-correspondence-example-fold-iff.md`, independently verified here where the
page states facts (verification notes inline; disagreements surfaced, none silent).

**This page is not execution evidence and does not reduce debt** — the obligation it
renders is still unmapped and insufficient-layer in the committed record, and one direction
of it is under an unresolved user ruling (below).

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

Left to right — **if a fold succeeds, all five hold**:

| # | Lean | reading |
|---|---|---|
| 1 | `w.nativeSpend = true` | a native spend witness was present |
| 2 | `foldItems s items = .ok t` | folding the items one after another from `s` succeeds and yields exactly `t` |
| 3 | `sameNet t.logical mint = true` | the representative deltas the fold logically implies equal, per asset, the transaction's mint field |
| 4 | `nonzero mint = true → w.representativeMint = true` | **conditional**: if the mint field is non-zero on some asset, the representative-mint witness is present; if the mint nets to zero, this clause requires nothing |
| 5 | `actionNonzero net = true → w.applicationMint = true` | **conditional**: likewise for the application action assets |

Right to left — **the direction that carries the product promise**: if the five hold, the
fold **succeeds**. Nothing further may be required: no owner, no privileged folder, no
signature beyond the named witnesses. The right-hand side is the *complete* precondition.

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

  Scenario exhibit (one concrete case; exhibits, never replaces, the quantified property):
    Given a one-item fold of a queued certified Insert from an initialized state,
      | with w.nativeSpend = true and a non-zero representative mint witnessed |
    When step runs the fold
    Then it succeeds, and clauses 1–3 hold with the mint witnessed by 4
    And a rival story asserting "also the state owner must have signed" is FALSE here —
      that requirement is exactly what the converse forbids, and what F-002 records
      the compiled validator as wrongly demanding.
```

Non-vacuity obligation this page fixes for the future story: each conditional's antecedent
(clauses 4, 5) must be **reached** by at least one generated case, and the zero side must
also be exercised — a mint that nets to zero with the witness **absent** must still succeed,
because clause 4 asserts nothing there. A suite that only ever tests non-zero mints has not
tested clause 4; it has skipped it.

## 4. Implementation boundary — where this must be checked, and what is known today

| clause | implementation boundary | status |
|---|---|---|
| 1, 3, 4, 5 | `state.ak` `validModify` witness and mint checks | partially exercised by merged CG rows |
| 2 | `foldItems` sequencing vs the on-chain fold | exercised for single-item folds; multi-item sequencing not isolated |
| **converse: nothing else required** | `state.ak` `spend` calls `expect validateOwnership(state, tx)` **before** dispatching `Modify` to `validModify` | **CONTRADICTED — F-002** |

Verification notes for this table (renderer's, per NOTE-004's "tell me where you disagree"):

- **Verified directly:** `onchain/validators/state.ak`, `spend`: `expect validateOwnership(state, tx)`
  precedes the `when redeemer is { Modify(actions) -> validModify(...) }` dispatch. The F-002
  contradiction stands as stated: a witness set satisfying all five clauses exists whose fold
  the compiled validator refuses (owner unsigned). Our own runner supplied the owner signature
  on every fold, which is why no row observed it — recorded, not defended. Regression control:
  row CG20; behaviour held for a user ruling.
- **Refinement, not disagreement:** the witness and mint checks for clauses 1, 3, 4, 5 are
  not literally inside `validModify`'s body — it drives the per-action fold (`mkAction`) and
  validates the resulting root and outputs. The enforcement lives in that fold path. The
  owner's "partially exercised by merged CG rows" is accepted with this precision added.
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

## 6. Unresolved interpretation

Whether the registry is permissionless — this theorem's converse and
`specs/protocol/spec.md` — or owner-gated, as the compiled validator enforces, is with the
user (Q-002, story 3). Until ruled, no reading of this theorem is adjusted to fit the code,
and this page renders the theorem as stated.

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
    "knownContradiction": "F-002 (validateOwnership before Modify), held for user ruling Q-002"
  },
  "recordStatus": "unmapped, insufficient-layer — this page is correspondence, not coverage"
}
```
