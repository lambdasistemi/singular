# Tasks for creating registries on shared script publications

Issue 745. Grouped by pull request and slice of [the plan](plan.md#pull-requests-and-slices). A task is checked only after
the ticket owner accepts its slice.

## Binding

- [x] gate-synthesized: the ticket owner's and the auditor's gate tables joined once and frozen with both input hashes.

## Pull request 1: measured creation

- [x] creation-cost-baseline-and-candidate: matched first and later creations for the previous design and the candidate, with receipts and the page.
- [x] boot-carrying-attempt: script and transaction sizes against the frozen limits, the outcome and its limiting evidence.

## Pull request 2: references and independent reuse

- [ ] reference-verification-outcomes: reused, published, missing, spent and wrong script outcomes, each with its control.
- [ ] independent-creator-and-recovery: a creator that never published reuses both copies; recovery and repeat invocation over shared publications.

## Pull request 3: registration, conformance and documentation

- [ ] shared-registry-registers: a registry created on live copies is booked and folded with the same commands.
- [ ] reuse-conformance-and-documentation: the reuse rows computed from receipts, the instructions and the speech.
