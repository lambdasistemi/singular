# Authentication and wire-format rows

As a reader deciding whether to use the registry, I want the authentication
and wire-format requirements to say which the model describes and which it
does not, so I can understand the evidence and its limits.

## Acceptance

- [ ] classify-authentication-and-wire-format: classify all five authentication
  and eight wire-format requirements as an edge composition, a transaction
  tamper, or outside the model vocabulary, with a reason for each.
- [ ] interpret-coherent-vocabularies-once: name and interpret each coherent
  authentication or wire-round-trip vocabulary generically, preserving the
  description language's execution and rendering extent.
- [ ] remove-replaced-runners-and-preserve-outcomes: delete every migrated
  per-row runner in the same change and retain its devnet outcome,
  receipt-derived state and recorded gaps.
- [ ] report-runner-size-and-verification-limits: state the runner's measured
  line count before and after, bind the unchanged Lean revision, and map the
  remaining verification limits to their tickets in the PR.

## Limits

Lean remains the behavioral authority. The migration changes no Lean and does
not wire the separate authentication specification. The wrong-constructor
requirement remains unmet by ruling; partial constructor coverage stays
partial. Newly executed rows and newly exposed model gaps require a ruling
before affected acceptance. This record marks no task complete without its
checkpoint review and required evidence.
