# Sign a bundle of unsigned transactions from the vault

Issue 639, second of five tickets under issue 490. This page records the story, the bundle format, the requirements and the refusals. Submitting witnesses (issue 640) and the write commands that write bundles (issue 641) are not part of it.

## Story

As Bob, I receive a bundle of unsigned transactions and run `singular wallet sign --vault bob.vault bundle.json` on an offline machine. I type my passphrase and get one witness file per transaction next to the bundle, with a short summary of what I signed on standard error. My key never leaves the vault and the command opens no network connection.

## The bundle

One JSON file with a version field, currently 1. It holds the name of the command that wrote it, the network magic, the registry state token (null before a registry exists), the addresses that must sign, and the transactions in submission order. Each transaction holds its identity, its unsigned body as a standard text envelope (`Unwitnessed Tx ConwayEra`), its deadline (the body's validity upper bound, or null) and the effects its writer expects as plain-language lines. The effects are the writer's claims: they are shown and journaled, never trusted.

## Requirements

- bundle-round-trips: decoding what encoding wrote gives the same bundle, transactions in order, for more than one transaction.
- bundle-version-checked: a bundle with an unknown version, a missing field or a malformed envelope is refused by name.
- recorded-identity-equals-body-hash: a transaction whose recorded identity differs from the hash of its body is refused, naming both.
- recorded-deadline-equals-body-bound: a recorded deadline that differs from the body's validity upper bound is refused.
- required-signers-covered: every key hash in a body's required signers is the key hash of an address in the bundle's signers; otherwise refused.
- vault-key-among-signers: the vault's address, derived for the bundle's network, must be among the signers; otherwise refused and nothing is written.
- witness-signs-the-body-hash: each witness is a standard `TxWitness ConwayEra` envelope whose signature verifies against its body's hash and whose key hash is the vault key's.
- witness-names-its-transaction: one witness per transaction, named by its identity, created exclusively; an existing file is refused with its bytes unchanged.
- signing-needs-no-network: the verb takes no provider option and opens no connection.
- no-secret-in-output: no output, error text or file carries the passphrase or any key byte; a witness carries the public key and the signature only.
- existing-wallet-commands-unchanged: `wallet create`, `wallet address`, `loadWallet` and every registry command behave as before.
- committed-controls-bounded: every run command of a committed control is bounded in time and memory.

## Limits recorded

Whether the signers list is complete cannot be checked offline, because inputs cannot be resolved; submit checks the witness set against the chain. Expiry is not judged offline, because there is no clock that knows the slot; submit refuses expired bodies.
