# t80d source-binding repair — candidate c56c2a5 (NOTE-002 + A-OPEN rulings)

Preserves `b76a42c`, `2aee840` and all prior handoffs as history. Branch
`feat/coverage-classification-inventory`, base `a95f299`, worktree
`/code/singular-e18-inventory`. Local commit only; no merge, no push.
The NOTE-001 structural splitter stands untouched and is not reopened.

## What was unbound (verified before repair)

- Counterexample 1: forged `requireSome_none` signature (`: True`) with
  agreeing clauses and the original digest passed exit 1, findings 0.
- Counterexample 2: `naming-no-delete` → `naming-xx-delete` in source only
  passed exit 1, findings 0 — the cleaned digest is blind to literals.
- Live instance: `escape_error`'s recorded signature drops
  `"completion-only-custody"` (an incomplete, malformed representation, not
  a weaker claim); `namingStepFoldActionEq` drops `"naming-no-delete"` —
  whole-span inspection finds exactly these 2 of 83.

## The repair (new classification artifacts only; scanner identities kept)

- `signature-unbound`: recorded signature text must equal the live
  declaration's text (digest equality then binds content transitively).
- `literal-drift`: per-row `literals` re-extracted from the raw signature
  span (offsets transfer: the scanner's cleaning is length-preserving) and
  compared exactly; 81 rows assert `[]`, 2 assert their literal.
- `definition-drift`: per-row `definitionDigests` for every dependency
  resolving to a `def`/`abbrev`/`structure`/`inductive`; mismatch, vanishing
  or omission fails. Obligation-valued deps stay inventory-bound.
- `base-unbound`: frozen base must resolve in git when git is present;
  without a git venue it is reported unverified, never silently green.
- Schema `singular-classification-v2` (+`independentObligation`); identities,
  texts and NOTE-001 clauses byte-identical (verified mechanically).

## A-OPEN rulings applied

- Seven algebraic rows (`countP_filter_le` → `list-lemma`; six Except
  identities → `monad-plumbing`) carry independent obligations decided from
  the statement — never from use counts, never retain-or-remove — each with
  its limitation and one explicitly unresolved applicability item (real API /
  composed operation unbound; no ledger action invented).
- `escape_error` needs no decision: `duplicate-statement` of
  `Statements.escape_refused` (same inputs, identical conclusion with
  restored literal, both `rfl`-proved), both identities kept, source plus
  definition (`step`, `State`) bindings, honest separate debt, no credit.
- Open 8 → 0; 18 unresolved follow-ups (11 simp confirmations + 7
  applicability) listed loudly in CLI and report, owning future work.

## Actual discriminator results (fresh CLI processes)

- Baseline: exit 0 COMPLETE, findings 0, open 0, unresolved 18.
- Forged `requireSome_none` (`: True`, agreeing clauses, original digest):
  exit 3, exactly `signature-unbound` ×1.
- Source-only `naming-no-delete` → `naming-xx-delete`: exit 3, exactly
  `literal-drift` ×1 (digests identical — invisible to all old bindings).
- `consume` body `!=` → `==` in an isolated tree copy: exit 3, exactly
  `definition-drift` ×8 (the recorded consume dependents), zero other codes.
- Stripped-literal fixtures for both literal rows: exit 3 `literal-drift`.
- Tampered base: `base-unbound`. Omitted def binding: `definition-drift`.

## Verification

- `PYTHONPATH=$PWD python3 -m unittest discover -s tests` → **101 OK**
  (61 pre-existing + 40 slice tests); pre-existing suite untouched and green.
- `singular_coverage` inventory `192 = 109 + 83`, ratchet PASS — unchanged.
- `git diff 2aee840..HEAD` touches only the 8 slice paths; worktree never
  mutated for tests (temp copies only).
- Judgment on dependencies, categories and follow-ups remains the owner's;
  existence checks and rationale length never stood in for it.
