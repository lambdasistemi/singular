# Contributor instructions

Read [.specify/memory/constitution.md](.specify/memory/constitution.md) before
planning, implementing, reviewing or accepting work in this repository.

Lean is the behavioral authority for every implementation layer. Repair code
that contradicts clear Lean. If Lean is wrong, ambiguous, underspecified for a
claimed behavior, or conflicts with the bound consumer model, hold affected
acceptance and escalate to the user with a concrete user story and evidence.
Do not invent a ruling, weaken expectations or count an unmet requirement as a
pass. This also applies to previously merged and released work.

The conformance suite is the product's public evidence statement, read by people
outside this project. Write it for that reader: state computed from receipts and
never typed, uncovered rows published, every product claim said in the suite's
description language, requirement text rather than internal identifiers, and
harness evidence kept to a marked appendix.

Use [.github/pull_request_template.md](.github/pull_request_template.md) to record
the story, exact model revision, implementation mapping and verification limits.
The constitution defines the full rules and amendment process.

Every Singular issue belongs in [Lambda Sistemi Project 4](https://github.com/orgs/lambdasistemi/projects/4).
After creating an issue, verify its project membership and repair or report a
failed automatic intake. Project membership does not set its schedule or prove
acceptance; the constitution defines the reconciliation obligation. See
[.github/PROJECT4_INTAKE.md](.github/PROJECT4_INTAKE.md) for the project rule and
inventory check.
