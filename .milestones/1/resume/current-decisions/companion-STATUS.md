# t89 status — consumer companion for the ownerless schema (preparation cut)

## NOTE-001 acknowledged [POINTER-1789208203-3216251] — context is FRESH, not REUSED

- Identity recorded: genuinely new process in a new pane, nothing inherited.
  Not restarting. Brief label corrected in my working understanding.
- `t70b` is read-only history: no verdict, writable state, or context
  acceptance transfers. I read its root only as history, write nothing there.
- Old six-field fixtures = **historical defect evidence** of prior
  implementation behavior, never an accepted owner-bearing design. I will NOT
  port them forward and adjust them: the four-field codec and
  zero-state-parameter tests are **derived fresh from committed `f3a68b1`
  source and an actual build**.

## acknowledged brief [POINTER-1789208061-3194502]

- Read `brief.md` in full; read both handoffs in full
  (`handoffs/ownerless-integration-cut.md`, epic-17
  `ownerless-schema-handoff-to-18.md`).
- Understood: positional decoder risk (owner/stake_script removed from HEAD of
  generic `State` — mis-parse, not field loss); state validator parameterless
  (applied identity = unapplied identity; `previousPolicies=[]` derivation now
  wrong); request validator unchanged at 2 params; SDK `Types.hs` already
  aligned; `RequestDatum` Constr 0 / `StateDatum` Constr 1 unchanged.
- Provisional antecedent `f3a68b1` (tree `3cac539b1db…`) — prepare against,
  credit nothing. No inherited GREEN. No edits to `onchain/`, `naming-onchain/`,
  `offchain/`. Consumer-only delta in `/code/singular-e18-companion` on
  `feat/ownerless-consumer-companion` from base `597b010`; does not merge alone;
  no conformance credit.
- Loading `code-the-design` + `worktrees`. Next: derive the complete affected
  set from the frozen source (not just CS06/Run/Mirror leads), then prepare
  decoders/builders/parameter application + tests/docs.
2026-09-12T10:18:19Z  START  pane=%984 seat=pi --provider zai --model glm-5.3-flash --thinking max --approve context=FRESH worktree=/code/singular-e18-companion branch=feat/ownerless-consumer-companion base=597b010 provisional-input=f3a68b1bcd63119f8db79548a7d15926bf408856
2026-09-12T10:18:28Z  NOTE  NOTE-001 read: context=FRESH confirmed, t70b read-only, four-field codec + zero-param tests derived fresh from f3a68b1 source+build, not ported
2026-09-12T10:18:28Z  NOTE  NOTE-002 read: worker-protocol loaded, tagged events from here on
