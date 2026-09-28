# Preserve the three datum forms

As a reader, I want inline, hashed and absent datums to remain distinguishable in transaction evidence.

## Data contract

Existing `Singular.DatumForm` has inline, hashed and none. Existing input/output JSON carries the datum field. There is no receipt-schema or model change. Observed forms are a translation of the corresponding concrete ledger datum constructor, independent of the expected model value.

Every reported spent input must be attributable to its actual output reference and observed output. Every reported destination must be attributable to the actual destination output. Missing or ambiguous attribution must fail instead of manufacturing a datum form. Preserve request, state, custody and witness identities and all other fields.

## Retained state input

The internal `LiveStep` observation record gains `lsStateUtxo :: Maybe (TxIn, TxOut ConwayEra)`: this registry's actual spent state output retained from the pre-submission snapshot. An accepted fold or reject reporting a state input requires exactly one corresponding retained state output. Missing or ambiguous evidence is an error. A retraction reports no state input. Unsupported or refused cases do not acquire accepted observations from this field.

This is observation metadata only; it does not change the built transaction, registry state, public receipt schema or Lean model. Other observation fields and their identities remain unchanged.
