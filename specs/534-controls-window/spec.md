# Refusal controls: a registry window that survives a slow runner

The Demo 1 ordinary CLI refusal controls create a throwaway registry with a
45 second processing window. A slow runner turned one healthy insertion into a
`partial` outcome. This page records the cause, the fix and how it is proved.

## Story

As a developer merging to `main`, I see the job "Demo 1 ordinary CLI refusal
controls" fail only for real defects. A slow runner no longer stops step 135
(`insert --fold` after the lock is released) `partial` because the fold build
had only 15 seconds inside a 45 second registry window.

## What is established

Issue 534 and its investigation (hosted run 37946202031, job 113873074542,
commit 75f0708f) establish the cause. The command line tool signs a fold only
while the host clock stays 30 seconds clear of the request's processing
deadline (`foldMarginMs` in `offchain/cli/src/Singular/CLI/FoldRules.hs`),
checked before and again after the build. With a 45 second window that leaves 15
seconds from the booking's submission time to the end of the fold build. Step 135
used 15.52 seconds, so the tool refused to sign and the combined `insert --fold`
reported `partial`. The lock was not involved, the tree was identical to the
green pull-request run, and the product rule did what it says.

Reproduction on the investigation's side: the whole story with the client slowed
only for step 135 gave `partial` with the hosted wording; the same single
command with twelve busy processes on one core gave three `partial` of four at
a 45 second window and four `success` of four at a 120 second window.

## Requirements

- `controls-registry-window-clears-a-slow-build`: the throwaway registry the
  controls story creates (and its preview) has a 120 000 millisecond processing
  window and an unchanged 15 000 millisecond retract window. The budget from a
  booking's submission to the post-build clock becomes 90 seconds.
- `window-readback-agrees`: the check that follows `registry create` reads the
  windows back from the command's own output and fails the step when they differ
  from the windows the story asked for. It agrees with the new values and is
  not weakened.
- `one-definition-of-the-window`: the arguments passed to `registry create` and
  `registry create --preview`, and the values the readback expects, come from
  one definition, so a later change cannot leave them disagreeing.
- `margin-rule-untouched`: no product code changes and the 30 second fold margin
  stays as it is. Only `conformance/app-cli` and this folder change.
- `no-clause-weakened`: the controls job's clauses keep their statements. After
  the change the clause counts equal the base's, with nothing newly retired,
  waived or uncovered.

## The window choice and its measured cost

The constant is shared by five call sites: the controls story's create, the
preview that precedes it, and three further seed-creating calls. Two choices were open: widen
the shared constant, or give only the controls story a longer window.

The one cost of a longer processing window is in the reclaim step, which waits
for the processing window to end before it retracts (`Backend.hs`, the wait
before `Reclaim`). A reclaim after a 45 second window costs 45 seconds; after a
120 second window, 120 seconds: 75 seconds more per reclaim.

The census of which stories reclaim: the only `Reclaim` action is inside
`refusedInsertion`, which only `permanentStory` runs (the attach take, against a
registry its own script creates with 90 second and 30 second windows). The
controls story contains no reclaim: its run on the base left 0 reclaim receipts
in 139. No story that creates its registry with the shared constant reclaims, so
the added wall time is 0 seconds, and the shared constant is widened. A
controls-only window would thread a parameter through five call sites to save a
cost that is zero.

Why 120 seconds: 30 seconds of margin plus the worst observed build use (15.5
seconds, step 135 on the failing run; 13.5 seconds at the next-worst healthy
step) leaves 90 seconds of budget, almost six times the worst use, and matches
the window the cross-wallet recovery harness moved to for the same reason.

## Verification

Each row is an existing command, not a new instrument, except the load rows,
which the desk named.

- The investigation's slowed-client run of the check script on the base: step
  135 is `partial` with `ClockWithinMargin`. The same run after the change:
  step 135 is `success`, and the R299-05 rows hold.
- `nix run --quiet .#demo1-cli-controls` on the final head, with the same clause
  counts as the base.
- The Haskell format and lint checks for the conformance package, the
  conformance unit suite, and `just ci` once at the end.
- Hosted continuous integration on the exact pushed head.

## Limits

- The 15.5 second use is one hosted observation. Why that runner was slow is
  not established; the fix gives headroom, not a cause.
- Other jobs on a 45 second window (the create race script) are not examined
  here and are not changed.
- Issue 517 is separate and untouched.
- `specs/401-create-windows` still says CI uses a 45 second window; it records
  the decision of its own date and is outside this ticket's fence.
- `onchain-release/DEMO1.md` (lines 353 to 355) says CI creates its throwaway
  registry with 45 000 and 15 000 milliseconds. It already disagrees with the
  journey (120 000 and 30 000) and the attach take (90 000 and 30 000), and is
  outside this ticket's fence; it is reported, not changed.
