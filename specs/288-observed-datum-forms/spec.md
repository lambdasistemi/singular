# Read the datum form the ledger holds

As a conformance reader, I want each reported input and destination datum form to come from the actual transaction or spent output, so a missing or hashed datum cannot be reported as inline.

## Required behavior

| Requirement | Observable result |
|---|---|
| witness-request-state-spent-custody-inputs-destination (blocking) | Witness, request, state and spent custody inputs and the destination output report their actual datum form. Inline, hashed and absent remain distinct. |
| observation-never-reads-model-s-expected-datum (blocking) | Observation never reads the model's expected datum form or defaults missing ledger evidence to inline. Missing or ambiguous evidence is an error, not a successful comparison. |
| relevant-observed-datum-mismatch-reaches-existing-complete (blocking) | A relevant observed datum mismatch reaches the existing complete transaction comparison and makes it fail; passing live cases retain their result. |
| no-lean-semantics-production-transaction-effects-script (blocking) | No Lean semantics, production transaction effects, script identities, receipt schema, module moves or independent refactor changes. |

## Model and evidence

Bind main `c4bad7cc9e079db03f962ecb89df2c24223439dc`, Lean tree `b5bd27105eed6bd71fffdb796b7bbad22aeecb7b`, constitution 1.10.1. From the first binding `b3cbe15e8cd7f9c1b701b9ff7d262c3a89fca8c8` only a Lean lint script moved; `lean/Singular/Model.lean` and `lean/driver-corpus.json` are byte-identical. Relevant definitions are `Singular.DatumForm`, `registryDatumForm`, `TxInput`, `TxOutput`, `txBurnInputs`, `txStateOutput`, `txDestinationOutput` and the driver's transaction serialization. Lean's expected inline form stays fixed; the implementation observation must read the actual form independently. A newly exposed model conflict requires a concrete user-story escalation.

The regression must execute the affected observer and comparator, including each relevant role and the absent/hashed/inline distinctions; source grep is not a control. Distinguish synthetic ledger-value tests from an actual devnet execution. No new on-chain coverage claim or hand-written book state follows from this harness repair. Existing model and coverage debt stays visible.
