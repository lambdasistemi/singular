# Changed responsibilities

## Contract

Base d92f35bf722120369c386ce09e6c7a40d321182f. This model owns responsibilities;
data-model.md owns fields and functions-model.md owns signatures.

| ID | Owner | Responsibility |
|---|---|---|
| onchain-validators-types-ak-state-ak | onchain/validators/types.ak and state.ak | Correct cage datum and authoritative custody identity/refund validation; retain edge contracts. |
| offchain-lib-singular-registry-types-hs | offchain/lib/Singular/Registry/Types.hs | Matching production wire codecs; no duplicated identity in payload. |
| offchain-lib-singular-registry-txbuilder-update-hs | offchain/lib/Singular/Registry/TxBuilder/Update.hs | Construct corrected custody; recognize custody identity from ledger output values under the registry configuration. Depends on offchain-lib-singular-registry-types-hs. |
| existing-onchain-offchain-test-components | Existing onchain and offchain test components | Exercise onchain-validators-types-ak-state-ak-offchain-lib-singular-registry-txbuilder-update-hs at their actual boundaries and preserve affected existing coverage. |
| conformance-github-workflows-conformance-yml | conformance/ and .github/workflows/conformance.yml | refund-custody-conformance HELD: execute the Lean-bound row through onchain-validators-types-ak-state-ak-offchain-lib-singular-registry-txbuilder-update-hs and register/assert it after story language merge. refund-custody-wire-and-consumers permits only existing consumer representation adaptations. |
| edge-documentation-final-pr-mapping | Edge documentation and final PR mapping | Explain corrected wire, exact model correspondence, exclusions and verification limits. |

No new subsystem, dependency, public command, simulator execution engine, or
naming validator responsibility is introduced. Generated blueprint/identity
artifacts remain owned by existing onchain generation commands.
