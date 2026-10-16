# Data for signing a bundle

## Bundle

Version (a natural number, 1), command name (text), network magic (a natural number), state token (text or null), signers (a non-empty list of bech32 addresses), transactions (a non-empty list in submission order).

## Bundle transaction

Identity (64 hex digits), envelope (type `Unwitnessed Tx ConwayEra`, a description, `cborHex` of the transaction), deadline slot (a natural number or null), effects (a list of single-line texts). Invariants: the identity is the hash of the decoded body; the deadline equals the body's validity upper bound; the identities in one bundle are distinct.

## Witness file

A text envelope of type `TxWitness ConwayEra` whose content is one verification-key witness: the public key and the signature of the body hash. Named by the transaction identity with the suffix `.witness`.

## Refusal

Named refusals, each carrying what it concerns and nothing secret: unknown version; missing or malformed field; envelope of the wrong type or undecodable; identity mismatch (recorded and actual); deadline mismatch; required signer not covered; vault address not among the signers; duplicate identity; output file exists; vault could not be opened; bundle file unreadable.
