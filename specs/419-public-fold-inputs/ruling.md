# Public fold inputs: ruling

Operator ruling, 6 October 2026: "go with A, as MPFS does". Recorded under constitution
principle II: the model was underspecified for the claim that "the folder is
permissionless" (`onchain/validators/types.ak:365`), which held for signatures only.

## Story

As Bob, a folder unrelated to Alice, I want to fold Alice's pending insertion from what
the chain shows, so that her request is processed without her staying online and
without any application running its own datum service.

## Decision

1. **The datum inline in the request.** `Request.destination` carries the address bytes
   and the datum itself, `(ByteArray, Option<Data>)`. The cage requires the receiving
   output's datum to equal it and derives the approval hash from it. Keeping the hash
   beside a carried datum is rejected: a request could carry a datum that disagrees with
   its hash.
2. **Existing registries stay as they are.** registry-go3 and the GO-2 registry cannot
   migrate; their insertions remain foldable only by whoever holds the datum, and the
   release notes say so. A preprod registry from the new release is a separate operator
   authorization.
3. **Two-actor test boundary.** Bob holds only the registry identity and trie state; the
   empty-directory version is #381's.

## Candidates compared

| | public from a node alone | presence enforced for every delivering edge | per-application work | booking cost on the Demo 1 payload |
|---|---|---|---|---|
| **Datum inline in the request** | yes | yes, by construction | none | about 152 bytes more, about 0.66 ADA more locked and delivered with the token |
| Datum in the booking's witness set | no | no: only an approval policy could require it, and `witnessTerminal` has none | every application adds the check | an extra output of about 1 ADA plus the datum bytes |
| Datum in transaction metadata | no | no: scripts do not see metadata | yes | the datum bytes |
| A separate datum output read at fold | yes | no: no script runs when it is created | yes | an extra output, permanent if locked |
| A datum fixed by the protocol | yes | yes | ends the application's datum choice | none |

The witness-set rule: a datum not required by a spent input is admitted only when its
hash is the datum hash of an output of the same transaction or of a reference input
(`getBabbageSupplementalDataHashes`, cardano-ledger
`eras/babbage/impl/src/Cardano/Ledger/Babbage/UTxO.hs:79-84`).

## Upstream

Upstream MPFS requests carry their operation's bytes inline
(`Operation = Insert(ByteArray) | Delete(ByteArray) | Update(ByteArray, ByteArray)`,
cardano-foundation/cardano-mpfs-onchain `validators/types.ak` at main `34a5bfbb`). The
defect is Singular's own; the ruling restores the upstream shape while keeping #157's
protection that no folder chooses the address or the datum.

## Consequences

- The request wire changes: the cage, naming's request mirror and their script hashes
  move; a breaking on-chain release follows.
- The Lean model carries the datum value in the request, the delivered output and the
  holding; driver corpus, simulator mirror and conformance follow.
- The registry directory's `preimages/` and `Preimage.hs` are removed.
