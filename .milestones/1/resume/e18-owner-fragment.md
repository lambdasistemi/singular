# Epic 18 — resurrection record

Rewritten 2026-09-12T10:35Z. **This file describes the live state. It resurrects nobody.**
The previous version claimed t70 at `%938` and t80c at `%917` as live; both are retired. Root
preserves the prior file separately.

## Identity

Epic owner for `lambdasistemi/singular#18` (consumer conformance and integrated release).
Runtime root `/tmp/projects/singular/milestone-1/epic-18`, pane `%914`, reporting to the milestone
owner at `%844` in session `mpfs-onchain-ms2`. Opus, standard context.

## Live roster

| worker | seat | pane | worktree / branch | owns |
|---|---|---|---|---|
| `t87-blaster-driver` | Muse | `%982` | `/code/singular-e18-blaster` · `feat/blaster-compiled-invariants` | #87 compiled-invariant harness, `blaster/` subtree |
| `t89-ownerless-companion` | GLM | `%984` | `/code/singular-e18-companion` · `feat/ownerless-consumer-companion` | consumer codecs, builders, parameter application, their tests/docs |
| `t80d-classification-inventory` | Muse | `%986` | `/code/singular-e18-inventory` · `feat/coverage-classification-inventory` | #80 classification inventory for the 83 unclassified, under `conformance/coverage/` |

Monitor: persistent event wait `bj2d3mo3u` over `t87` + `t89` — **extend it to `t80d`.**

At most four simultaneous implementation slots across the milestone: #77 (epic 17), plus my three.

## Retired — never relaunch

`t63`, `t68`, `t69`, `t70-generic-rows`, `t70b-generic-rows-finish`, `t80-coverage-ratchet`,
`t80b-coverage-stories`, `t80c-release-gate`, `t81-fork-investigation`. All listed in
`.retired-workers`, roots preserved in place. **t80c's verified gate is unchanged and read-only.**

## Open work

| id | state |
|---|---|
| PR 88 (#70) | **MERGED** `6fd02c7` at 10:36:19Z; issue #70 CLOSED. Bounded execution/reporting delivery only. |
| PR 86 (#80) | **merged** `a95f299`. Publication boundary prepared and **inert** — `if: false`, absent from `publish.needs`. |
| #80 | **open.** Activation debt + 83 unclassified declarations (t80d) + #87 compiled-debt integration. |
| #87 | **open.** M1 blocker. I-1 `COULD-NOT-EVALUATE`; I-2 Rejected-scope done, Update span blocked on `Blake2b_256`. |
| #71 | queued (CK/CL rows). |

## Settled rulings — do not reopen

- **No registry owner whatsoever**, including latent ownership, transfer, owner-authorised
  termination or migration. CG13 resolved-by-ruling (defect evidence); CG14/CG15/CG16/CG17
  superseded, observations preserved, claims withdrawn.
- **A-005 sequencing:** prepare and verify now, activate at the integrated acceptance commit. Strict
  debt blocks the *integrated product release*; ordinary docs publication stays independent.
- Receipt-overwrite repair and CI expected-debt adjudication: **verified fixed, settled unless the
  code changes.**
- Publication-boundary input binding and mutant adjudication: **verified, settled.**
- **PV10 + V3 → `defaultFunSemanticsVariantC`** — by the protocol mapping (`vanRossemPV`=11), not
  because the pin lacks E. This overrides the skill's era table for this lane.

## Frozen inputs

- Epic 17 antecedent `f3a68b1bcd63119f8db79548a7d15926bf408856`, tree `3cac539b…` — **provisional,
  not accepted.** Four-field `State`: `root`, `tip`, `process_time`, `retract_time`; `owner` and
  `stake_script` removed from the **head** of the record, so a positional decoder **mis-parses**.
  State validator parameterless.
- Blaster pins: Lean-blaster `01240b37…`, PlutusCoreBlaster `17cee18a…` (no `Blake2b_256`).
  Candidate support path `ed3126b6…` — source-inspected only, composition unverified.
- Board: **42 rows**, 41 owned, 14 executed, 5 bound-elsewhere, 22 uncovered, 1 out-of-scope.
- Coverage denominator: **192** declarations, 109 public, 83 unclassified. No exclusions.

## Standing rules learned here

1. Verify a command exists before publishing it.
2. A control that survives removal of what it certifies is decoration.
3. An error is not the expected negative — a mutant must succeed at everything except the thing
   under test.
4. An empty grep is not proof of absence; a failed lookup is not proof of absence.
5. Authority is a role, not a vocabulary — `State.stake_script` was an owner hook that never said
   "owner".
6. Check the fence **after** a merge moves the base, with `merge-base`, never bare `origin/main`.
7. A `pull_request` run takes the **workflow from the base** and the **flake from the head** — a new
   required app on main breaks open PRs as a missing-executable error.
8. Two people agreeing about a misreading is not a finding.
9. Coverage is not inherited across a wire-format change.
10. Changing a row's applicability earns no execution credit.
11. `HANDOFF` is not a terminal tag. `COMPLETE` with a handoff is, including at capacity.
12. Every brief lists `worker-protocol`, or the seat journals prose nobody can wait on.
13. `send-pointer` needs pane width — check geometry before diagnosing a dead seat.
14. Scan whole declaration spans, never a fixed line window. Four counts of mine came in short
    because the window became the answer (171 vs 192; 1 vs 2 literal-stripped rows).
15. Do not manufacture a user decision. If two declarations agree exactly, that is metadata to
    record, not a design choice to escalate.
