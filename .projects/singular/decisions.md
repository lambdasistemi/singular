# Product decisions

## 2026-10-08: two-edge M1 and successor milestones

Authority: direct operator discussion: KERI close/reopen is application-level; KERI does not consume the terminal witness in its Lean model; the remaining edges are Demo1's goal; restructure the project and move the next edges into later milestones; preserve the broader Lean/on-chain work on a permanent branch, organized as an epic.

Decision: M1 contains insertActive/updateTerminal and the applicable request exits/refunds, supported through existing Demo1/open-datum. M2 contains witnessTerminal/insertAbsent/updateActive/deleteAbsent/deleteActive. Reorder existing programmable naming plus escrow to M3; retain tooling/refactoring as M4 and assurance as a cross-release track. See ledger.md for stable GitHub IDs. This supersedes historical all-seven-edge and naming/escrow M1 completion scope, the old M2 naming title, and the previous possible-factoring interpretation of M2. It preserves past achievements and unmet requirements.

[Epic #507](https://github.com/lambdasistemi/singular/issues/507) is filed, with serial #504 → #505 → #506. This is planning/metadata authority only; no model/source changes, branch preservation execution, staff launch, paused-lane resume, merge, release or transaction is inferred. Existing candidate contracts require owner amendments before affected acceptance.

The earlier scope-only ruling is retained at [rulings/20261008-m1-two-edge-contract.md](rulings/20261008-m1-two-edge-contract.md). Its statement that M2 was not yet founded is superseded by the present explicit restructuring request: M2 is now a planned milestone, not a staffed execution campaign.

The initial project interpretation that KERI close/reopen required Singular edges was wrong and withdrawn. No hold based solely on that interpretation remains. Compiled bounded admission and consumer correspondence remain real evidence obligations. Actual integration versus consumer conformance was decided on the afternoon of 8 October (below).

## 2026-10-08 afternoon: M1 closing criterion and identity change

Authority: operator rulings recorded by the M1 desk (milestone-1 STATUS lines 2490 to 2493), consumed by the project desk.

- M1 closes when the open-datum demos are complete: Demo 1 on preprod against the restricted two-edge contract. KERI's own integration is not an M1 closing condition. Outcome test: cardano-keri's required features work against that contract; payload updates are application spends. This settles the earlier open question (actual integration versus consumer conformance).
- Registries from earlier releases are abandoned when #505 changes the contract identities. The #480 obligation to recognise earlier deployments is withdrawn.
- #498 protected rejection is an M1 closing condition, landing after the #505 cut (a second identity change is accepted). Protected-deposit enforcement beyond #498 is not an M1 condition. #495 release is gated on #505 merge.

Earlier snapshots and decisions are retained under [history/pre-restructure-20261008](history/pre-restructure-20261008/ledger.md). Historical rosters, launch authorizations and release claims must be revalidated before reuse.
