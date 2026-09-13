# A-006 candidate result — executable rejected-fold refinement

Seat `%993`, worktree `/code/singular-e18-blaster` @
`970b15917a76982ad6db2b1c8efaaaa5f5d15969`. Design input: NOTE-029-
corrected R2 packet. Fences kept: `lean/`, production validators,
consumer implementation, shared coverage schema byte-unchanged
(verified `git status`: no such paths modified); no ledger campaign,
migration, adoption, push/merge/release. Register/C5 gates not rerun
(files byte-untouched). Stop uncommitted (all files below new or
lane-modified, uncommitted for owner review).

## Exact files (owned `blaster/abstract/` + lane receipts)

| file | lines | bytes | sha16 |
|---|---|---|---|
| `RejectedFold.lean` (candidate) | 340 | 15472 | `7790b0e5fcdc273e` |
| `RejectedFoldGate.lean` (battery) | 405 | 15771 | `f06ea7fc1157b098` |
| `RejectedFoldMutant.lean` (retention mutant) | 114 | 5767 | `0a8cdad09bae6898` |
| `RejectedFoldMutantPos.lean` (positive target) | 20 | 570 | `d5b3f0c541fe02f2` |
| `RejectedFoldMutantGate.lean` (kill target) | 30 | 1139 | `8d4f2dbd1af4cba4` |
| `run-candidate.sh` (recipe, green+mutant modes) | 88 | 3958 | `d269861b6b69ccf6` |
| lane `handoffs/a006-mutant-receipt.txt` (kill receipt) | — | 2607 | — |
| `blaster/.gitignore` (+`.work-candidate/`, build scratch) | — | — | — |

`git diff --check`: exit 0 (clean).

## Commands/exits (true)

- TDD RED (accepted, Lean-level): `lake build RejectedFoldGate` →
  `error: RejectedFoldGate.lean: bad import 'RejectedFold'`, exit 1.
  (Earlier cp-cannot-stat relabeled setup-only, no credit.)
- GREEN: `bash blaster/abstract/run-candidate.sh` → 5 jobs,
  `Build completed successfully`, exit 0.
- MUTANT KILL: `bash blaster/abstract/run-candidate.sh --mutant` →
  stage exits module=0 positive=0 kill-gate=1, wrapper exit 0
  (verified: module builds, positive control builds, kill fails ONLY
  on the retained row `[8,7]` vs `[7]` with removed/refunds
  matching; malformed → 2, survival → 1).
- GREEN re-verified after mutant work: exit 0.

## Pre/post/result witnesses (executed)

One batch context `ctxMain` ([5000, 6000), state times 2000/1000)
judges every run; endpoint convention lower-inclusive/upper-exclusive/
none=+∞ with Aiken bound-closure correspondence as stated debt.
Per-item ranges do not exist (substitution unrepresentable).

- All-rejected `[i8]/[.rejected]`: removed `[8]`, logical `[]`,
  post ids `[7]`, refunds `[{77, 1999500}]`, custody `[]`, used∋8;
  full post-state equals pre except row 8 removed (entries,
  applications, approvals, config, funding, custody, used all
  byte-identical guards); id 8 consumed-in-used pre and post;
  immediate replay on post-state refuses `request-unavailable`
  (candidate-scope no-replay).
- Mixed `[i7,i8]/[.processed,.rejected]`: logical `[{rep0,+1}]`,
  removed `[7,8]`, post ids `[]`.
- Zero-net `[i7,i9]` (reachable incarnation-2 fixture, scoped
  proposal+approval, stale rep42): logical `[{rep0,+1},{rep0,-1}]`,
  removed `[7,9]`, `netSumsZero` true. Vacuous `[]` zero-net labeled
  separately (own guard).
- Custody Case T `[i10]`: removed `[10]`, logical `[]`, refunds
  `[{80,2999500}]`, custody `[10]` unchanged.
- DIR-A: candidate mixed logical == model `foldItems` logical (true).
- DIR-B: model SPAN-OK success + extras accepted with same effects.
- 24 refusal controls, each exact reason: empty, count×2, dup,
  invalid-range, funding-dup, missing, missing-used-id,
  funding-unbound, underfunded, reject-timing, process-timing,
  consumer, recipient, underpayment, conservation×3
  (fee/surplus-output/unbalanced-input), surplus-refund,
  refund-missing, custody dup/unassociated/unbound/spent. reject-timing,
  process-timing, consumer, recipient, underpayment, conservation×3
  (fee/surplus-output/unbalanced-input), surplus-refund,
  refund-missing, custody dup/unassociated/unbound/spent.
  Used-membership enforced at entry (present items); `used` monotone
  at exit (`finish` checks pre⊆post — rejected keeps, processed
  extends per accepted `foldOne` prepending `outputId`).

## Theorem/check inventory

- Proved: `empty_batch_refuses` (rfl), `count_mismatch_refuses`
  (`dif_neg`) — structural refusal lemmas.
- Executable checks: all witnesses/controls above as `#guard_msgs`.
- Retained mutant: retention copy (pays+reports, never removes);
  kill receipt `handoffs/a006-mutant-receipt.txt` (kill ONLY on
  retained row `[8,7]` vs `[7]`; removed/refunds match; isOk passes).

## Remaining obligations (open, honest)

Quantified scope (finite instances only); realizability D1-D6
(pin value, current six-field CEK, ledger, authentic custody setup,
mint-policy execution, hash binding); KERI adapter/compositor
instantiations (parametric contract has E17 only); concrete-context
six-field execution; whole-proof `fold_iff` correspondence (C2
disposition arm unlanded); admission discipline populating
funding/custody registries; used-history completeness; cross-batch
monotonicity; Case-T pre-state admission path; burn/completion as a
separate effect; Aiken bound/infinity correspondence for the integer
range abstraction. No invariant credit, epic acceptance, or release
claimed. Accepted register repair discharges none of this.
