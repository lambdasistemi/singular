# Give registry folds coherent owners

As a registry caller, I want a fold built through the existing `Update` API to
keep its request order, token effects, custody refunds, destinations and signer
requirements while its preparation, duty decisions and assembly gain clear
owners. This is a representation change, not a new registry rule.

Intake base: `446617ab99b181bbcc0939728b3f77edf92e9a32`. Accepted Lean at
intake: that commit's `lean/` tree
`f1e6a0edcaf9edce7369fd42add8b3677ddabeb2` (`Model.lean` blob
`19806f297bf9a998e795747e0f1601b5376ebbe1`; `Statements.lean` blob
`e40c40c0165fbf110902544126e7f76edef6c25e`). The latest model-source
commit is `5a6e307c1caf1b4cdd6b2fae082d4b0c33c338f4`; the later Lean
corpus commit `57e173d0e98869e491ea486c0e058c0b35d8c80e` is included in
the intake tree. `foldActions`, `foldBatch`, `obligations`, `txOf`,
`requiredSigners` and `Statements.fold_requires_no_signer` bind this change.

## Requirements

| ID | Requirement | Observable acceptance |
| --- | --- | --- |
| R267-1 | Give each original declaration exactly one owner and retain all six public `Update` exports, including record selectors and instances. | Before/after declaration map, unchanged export list and compiled original callers. |
| R267-2 | Keep ordered request lookup, speculative proofs, state continuation, fee input and upper slot. | Focused fold controls and fresh-blueprint E2E/journey through production entry points. |
| R267-3 | Keep duty results and refusals: mint quantities, approval returns, holder selection, destination datums, custody spends/refunds, owner deposit settlement and no required signer. | Existing booking, burn-source and lifecycle assertions; a behavior-sensitive negative control detects an altered effect/order. |
| R267-4 | Keep transaction assembly, balancing and script/reference use at the same public call path. | Component build, focused cage suite, fresh-blueprint E2E/journey and exact-head CI. |
| R267-5 | Publish contributor-facing ownership, dependency and fold flow documentation with source/API links and speech. | Guide, navigation and synchronized speech pass docs/presentation checks and source-derived review. |
| R267-6 | Leave independent evidence derivation and Conformance state untouched. | Conformance consumer compilation/listing is an unchanged compatibility check; no new coverage claim. |

## Boundary

The #253 deposit/custody settlement code, #254 shared-custody case and #258
model exit obligations are intake facts, not rules to reinterpret. #198 tests
are outside this implementation scope. No Lean, on-chain, wire, validator,
Conformance, workflow, dependency, executable-name, release or deployment edit
belongs to this ticket. A needed excluded-surface change is a question to the
epic owner before any edit. A clear code/Lean contradiction is repaired within
scope with evidence; ambiguity or model conflict holds affected acceptance.

Source inspection and a passing build alone do not establish transaction
correspondence. The exact candidate, model, gate receipts, negative control,
independent audit and uncovered behavior remain explicit in the PR record.
