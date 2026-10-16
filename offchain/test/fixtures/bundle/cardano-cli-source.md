# cardano-cli oracle envelopes

`cardano-cli-tx-body.json` and `cardano-cli-tx-witness.json` are
read-only oracle data: the exact JSON text envelopes emitted by the
official `cardano-cli` binary from the `cardano-node` 10.7.0 Linux
release asset, pinned here so the bundle codec is checked against the
tool that produces unsigned transactions, not only against its own
encoder.

```text
cardano-cli 10.15.1.0 - linux-x86_64 - ghc-9.6
git rev 1e6d8228693ab2aa4e1d7305e7bdcc57cdd278e4
```

They were generated offline with
`cardano-cli conway transaction build-raw` and
`cardano-cli conway transaction witness` from a dummy all-zero
transaction input and a throwaway payment key (never checked in): the
envelope shape, not ledger validity, is the contract under test. The
transaction body envelope carries the complete unsigned transaction —
an array of body, empty witness set, validity flag and auxiliary data
— typed `Tx ConwayEra` by that version; the witness envelope carries
one verification-key witness — an array of the 32-byte key and the
64-byte signature — typed `TxWitness ConwayEra`, described
`Key Witness ShelleyEra`.

The bundle codec writes the same transaction shape under the label
`Unwitnessed Tx ConwayEra` and accepts both labels on decode; its
specs prove the official bytes decode, that a recorded identity equals
the hash of the decoded body, and that re-encoding the decoded
transaction reproduces the official `cborHex` byte for byte.
