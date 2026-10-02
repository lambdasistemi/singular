# Cross-artifact analysis

As the ticket owner, I want the spec, plan, models and tasks checked against each other before code, so no worker has to pick between two statements.

## Coverage

| Requirement | Plan | Model | Tasks |
| --- | --- | --- | --- |
| fixed-fallback-mutant-candidate-exactly-one-committed | Delivery step 3, mutant gate row | patch and recorder components; record `exit` and `witnesses` | patch-reader-page-committed-patch-applies-its, recorder-run-against-candidate-mutant-nonzero-its |
| same-command-on-clean-candidate-evaluated-declaration | Delivery step 3, restored gate row | record `exit` and `witnesses` | recorder-run-against-candidate-mutant-nonzero-its |
| run-record-produced-by-recorder-never-typed | Identity gate row | every record field and the pair invariants | recorder-committed-at-same-candidate-interface-in, recorder-run-against-candidate-mutant-nonzero-its |
| patch-recorder-two-run-records-raw-logs | Delivery step 5 | records, logs and reader page components | patch-reader-page-committed-patch-applies-its, records-raw-logs-committed-commit-touches-evidence |
| nothing-else-changes-ci-workflow-product-runner | Root CI, format and lint gate rows | direction: nothing depends on the new components | root-ci-conformance-format-lint-checks-haskell |
| if-mutant-command-exits-regression-cannot-fail | Delivery step 4 | conditional regression target component and signature | if-mutant-exits-regression-target-repair-committed |

Every requirement has a task, and every task names a requirement or covers all of them.

## Consistency findings

| Severity | Finding | Disposition |
| --- | --- | --- |
| high, resolved | Planning audit 001: a mutant that only empties the map given to the final assembly is stopped by the runner's pre-submission consistency guard, so it never reaches the node. | The mutation now replaces the declaration itself, which the guard, the assembly and refusal attribution all read. No guard is disabled. |
| none | The spec says "runner" where the ticket brief says "interpreter"; both mean the generic fold step of `Conformance.Run.Live`. | Recorded here; no edit. |
| low, resolved | Coder question operator question (Q-001): the repository's code inventory maps shell sources only as `*.sh` and has no class for `*.gz`. | The recorder is `record.sh`, and the logs are retained raw as `*.log`, a class the inventory already maps; no repository tool changes. |
| none | The fixture sets the fallback only for the first fold. The mutation gives every fold its default units as its declaration, so later folds would get the fixture's pass-through units, but the first fold fails before any later one runs. | The RED witnesses are tied to the first fold. |
| low | Log size is unknown before the first run. | Stop condition in the plan: above 5 MiB per raw log, the coder asks first. |
| low | New files may need a code inventory entry, and a new script meets the fixture-state guard. | Both run inside root CI, the root-ci-conformance-format-lint-checks-haskell gate. |

## Constitution alignment

No Lean change, no expected-result change, no public conformance page change. Execution units stay unobservable in the model. The evidence type is ledger execution through the CI command, as the constitution requires for a ledger claim.

## Result

No blocking contradiction, no uncovered requirement and no open question. Planning is ready for the auditor's checkpoint.
