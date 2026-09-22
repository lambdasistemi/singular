# Registration compared with the driver

A requester books an `insertActive` edge for a recipient. The live story submits
the request, folds it on a local Cardano devnet, and compares the resulting
transaction and registry observations with the executable Lean driver. The
same interpreter handles the retirement chapter and the unnamed sequence.
The receipt records the request, model and chain outcomes, nine declared
observations, and perturbation checks for an accepted comparison.

The model declaration for the registration transaction is
`Singular.Statements.insert_active_transaction_row` at
`265c595edd72eab10f3b08a36cb010ad407cf48b`. The exact model revision and
run basis belong to each receipt. The [book](../BOOK.md) is generated from
those receipts and lists uncovered requirements as well as executed ones.

## Historical evidence

The [earlier structured run](registration-run.json) records a narrower delivery
projection on working-tree base `7db0341a17cb0f2e9c932b86437d72648e5b88d1`.
It compared one normal delivery and two altered observations. That run is
historical evidence of its own interpreter, not evidence for the current
driver-based chapter or an exact-final-commit acceptance.

## Limits

The live receipt proves only the compared story steps on its recorded devnet.
It does not prove every reachable state or every theorem consumer. The
declaration and its executable driver remain the behavioral authority;
the [correspondence inventory](journey-correspondence.md) names uncovered
consumers.
