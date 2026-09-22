# Boundary data contracts

- D01 Surface identity: qualified model declaration, definition digest, model
  revision and protocol version. A scenario names only declared operations.
- D02 Scenario: stable corpus identity, theorem/statement bindings, quantified
  inputs, state/action/parameters and setup trace where reachability is required.
  Witness and mutant relationships are explicit. Unsupported or unreachable
  concrete setups are classified; they never become a fabricated successful run.
- D03 Driver result: accepted transition and declared boundary observations, or
  domain refusal with reason. Parse/unsupported-operation/process errors are
  distinct execution failures. No partially decoded success is admitted.
- D04 Concrete observation: actual operation outcome and all observable fields
  named by the constitutional translation. Input provenance and missing fields
  remain explicit; missing values cannot be replaced by model expectations.
- D05 Context/identity state: externally supplied runtime resources with typed
  concrete-to-abstract identity maps persistent across the scenario trace.
  Allocation is allowed only during setup/action; observation is lookup-only.
- D06 Execution receipt: candidate/tree and model/corpus identities, scenario
  and theorem bindings, actual and expected observations, comparison outcome,
  controls applied, execution command and provenance. Rendered status derives
  from receipts. Historical receipts are immutable evidence, not current passes.

Ordering, quantities, datum shapes, signers/refunds, concrete funding/change and
root realization must be defined in M03 before M04 excludes or normalizes them.
Proof-only fields remain visible limitations and do not satisfy R10 by fiat.
