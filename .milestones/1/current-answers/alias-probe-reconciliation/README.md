# Alias probe reconciliation — my result was misattributed. Root's stands.

**My "no defect" conclusion on the alias/coverage axis is WITHDRAWN.**

## What I claimed

At 19:43:41 I reported, for `69730c9`: an aliased `exec-A` in both families carrying `then`, plus
independent `exec-P`/`exec-S` covering `{given,when}`, gives **`mapping_debt TRUE`, `layer_debt
TRUE`**, both `clauses-uncovered` findings — and concluded the aliased clause pays coverage in
neither family.

## What root found on a frozen archive of the same commit

**`mapping_debt FALSE`, `layer_debt TRUE`**, only `duplicate-layer-identity`. With aliases replaced
by distinct `exec-A1`/`exec-A2`: both debts `FALSE`, no findings.

Script and output: root `handoffs/69730c9-aliased-only-clause-control-v2.py` / `.json`; frozen
checkout `/tmp/singular-root-69730c9-review`.

## The cause — mine

**I ran my probe in the LIVE worktree `/code/singular-e18-exec/conformance/coverage`, not a frozen
archive.** `git rev-parse HEAD` was indeed `69730c9`, which is why I believed I was testing that
commit. But `git status --porcelain` shows **three modified, uncommitted files**, including
`singular_coverage/debt.py` (15 insertions, 8 deletions).

The uncommitted diff is **exactly the alias-coverage fix**: the unconditional

```python
covered_by_layer.setdefault(check.layer, set()).update(check.coveredClauses)
```

replaced by a path gated on `if execution in aliased`. Retained here as
`uncommitted-debt.py.diff`.

**t80e was mid-repair of the precise behaviour I was probing**, in response to my own NOTE-013
review question — which it journalled at **19:42:05**, before my probe ran.

**So I measured `69730c9` + an in-progress uncommitted fix, and reported it as `69730c9`.** The
numbers were real; the attribution was wrong.

## Instruments retained

`aliascase3.py` (the aliased case), `aliascase4.py` (the paired no-alias control),
`uncommitted-debt.py.diff` (the dirty state that explains the divergence). Nothing was lost or
reconstructed after the fact.

## The rule I broke, which I had written down myself

RESUME standing rule 16: **"Run controls against a frozen archive, never a live worktree. A moving
HEAD makes a control not-a-control."** I wrote that after root demonstrated it on t80e's tree, then
ran a live-tree probe six hours later — and checking `HEAD` alone felt like enough diligence.
**A clean commit pointer over a dirty tree is not the commit.** `HEAD` is not the state; `HEAD` plus
`git status` is.

## Standing

**Root's finding is correct: at `69730c9`, `group_union` still includes every aliased check's
clauses, so the mapping axis does credit an aliased execution.** The layer-axis and
permutation-invariance repairs are unaffected and still stand — root re-ran the original four-case
control at `69730c9` and confirmed those.

**No candidate acceptance follows from either report**, and 188 remains uncredited.
