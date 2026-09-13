---
role: orchestrator
repo: lambdasistemi/singular
branch: main
worktree: /tmp/projects/singular/milestone-1/epic-15/checkout
epic: lambdasistemi/singular#15
lane: lambdasistemi/singular#20
ticket: lambdasistemi/singular#20
pr: lambdasistemi/singular#27
layout: quadrant
panes: top-left=%848, top-right=%849, bottom-left=none, bottom-right=%852
expected_window_name: singular-e15-t20-naming-simulator
stage: implementing
goal: Accepted executable naming model/contracts/scenarios plus a playable, independently verified docs simulator release for M1 (epic #15, serial children #20-#25).
last_action: First-write checkpoint RESOLVED - it fired, the boolean was false, the T.O. sent one mechanism-level correction and the first Lean write landed 17:34:05Z (lean/Singular/Naming.lean + NamingStatements.lean, Singular.lean modified). Monitor blind spot closed: watch brqjhukdv now also detects ARTIFACT STAGNATION, not just journal silence. Q-002 filed and answered by A-003 (same-family recovery only, on real stop evidence).
blockers: none blocking. Open with parent: (a) the next release PR needs FRESH authorization - A-001 covered only its frozen candidate; (b) the publication path (.#publish-docs, refs/tags/v* trigger) is still UNPROVEN because the tag is held; (c) documentation-file ownership between #20 and the standalone docs-links lane (README.md, README.speech.json, docs/simulation.md) must be coordinated through parent before simultaneous edits.
updated_at: 2026-09-09T17:44:00Z
---

## Resume record (resurrection-grade)

- **My launch**, replay exactly: `/run/current-system/sw/bin/claude --dangerously-skip-permissions --model 'claude-opus-5' --effort high` with cwd `/tmp/projects/singular/milestone-1/epic-15`, interactive on /dev/tty. Standard context pin, **no `[1m]`**.
- **My runtime root**: `/tmp/projects/singular/milestone-1/epic-15` (brief.md, STATUS.md, questions/, answers/, inbox/, handoffs/, .orch/, checkout/).
- **Parent**: milestone owner pane %844, session `mpfs-onchain-ms2`, runtime `/tmp/projects/singular/milestone-1`. Parent consumes my durable STATUS; I do not send routine pointers into its active pane.
- **Operator-owned, never touched**: `/code/singular` (read-only), issue #10.
- **Durable state**: `.orch/epic-map.md` is the authority for the graph, staffing, contracts, invariants and the 12 frozen application rulings. Re-read it before any dispatch or acceptance.
- **Next action**: supervise ticket-20 through one long event wait per turn on `/tmp/projects/singular/milestone-1/epic-15/ticket-20/STATUS.md`. Verify each ticket-level claim once, at its transition, with a one-line check (draft PR identity, pushed SHA exists remotely, CI green on that exact head, preview candidate.txt SHA). Never read its commit owner or auditor journals, panes or artifacts.
- **Active child**: ticket-20, grok/grok-4.6, pane %849, pid 556714, runtime `/tmp/projects/singular/milestone-1/epic-15/ticket-20`, relaunch with `/run/current-system/sw/bin/grok --always-approve -m grok-4.6`.

## Layout intent

Epic quadrant. Top-left me (%848). Top-right the single active grok ticket owner. The bottom
row belongs to that ticket owner: glm commit owner bottom-left, and a bottom-right work slot
holding a fresh sol auditor only while a candidate is under audit. I never create, read, wake,
correct or retire the bottom row — that is the ticket owner's control surface, not mine.

## Release state (as of 2026-09-09T16:47Z)

- `origin/main` = **`9e8d6b57a6e538719b8f782b521bd456301df71e`** (was `58eaaba`). `version.txt` `0.1.0`,
  `.release-please-manifest.json` `{".":"0.1.0"}`.
- **No tags, no releases** on the remote. `v0.1.0` is deliberately HELD, not lost — see
  `handoffs/day-zero-release.md`. Do not create it without fresh parent authorization.
- The next release PR release-please opens after the docs-link fix is a **new, unauthorized**
  candidate. A-001 authorized only its frozen one.

## Standing boundaries added by NOTE-003

- README/docs **link destinations**, speech freshness and the link check belong to a **standalone
  parent-owned lane**, not to epic #15 and not to #20. Do not adopt that work and do not create a
  child for it.
- Epic #15 and #20 keep **model / engine / corpus / scenario** ownership.
- Coordinate shared documentation-file edits through parent **before** they happen.

## Standing contingency for the grok ticket-owner seat (A-003, 2026-09-09)

Applies only to an **actually stopped** seat. A timeout, a quiet journal, a UI quota percentage
or a transient provider error is **not** proof of stopping and authorizes nothing. The 8% UI
figure observed at 17:34Z is not a capacity condition.

1. **Capacity available → same family only.** Relaunch `grok --always-approve -m grok-4.6`, same
   ownership scope. First classify the old seat and its in-flight commands from evidence,
   preserve its worktree and runtime artifacts, and never allow two live ticket owners.
   Successor gets a **fresh runtime root** and a recovery brief binding: predecessor identity,
   accepted base, branch/PR/head, dirty tree, frozen mandate + gate hashes, open questions,
   owned commands, and the **cumulative** campaign ledger. Require its own new `START`; never
   fabricate one. Preserve the predecessor in place with its terminal disposition, or the exact
   abrupt-exit evidence if it could not write a handoff.
2. **Quota actually exhausted → preserve and escalate.** Report the provider error and reset
   information plus a mechanical handoff; route recovery through parent. Do **not** loop
   relaunches, do **not** kill healthy GLM or build commands because their owner is gone, do
   **not** substitute Codex or any other family.

**Counters carry forward.** Replacing a process creates no new candidate, audit or build budget.
