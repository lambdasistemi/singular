# Singular M1 ledger — finish M1

Updated 2026-09-15T14:39:58Z by the milestone desk (pane %988). OUTCOME TEST MET 2026-09-15; #102 and #18 closed; v0.6.1 released; milestone object open only for the operator's demo epic #141 pending placement.
https://github.com/lambdasistemi/singular/milestone/1 (3 open: #102, #108, #18).
Public map: https://github.com/lambdasistemi/singular/wiki/Milestone-1
(wiki commit 6b4e7056ec4d1b79c6a845b8c8ac43a4a3441035, register sha256
5a1a3a4328faeaa2…). Desk runtime root /tmp/projects/singular/milestone-1
(journal STATUS.md, prior ledger RESUME.md).

## Outcome test

From a downloaded Singular release archive, against a preprod node, a
cardano-keri integrator registers a key, resolves it, recovers control,
retires it and observes permanent Over. Every runner exits 0 from the archive
with no environment override, attached to one persistent preprod deployment.
When that run is recorded in docs/preprod.md and released, M1 closes.

## Where we are

- OUTCOME MET (2026-09-15 15:46Z): v0.6.1 (tag 41861a66) published; downloaded archive verifies and its deployment verifier agrees with docs/preprod.json 14/14 on the preprod node; register/recovery/retirement-to-Over ran on preprod (registry bb41081f…, representative policy 64adbd9c…, 10-min window) from the released code path. #102, #18 closed. Preprod window handed to milestone 4 (handoffs/m4-preprod-window.md, acked by %1182).
- Audit rule in force since 2026-09-15: every PR audited blind before merge (Grok lane t-audit %1525 still gates #146). Retroactive audits and specs of the five 2026-09-14 merges: done.
- Open under this desk: #146 (second asset disables recover/retire; Codex lane %1566, milestone M1 assurance); PR #105 presentation (parked, operator-interactive).
- Operator filed a live-demo epic #141 (+#133-#140, #142, #145) into the M1 milestone today; placement pending the operator; not staffed.

## State table

| item | state | owner / pane | next |
|---|---|---|---|
| M1 outcome (preprod run from the released artifact) | delivered | desk | close the GitHub milestone once the demo epic's placement is ruled |
| #146 second-asset lockout | in-progress | Codex lane t146-second-asset %1566 | spec, fix, audited PR, merge (no preprod redeploy in-ticket) |
| audit gate | standing | Grok lane t-audit %1525 | gate #146; then retire |
| demo epic #141 | planned, unstaffed | operator | placement, then one lane per ticket |
| PR #105 presentation | parked | Codex %1102 | operator's call |

## Priority and reasons

1. The close lane's runner fix, then the journeys: the product outcome.
2. The live audit gate on every close-lane PR (operator revert 2026-09-15).
3. Retroactive audits in the auditor's idle time; findings become fix tickets, none blocks the close unless it breaks a journey.
4. Assurance (#87 #80 #92) is milestone 2 "M1 assurance"; #104/#107 milestone 4; #97 milestone 3. Codex is out of credits until 2026-09-19: milestone 4's lanes are the project owner's problem, notified.

## Parked decisions

- Release tagging: release-please still does not push the tag; 0.4.0 and 0.5.0
  tags were pushed by hand (A-013). The close lane hand-tags if needed; a
  chore to make the pipeline tag is to be filed after the close (not blocking).
- Ceremony-chain retirement question (retrospective 2026-09-13) is with the
  operator.

## Budget

Claude weekly 46% at 12:00Z; guard tightens at 54%, pauses Claude worker
panes at 57% (budget-warden, one monitor). No Claude seat is added.

## Close checklist (desk)

After the lane reports COMPLETE: read docs/preprod.md and the release run,
run the outcome audit against the test above (not by counting issues), close
the GitHub milestone, retire the milestone row in
/code/llm-settings/shared/milestones.md, final wiki and ledger sweep,
MILESTONE-COMPLETE on STATUS.md, retire the lane panes.
