# Changed responsibilities

## Contract

Base d92f35bf722120369c386ce09e6c7a40d321182f. This model owns responsibilities;
data-model.md owns fields and functions-model.md owns signatures.

| ID | Owner | Responsibility |
|---|---|---|
| M1 | onchain/validators/types.ak and state.ak | Correct cage datum and authoritative custody identity/refund validation; retain edge contracts. |
| M2 | offchain/lib/Singular/Registry/Types.hs | Matching production wire codecs; no duplicated identity in payload. |
| M3 | offchain/lib/Singular/Registry/TxBuilder/Update.hs | Construct corrected custody; recognize custody identity from ledger output values under the registry configuration. Depends on M2. |
| M4 | Existing onchain and offchain test components | Exercise M1-M3 at their actual boundaries and preserve affected existing coverage. |
| M5 | conformance/ and .github/workflows/conformance.yml | S2 HELD: execute the Lean-bound row through M1-M3 and register/assert it after DSL merge. S1 permits only existing consumer representation adaptations. |
| M6 | Edge documentation and final PR mapping | Explain corrected wire, exact model correspondence, exclusions and verification limits. |

No new subsystem, dependency, public command, simulator execution engine, or
naming validator responsibility is introduced. Generated blueprint/identity
artifacts remain owned by existing onchain generation commands.
