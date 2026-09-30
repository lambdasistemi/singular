# Delivery ledger for the fold budget control

As an integrator, I need each task stamp to name its commit and receipt rather than claim a result.

## Work items

Tasks run in this order; each depends on the one before it.

| Task | Requirements | Owner | Completion evidence | Status |
| --- | --- | --- | --- | --- |
| T280-01 | all | ticket owner | Intake, source map, root CI baseline at the base, and these planning artifacts committed. | Complete: planning at 2e13bc8, revised at 4794aeb, f1974bd, 7300652 and d265005; root CI baseline exit 0 at the base. |
| T280-02 | all | auditor | Planning checkpoint approved at the planning commit. | Complete: planning approved at review 001-r1 (4794aeb) and 001-r2 (f1974bd), after review 001 found the pre-submission guard. |
| T280-03 | R280-01, R280-04 | coder | The patch and reader page committed. The patch applies to its own parent and changes only the per-purpose declaration. | Complete: 9c23586, repaired at 4185d8f and dfd4ac1 after reviews 002 and 002-r1. |
| T280-04 | R280-03 | coder | The recorder committed at the same candidate, with the interface in the functions model. | Complete: dfd4ac1, approved at review 002-r1b. |
| T280-05 | R280-01, R280-02, R280-03 | coder | The recorder run against the candidate: mutant nonzero with its four witnesses, restored run 0 with its witnesses, pair admissible. | Complete: the recorder run against dfd4ac1 was admissible. The mutant exited 1 with the runner's budget refusal; the restored run exited 0 with the book. |
| T280-06 | R280-06 | coder | Only if the mutant exits 0: the regression target repair committed, then T280-05 repeated on the repaired candidate. Otherwise marked not needed, citing the mutant record. | Not needed: the mutant exited nonzero with all four witnesses (mutant record). |
| T280-07 | R280-04 | coder | Records and raw logs committed; the commit touches only the evidence directory. | Complete: a6172e0 touches only the two records and two raw logs. |
| T280-08 | R280-05 | coder | Root CI, and the Conformance format and lint checks when Haskell changed, exit 0 at the final head, with receipts. | Complete: root CI, format and lint exit 0 at a6172e0 (coder receipts); the final gate reruns them on the head. |
| T280-09 | all | auditor | Checkpoint approvals for the candidate, the pair and the final head. | Complete: reviews 003 and 004 approved at a6172e0. |
| T280-10 | all | ticket owner | Acceptance: approval trail, fresh final gate, tasks stamped and the plan's status current. | Complete at handback: approval trail verified, and the final gate runs on the head that carries this stamp; its receipt is in the handback, not in this file. |

Task stamps do not substitute for the run records, the audit verdicts or CI on a published head. No push, pull request or merge is authorized by this ticket's current grant.
