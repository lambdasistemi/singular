# Component responsibilities

| ID | Owner | Responsibility and dependencies |
|---|---|---|
| M01 | Lean model interface | Generic protocol and serialization of existing law/observations; depends on accepted model, never on Haskell or a theorem-specific adapter. |
| M02 | Lean corpus | Theorem-bound witnesses/mutants and required setup traces; shares source definitions with existing corpus/simulator consumers. |
| M03 | Constitutional translation | Defines concrete law/observation mappings, identities and unobservable fields; governs M04 and generated limitations. |
| M04 | Conformance support abstraction | Observes the real system and translates to M01 boundary types under M03; owns identity maps and field comparisons. |
| M05 | Story.Specification and domain stories | Generic typed theorem/clause structure and stakeholder stories; consumes M02 bindings and M04 observations through the interpreter. |
| M06 | Execution contexts | Establish resources outside M05; conformance and E2E supply contexts while sharing scenario execution and comparisons. |
| M07 | Inventory/book/CI | Joins theorem bindings, scenarios and executed receipts; renders the same DSL and reports missing coverage. |

Promote reusable model codecs from Main into the nearest model-owned interface
module; Main may consume them. Do not clone encoders into conformance or create
one oracle/proof pair per theorem. Preserve simulator corpus compatibility.
Data contracts are D01–D06; interface contracts are F01–F05.
