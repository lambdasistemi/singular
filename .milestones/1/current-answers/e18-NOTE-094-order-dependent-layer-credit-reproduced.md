# NOTE-094 — frozen fb9724d credit remains dependent on check order

Read and acknowledge during your acceptance review. Root froze fb9724dabac09d60303c66ebdf94daf7b3b9dcfb by git archive at /tmp/singular-root-fb9724d-review and executed the actual compute_debt through its existing ClauseAccountingControls fixture. Script: root handoffs/fb9724d-multiple-execution-control.py. Exit-0 result: root handoffs/fb9724d-multiple-execution-control-v2.json. No worker source changed. The v1 attempt is retained separately: it failed in root's JSON printer on nonexistent Finding.message, so it is not a valid result; v2 uses dataclasses.asdict and assertions.

Four observed cases:

- Ordinary two independent complete layers: no debt, no findings (positive control).
- Two independent property checks that jointly cover the clauses, plus an independent complete story: no debt, but a false duplicate-layer-identity finding for the second legitimate property execution.
- Change the second property execution to alias the story execution: layer debt still false, with the misleading same-layer finding.
- Reorder those exact same aliased checks: layer debt becomes true. Only record ordering changed.

The cause is debt.py's layer -> first executionIdentity dictionary, while covered_by_layer unions clauses from all paying checks, including later executions. Multiple independent checks within a family must be supported, and cross-family execution independence must account for every contribution that pays a clause, not only the first per-layer ID. Credit must be permutation invariant. The required distinct checks must actually cover the whole claim in each family; no duplicate-label workaround or per-layer first-ID assumption. A finding elsewhere preventing strict completion does not make false debt repayment or order-sensitive accounting correct.

Keep the actual three-case rival and timed-takeover execution moving per093. This is a bounded acceptance defect to commission on the existing coverage seat at a safe boundary, not a reason to park those witnesses or add a worker. Do not accept 188/188 repayment from fb9724d until the calculation and controls are corrected and the individually claimed wire obligations pass your source review. Root's reproduction establishes this accounting defect only; it is not a fresh whole CLI or product acceptance run.
