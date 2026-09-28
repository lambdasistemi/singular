# Read the datum form the ledger holds

As a conformance reader, I want each reported input and destination datum form to come from the actual transaction or spent output, so a missing or hashed datum cannot be reported as inline.

## Required behavior

| Requirement | Observable result |
|---|---|
| INV-288-OBSERVED (blocking) | Witness, request, state and spent custody inputs and the destination output report their actual datum form. Inline, hashed and absent remain distinct. |
| INV-288-INDEPENDENT (blocking) | Observation never reads the model's expected datum form or defaults missing ledger evidence to inline. Missing or ambiguous evidence is an error, not a successful comparison. |
| INV-288-COMPARED (blocking) | A relevant observed datum mismatch reaches the existing complete transaction comparison and makes it fail; passing live cases retain their result. |
| INV-288-FENCE (blocking) | No Lean semantics, production transaction effects, script identities, receipt schema, module moves or independent refactor changes. |

## Model and evidence

Bind main `b3cbe15e8cd7f9c1b701b9ff7d262c3a89fca8c8`, Lean tree `f1e6a0edcaf9edce7369fd42add8b3677ddabeb2`, constitution 1.10.1. Relevant definitions are `Singular.DatumForm`, `registryDatumForm`, `TxInput`, `TxOutput`, `txBurnInputs`, `txStateOutput`, `txDestinationOutput` and the driver's transaction serialization. Lean's expected inline form stays fixed; the implementation observation must read the actual form independently. A newly exposed model conflict requires a concrete user-story escalation.

The regression must execute the affected observer and comparator, including each relevant role and the absent/hashed/inline distinctions; source grep is not a control. Distinguish synthetic ledger-value tests from an actual devnet execution. No new on-chain coverage claim or hand-written book state follows from this harness repair. Existing model and coverage debt stays visible.
