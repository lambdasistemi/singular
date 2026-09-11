# Correspondence: `naming_occupied_key_refuses_duplicate` — Lean ⇄ acceptance story

One representative obligation rendered for human review (issue #80; user criterion:
*"Humans should be able to match lean and acceptance"*). Read it in both directions:
every Lean clause points at its story clause, every story clause points back.
**This page is not execution evidence and does not reduce debt** — the obligation it
renders is still unmapped and insufficient-layer in the committed record.

## 1. The pinned Lean claim

| field | value |
|---|---|
| qualified name | `Singular.NamingStatements.naming_occupied_key_refuses_duplicate` |
| statement digest (sha256) | `5bb53ab9bde7a263c2119c592c8e21ce45c261b1160902e14d75eb69aa33c86b` |
| source | `lean/Singular/NamingStatements.lean:36` (frozen; digest bound above) |
| proof status | `PROVED` from the standard axioms only (`debt: none`, compiled axiom report) |
| depends on | `Singular.namingFoldRequest`, the frozen journey `activeOnce`, the generic `step` refusal at `lean/Singular/Model.lean:175` |

The exact statement, verbatim:

```lean
theorem naming_occupied_key_refuses_duplicate :
    namingFoldRequest activeOnce 2 = .error "occupied-key" := by
  rfl
```

## 2. Faithful plain-language reading, clause by clause

The theorem is one equation. Its meaning comes from the definitions it names; each is
quoted and then read.

| Lean clause | what it says, plainly | story counterpart |
|---|---|---|
| `activeOnce` | the frozen journey state after: `alice` claimed the spelling `alice` (request 1, fixture `aliceFixture`), a second competing claim for the same spelling queued (request 2, fixture `otherFixture`), and **request 1 was folded** — so key `42` (`aliceKey`) is now **active** with its certified fixture | **Given**: a registry where `alice` is already active from the first claim, and a second certified claim for `alice` is queued |
| `2` | the request id of the **second, competing** claim — the one that has *not* been folded | **When**: fold exactly that second claim |
| `namingFoldRequest … 2` | attempt to fold request 2: find its certified claim, build the certified Insert action, run the naming transition | **When**: the transition attempts to activate `alice` a second time |
| `= .error "occupied-key"` | the transition **refuses**, and the refusal is not an accident of crash or a generic exception: it is the named registry reason `occupied-key`, decided at fold-time by the occupied-key check (`entry s r.proposal.key).value.isSome → throw "occupied-key"`, `Model.lean:175`) | **Then**: the action is refused with the exact reason `occupied-key`; nothing about `alice` changes (the pre-state is kept on refusal) |

Both directions: clause 1↔Given, clause 2–3↔When, clause 4↔Then. No clause is dropped,
no quantifier weakened (this instance *exhibits* the uniqueness rule; the general rule —
uniqueness decided only at fold — is the profile-level property the frozen demo journey
makes concrete; its quantified sibling for arbitrary queued claims is
`naming_fixture_fields_preserved_on_insert`, a separate obligation with its own row).

## 3. The story, in the same vocabulary

```text
Feature: naming uniqueness is decided at fold
  Vocabulary: spelling→key 42 (`aliceKey`), claim/request, fold, occupied-key
              — every noun bound to a qualified Lean identity in the record.

  Scenario: a competing certified claim for an occupied key is refused
    Given the journey state `activeOnce`:
      | alice  | active  | certified fixture `aliceFixture`  | from folding request 1 |
      | claim 2| queued  | competing claim, fixture `otherFixture`, request id 2 |
    When I fold request 2
    Then the fold is refused with reason exactly "occupied-key"
    And the refusal is the named registry reason, not a crash or generic error
    And the registry state is kept as it was before the fold
```

Concrete example (what makes the quantified rule non-vacuous here): the frozen journey —
`claimedOnce` queues alice; `claimedTwice` queues the rival; `activeOnce = namingFoldState
claimedTwice 1` folds the winner; folding `2` now meets an occupied key and must refuse.

## 4. Actual execution evidence bound to this obligation

| check identity | layer | what ran | result |
|---|---|---|---|
| `evaluation.spike.cg05.story` (tasty-bdd evaluation spike) | real-boundary story exercise | row **CG05** — Insert on an already-present key — through the packaged conformance runner on a real devnet with the compiled blueprint; refusal observed script-attributed; executing negative control (fresh cage, valid insert accepted) proved the refusal discriminates; receipt `receipt-CG05.json` produced | story **passed**; deliberate-failure mode **exited 1** as required (see `../evaluation/README.md`) |

Honest limits of that evidence: CG05 exercises the **generic** occupied-key refusal the
naming theorem rests on (`Model.lean:175`), not the naming-profile wrapper
(`namingFoldRequest`) — the naming production boundary (Aiken naming validators + epic-17
traces) is not yet available. This is a missing **mapping/layer row** in the record, not a
claim of coverage. Lean proofs and simulator replay remain separate evidence and count for
neither layer.

## 5. What is *not* modeled here

- The refusal message's *attribution on chain* (which script/phase emitted it) is observed
  by the CG row runner, not asserted by this theorem — the theorem says only the value
  `.error "occupied-key"`.
- Fee, bond, tip and custody effects around the refusal are out of this theorem's scope
  (they belong to the fold/wire obligations, separate rows).
- The theorem says nothing about claim 1's fate — it is already folded in the Given; its
  effects are covered by `naming_absent_certified_insert_activates`.

## 6. Unresolved interpretation (recorded, not hidden)

- `activeOnce` is a frozen demo journey constant. The theorem quantifies over nothing — it
  is a single-instance execution of the uniqueness rule. Whether the suite needs a
  quantified duplicate-fold property (for arbitrary states and request ids) with its own
  generated cases is a mapping question for the story layer; this row, as stated, is fully
  exhibited by the single instance.
- "Registry state is kept" is read from `namingFoldState`'s definition (`| .error _ => state`)
  — the Lean refusal path keeps the pre-state. The theorem itself does not assert it; the
  story's last `And` renders the adapter's obligation to check it, sourced from the
  definition rather than the theorem. Flagged so a reviewer can strike it if definitions
  are not acceptable story sources.

## 7. Machine anchors

```json
{
  "obligation": "Singular.NamingStatements.naming_occupied_key_refuses_duplicate",
  "statementSha256": "5bb53ab9bde7a263c2119c592c8e21ce45c261b1160902e14d75eb69aa33c86b",
  "vocabulary": {
    "spelling": "String (alice)",
    "key": "Singular.Naming.aliceKey = 42",
    "fold": "Singular.Naming.namingFoldRequest",
    "refusal": "occupied-key (Singular.Model.step, Model.lean:175)"
  },
  "evidence": {
    "checkId": "evaluation.spike.cg05.story",
    "runner": "conformance row CG05 (real devnet + compiled blueprint)",
    "evaluation": "../evaluation/README.md"
  },
  "recordStatus": "unmapped, insufficient-layer — this page is correspondence, not coverage"
}
```
