# Delivery ledger for the fold budget control

As an integrator, I need each task stamp to name its commit and receipt rather than claim a result.

## Work items

Tasks run in this order; each depends on the one before it.

| Task | Requirements | Owner | Completion evidence | Status |
| --- | --- | --- | --- | --- |
| T280-01 | all | ticket owner | Intake, source map, root CI baseline at the base, and these planning artifacts committed. | Open |
| T280-02 | all | auditor | Planning checkpoint approved at the planning commit. | Open |
| T280-03 | R280-01, R280-04 | coder | The patch and reader page committed. The patch applies to its own parent and changes only the per-purpose declaration. | Open |
| T280-04 | R280-03 | coder | The recorder committed at the same candidate, with the interface in the functions model. | Open |
| T280-05 | R280-01, R280-02, R280-03 | coder | The recorder run against the candidate: mutant nonzero with its four witnesses, restored run 0 with its witnesses, pair admissible. | Open |
| T280-06 | R280-06 | coder | Only if the mutant exits 0: the regression target repair committed, then T280-05 repeated on the repaired candidate. Otherwise marked not needed, citing the mutant record. | Open |
| T280-07 | R280-04 | coder | Records and raw logs committed; the commit touches only the evidence directory. | Open |
| T280-08 | R280-05 | coder | Root CI, and the Conformance format and lint checks when Haskell changed, exit 0 at the final head, with receipts. | Open |
| T280-09 | all | auditor | Checkpoint approvals for the candidate, the pair and the final head. | Open |
| T280-10 | all | ticket owner | Acceptance: approval trail, fresh final gate, tasks stamped and the plan's status current. | Open |

Task stamps do not substitute for the run records, the audit verdicts or CI on a published head. No push, pull request or merge is authorized by this ticket's current grant.
