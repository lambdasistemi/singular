# Data and identity boundary

As an integrator, I want the same compiled script and ledger data to reach the
same transaction and refusal paths after the modules move.

```mermaid
flowchart LR
    JSON[CIP-57 blueprint] -->|parse| Types[Existing schema and validator types]
    Types -->|select code and parameters| Script[Compiled script bytes]
    Script -->|hash and attach| Tx[Transaction]
    Tx -->|observe| Receipt[Existing E2E receipt]
```

## Identity contracts

| ID | Existing value | Constraint |
| --- | --- | --- |
| D265-1 | `Blueprint`, `Validator`, `Schema`, `Constructor`, `NamingCodes` | Retain constructors, fields, instances and public export path. |
| D265-2 | `ConsumerBinding` | Retain fields, script bytes and hash derivation. |
| D265-3 | Ledger datum, script hash, address, token and UTxO references | Preserve encodings, order and failure behavior. |

No schema or wire migration is authorized. The declaration map records any
type and instance move together.
