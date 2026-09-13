# Singular M1 session recovery

Current 2026-09-13T05:35:00Z. Session singular. Restore only from current
RESUME.md and the journals named below. Continue existing worktrees and runtime
roots; do not restart work from founding briefs.

## Milestone desk

Window singular-ms1-onchain-keri, pane %988, cwd
/tmp/projects/singular/milestone-1. Current shell PID 3793575 and Codex child
PID 3798710. Reconstruction command:

    codex --dangerously-bypass-approvals-and-sandbox -C /tmp/projects/singular/milestone-1

After launch, read .milestones/1/resume/ms.md and bind to the current goal:
finish E17 and E18, then stop.

## E17 owner

Window singular-e17-t77-representative-fold, owner pane %913, cwd/runtime
/tmp/projects/singular/milestone-1/epic-17. Family Grok, model grok-4.6,
PID 568965, startTicks 150360890. Exact current launch:

    grok --always-approve -m grok-4.6 --cwd /tmp/projects/singular/milestone-1/epic-17

Resume from .milestones/1/resume/current-owners/epic-17/STATUS.md and
epic-STATUS.md, then read NOTE-095. Existing E17 implementers belong to this
owner:

- %990 Muse/Pi, PID 3808876, cwd /code/singular-e17-issue-77, runtime
  epic-17/ticket-77/commit-owner-2; active policy-binding repair.
- %995 GLM/Pi, PID 72262, cwd /code/singular-e17-issue-81; parked with
  83b359f staging repair awaiting integration.

Do not create replacements or control these implementers from the M1 desk.

## E18 owner

Window singular-e18-consumer-conformance, owner pane %914, cwd/runtime
/tmp/projects/singular/milestone-1/epic-18. Family Codex, model gpt-5.6-sol,
effort high, PID 568968, startTicks 150360894. Exact current launch:

    codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-5.6-sol -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-1/epic-18

Resume from .milestones/1/resume/current-owners/epic-18/STATUS.md and
epic-STATUS.md, then read NOTE-152. Existing E18 implementers belong to this
owner:

- %994 GLM/Pi, PID 4182517, cwd /code/singular-e18-exec with isolated
  /tmp/t80e-rival-witness, runtime epic-18/t80e-execution-evidence; terminal
  partial NOTE-053 handback must resume in the same native session without
  reset or repeat compaction.
- %993 Muse/Pi, PID 4052478, cwd /code/singular-e18-blaster, runtime
  epic-18/t87b-blaster-refinement; formal NOTE-038 candidate under owner
  review, uncommitted until that review.

Do not create replacements or control these implementers from the M1 desk.

## Global recovery fences

Preserve all four existing implementation seats, runtime roots, native
histories, worktrees, raw logs, failed attempts and counters. Do not infer
death from a timeout. Verify PID, startTicks, cwd, family/model and a fresh
durable acknowledgement before any recovery action. No Claude below the
milestone, new worker, auditor, reset, second rival ledger run, merge, push,
release, Scalus, M2 or later epic.
