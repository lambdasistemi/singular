# The fixed two-edge contract and its current scope

As a reviewer, I need to distinguish a new permanent registry from an earlier
deployment and understand which behavior this candidate establishes.

The operator's 8 October 2026 ruling selects `insertActive` and
`updateTerminal` for the first milestone. `witnessTerminal`, `insertAbsent`, `updateActive`,
`deleteAbsent` and `deleteActive` are excluded. Application payload updates and
KERI close/reopen are application operations. The admission set of a deployed
script remains fixed; no mutable configuration can enable another registry edge.

The later ruling delivered as `NOTE-001-old-registries-abandoned` explicitly
supersedes the earlier old-instance compatibility requirement: registries made
by earlier releases, including old Demo1 registries, are abandoned by the new
release. There is no migration or old deployed recognition path. The new CLI
refuses wrong or unknown script identities. Preserved broader source, artifacts
and remote history remain evidence for their own contracts, not the restricted first milestone.

The first milestone's finish line is KERI feature support, for which the open-datum application
is sufficient. The later `NOTE-002` corrects the milestone ordering: #498
protected rejection is a first-milestone closing condition, landing after #505
through #495 with its own identity change. This carve does not close that milestone and must not
include #495 or PR508. Protected deposit is outside this carve's closing
conditions. Current valid model behavior, deposits and refunds must still be
preserved. The parent reports the eventual #505 merge to release #495.

Sources read in full: the bounded permanent contract answer
`A-20261008-keri-bounded-permanent-contract.md`, the carve-505 brief,
`NOTE-001-old-registries-abandoned.md`, and the parent ruling
`NOTE-M1-20261008-old-registries-abandoned.md`, including its addendum.
The subsequent `NOTE-002-protected-rejection-after-carve.md` and parent
`NOTE-M1-20261008-correction-498-is-m1.md` were also read in full.
The subsequent `NOTE-003-excluded-redeemers-and-docs.md` clarifies that shared
representations may remain: defining or encoding a redeemer does not support
its action. The five excluded actions must fail against the permanent contract,
including independently constructed requests, alternate admission paths and
mixed batches. Refusal tests pass by observing that failure, with setup and
unreachable-state limits retained. That clarification did not require source deletion. NOTE-005 subsequently supersedes it with an explicit source-removal authorization.

These are operator scope decisions, not evidence of KERI integration, ledger
acceptance, merge or release. The parent owns acceptance and publication.

The subsequent NOTE-005, "ok, now, big delete", authorizes one active two-edge
model, implementation and test surface, removing obsolete success implementations
and their direct support. The seven historical edge tags retain their original
numbers; five are represented only to prove refusal. Recovery branch
`preserve/m2/pre-m1-source-removal` was remotely verified at `a098408e` before
removal and remains untouched. Every prior a098 receipt is historical for the
revised candidate. A-003 authorizes the repository's existing isolated coverage
baseline-move process for exactly retired declarations and moved signatures,
with no gate change, no coverage credit and a live extra-deletion fault control.
