# Data and identity boundary

As an integrator, I want the same compiled script and ledger data to reach the
same transaction and refusal paths after the modules move.

```mermaid
flowchart LR
    JSON[CIP-57 blueprint] -->|parse| Types[Existing schema and validator types]
    Types -->|select code and parameters| Script[Compiled script bytes]
    Script -->|hash and attach| Tx[Transaction]
    Tx -->|observe| Receipt[Existing end-to-end receipt]
    Source[Haskell library source] -->|same candidate revision| API[Generated library reference]
```

## Identity contracts

| ID | Existing value | Constraint |
| --- | --- | --- |
| blueprint-validator-schema-constructor-namingcodes | `Blueprint`, `Validator`, `Schema`, `Constructor`, `NamingCodes` | Retain constructors, fields, instances and public export path. |
| retain-fields-script-bytes-hash-derivation | `ConsumerBinding` | Retain fields, script bytes and hash derivation. |
| ledger-datum-script-hash-address-token-utxo | Ledger datum, script hash, address, token and UTxO references | Preserve encodings, order and failure behavior. |
| generated-library-api-artifact | Generated library API artifact | Bind rendered Haddock to the candidate library source content and complete Cabal `exposed-modules` plus `other-modules` inventory; local module/source links must resolve in the site build, and the same pages must appear in the future docs archive. |

No schema or wire migration is authorized. The declaration map records any
type and instance move together.
