# Component responsibilities

| ID | Owner | Responsibility and dependencies |
|---|---|---|
| generic-protocol-serialization-existing-law-observations-depends | Lean model interface | Generic protocol and serialization of existing law/observations; depends on accepted model, never on Haskell or a theorem-specific adapter. |
| theorem-bound-witnesses-mutants-required-setup-traces | Lean corpus | Theorem-bound witnesses/mutants and required setup traces; shares source definitions with existing corpus/simulator consumers. |
| defines-concrete-law-observation-mappings-identities-unobservable | Constitutional translation | Defines concrete law/observation mappings, identities and unobservable fields; governs observes-real-system-translates-boundary-types-under and generated limitations. |
| observes-real-system-translates-boundary-types-under | Conformance support abstraction | Observes the real system and translates to generic-protocol-serialization-existing-law-observations-depends boundary types under defines-concrete-law-observation-mappings-identities-unobservable; owns identity maps and field comparisons. |
| story-specification-domain-stories | Story.Specification and domain stories | Generic typed theorem/clause structure and stakeholder stories; consumes theorem-bound-witnesses-mutants-required-setup-traces bindings and observes-real-system-translates-boundary-types-under observations through the interpreter. |
| establish-resources-outside-conformance-e2e-supply-contexts | Execution contexts | Establish resources outside story-specification-domain-stories; conformance and end-to-end supply contexts while sharing scenario execution and comparisons. |
| joins-theorem-bindings-scenarios-executed-receipts-renders | Inventory/book/CI | Joins theorem bindings, scenarios and executed receipts; renders the same story language and reports missing coverage. |

Promote reusable model codecs from Main into the nearest model-owned interface
module; Main may consume them. Do not clone encoders into conformance or create
one oracle/proof pair per theorem. Preserve simulator corpus compatibility.
Data contracts are surface-identity-qualified-model-declaration-definition-digest–execution-receipt-candidate-tree-model-corpus-identities; interface contracts are F01–F05.
