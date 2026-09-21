# insertAbsent transaction contract

As a requester witnessing an unknown key absent, I want the cage custody output
 to carry my refund address alone and exactly one absent token naming the key,
so that the token supplies the identity and the recorded deposit can later be
refunded to the address I selected.

This design slice extends `txOf`, connects the existing insert-absent inversion
and absent-witness uniqueness proofs, and exports an executed transaction row.
It preserves the existing logical transition. The runnable deliverable is
`nix run --quiet .#model-check` checking that row and its source-bound corpus.

The theorem will bind the complete constructed transaction, sole-asset key
recovery, the root transition and configuration frame, keyed mint and policy,
empty signer set, custody deposit and refund address, and no immediate refund.
Proof mutations cover an added datum key, two custody assets and no custody
asset. Evidence and the consumer inventory will be recorded here before review.

Simulator transaction replay is deferred to #178. The simulator currently
replays logical steps but does not execute `corpus.transactions`; its green
result cannot establish this transaction contract. On-chain and Haskell wire
migration, conformance rows, and a user command remain #178's work.
