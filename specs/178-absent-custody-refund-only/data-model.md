# Custody representation

## Contract

Base d92f35bf722120369c386ce09e6c7a40d321182f; vocabulary bound by spec.md.

| ID | Entity | Fields and invariant |
|---|---|---|
| D1 | CageDatum.AbsentCustody | refund: ByteArray on chain / ByteString off chain; constructor index 2, one payload field; no key field. |
| D2 | Custody output value | Lovelace deposit plus precisely one non-ADA absent-policy asset, quantity one. Asset name realizes the model Key. Registry configuration identifies the absent policy. |
| D3 | Custody identity | Optional key derived solely from D2; invalid cardinality, policy or quantity yields no identity. |
| D4 | Custody refund | Datum refund address and held lovelace remain distinct from asset identity; insertion holds deposit and pays no custody refund. |

Representation correspondence: Lean logical Nat key/address map to existing
ledger bytes and address encoding; this correction does not invent a new
encoding. Lean's assets list excludes the separately represented lovelace.
Removing ADA from the ledger value is that explicit representation mapping;
discarding another policy's non-ADA asset would weaken the model's singleton.

Old two-field datum is an incompatible wire, documented as such. No migration,
legacy decoder, deployment, naming mirror change or compatibility promise is
introduced by this ticket.
