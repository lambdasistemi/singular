# Cross-artifact analysis

As the ticket owner, I want the spec, plan, models and tasks checked against each other before code, so no worker has to pick between two statements.

## Coverage

| Requirement | Plan | Model | Tasks |
| --- | --- | --- | --- |
| R280-01 | Delivery step 3, mutant gate row | patch and recorder components; record `exit` and `witnesses` | T280-03, T280-05 |
| R280-02 | Delivery step 3, restored gate row | record `exit` and `witnesses` | T280-05 |
| R280-03 | Identity gate row | every record field and the pair invariants | T280-04, T280-05 |
| R280-04 | Delivery step 5 | records, logs and reader page components | T280-03, T280-07 |
| R280-05 | Root CI, format and lint gate rows | direction: nothing depends on the new components | T280-08 |
| R280-06 | Delivery step 4 | conditional regression target component and signature | T280-06 |

Every requirement has a task, and every task names a requirement or covers all of them.

## Consistency findings

| Severity | Finding | Disposition |
| --- | --- | --- |
| high, resolved | Planning audit 001: a mutant that only empties the map given to the final assembly is stopped by the runner's pre-submission consistency guard, so it never reaches the node. | The mutation now replaces the declaration itself, which the guard, the assembly and refusal attribution all read. No guard is disabled. |
| none | The spec says "runner" where the ticket brief says "interpreter"; both mean the generic fold step of `Conformance.Run.Live`. | Recorded here; no edit. |
| none | The spec retains raw logs; the models retain them compressed and compare digests after decompression. | Consistent: compression is a storage choice. |
| none | The fixture sets the fallback only for the first fold. The mutation gives every fold its default units as its declaration, so later folds would get the fixture's pass-through units, but the first fold fails before any later one runs. | The RED witnesses are tied to the first fold. |
| low | Log size is unknown before the first run. | Stop condition added to the plan: above 5 MiB compressed, the coder asks first. |
| low | New files may need a code inventory entry, and a new script meets the fixture-state guard. | Both run inside root CI, the T280-08 gate. |

## Constitution alignment

No Lean change, no expected-result change, no public conformance page change. Execution units stay unobservable in the model. The evidence type is ledger execution through the CI command, as the constitution requires for a ledger claim.

## Result

No blocking contradiction, no uncovered requirement and no open question. Planning is ready for the auditor's checkpoint.
