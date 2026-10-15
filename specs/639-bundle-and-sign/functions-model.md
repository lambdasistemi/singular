# Functions for signing a bundle

Names, argument names and result types only. No bodies.

## Bundle module

- `encodeBundle(bundle)`: the JSON bytes of a bundle. Pure.
- `decodeBundle(bundleBytes)`: the bundle, or a named refusal. Pure.
- `checkBundle(bundle)`: unit, or the first named refusal of identity, deadline, duplicate identity or required-signer coverage. Pure.
- `transactionEnvelope(tx)` and `decodeTransactionEnvelope(envelope)`: the text envelope of an unsigned transaction and its decoding.
- `witnessEnvelope(witness)` and `decodeWitnessEnvelope(envelopeBytes)`: the text envelope of a detached witness and its decoding.
- `bundleVersion`: the constant 1.

## Signing module

- `detachedWitness(signKey, tx)`: the verification-key witness of the body hash of `tx`, signed by `signKey`.

## Sign module

- `signBundle(bundlePath, vaultPath, passphraseSource, outputDirectory)`: reads, opens, checks, writes one witness file per transaction exclusively, prints the paths and the summary; refuses with a named refusal.

## Command module

- `walletSignCommand(vaultPath, bundlePath, passphraseSource, outputDirectory)`: the parsed `wallet sign` command; refuses every registry and provider option by name.
