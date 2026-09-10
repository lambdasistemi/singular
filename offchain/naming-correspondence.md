# Naming LI correspondence record (t45)

The correspondence between the abstract identities the epic-15 contract's
`LI` rows carry and the concrete ledger objects this epic intends to
realise them with.

**This record is an epic 16 design artifact, not something the v0.2.0
contract blessed.** v0.2.0's acceptance note states that the concrete
ledger witness and script partition remain abstract and are
implementation work for the on-chain epics. Every entry below is
**intended-but-unproven** until a validator realises it; issue #47 is
where the partition becomes realised, and any entry may still be recut
there.

Grounding row, read from the contract's own corpus
(`simulator/lifecycle-corpus.json`, `initializations`):

```
LI01-canonical-initialization-accepts
  attempt:  { registry: 1, applicationPolicy: 7, representativePolicy: 8,
              seed: 400, seedConsumed: true, validatorScript: 12,
              sourceRevision: "14a64a…" }
  witness:  { seedSpend: true,  everything else false/empty }
```

Every substitution attempt (LI02 seed, LI03 registry, LI04/LI05/LI07/LI08
policies and script) is refused with `seedSpend: false` — the five
identities below are bound together at initialization or not at all.

## Abstract identity → intended concrete realisation

| abstract identity (LI row) | intended concrete ledger realisation | status |
|---|---|---|
| `registry` (1) | The singleton registry state UTxO held at the naming application validator, carrying the registry state token; the abstract `registry` nat indexes it (the state token's name/incarnation). | intended-but-unproven (#47) |
| `applicationPolicy` (7) | The `PolicyId` (script hash) of the application minting policy compiled from the naming blueprint — mints the insert-request token on `insert` and burns it when the request folds or is cancelled. | intended-but-unproven (#47) |
| `representativePolicy` (8) | The `PolicyId` (script hash) of the representative minting policy — one representative NFT per naming record; `assetScope` is the record's incarnation, so reuse mints a fresh representative under the same policy. | intended-but-unproven (#47) |
| `validatorScript` (12) | The compiled registry/application spending validator's script identity, from the pinned partition in `onchain/script-identity.json` (read at run time via `MPFS_BLUEPRINT`, never baked into the offchain tree). LI08 refuses a substituted validator script, so the identity is part of the initialization binding. | intended-but-unproven (#47) |
| `canonicalSeed` (400) | The canonical seed UTxO: a unique outRef consumed by the initialization transaction (`seedConsumed: true`). Uniqueness (LI02, LI03, LI06) is enforced by *spending* it — a second registry can never consume it again — not by referencing it. | intended-but-unproven (#47) |

## `executingWitness` flag → intended concrete witness

| flag (LI rows) | intended concrete ledger witness | status |
|---|---|---|
| `seedSpend` | A transaction input spending the canonical seed UTxO, witnessed by the bootstrap/seed validator. The only flag set on the accepted `LI01`. | intended-but-unproven (#47) |
| `applicationMint` | A `mint` field under the application policy: request token minted on `insert`, burned on withdrawal/fold/cancellation. | intended-but-unproven (#47) |
| `applicationSpend` | An input consumed at the application validator, carrying the naming datum (the four-field codec of this slice) and the application redeemer. | intended-but-unproven (#47) |
| `representativeMint` | A mint/burn under the representative policy, executed when a claim folds into a record (mint) or a record is retired/reused (burn). | intended-but-unproven (#47) |
| `authenticatedRead` | A reference input resolving to the registry state UTxO, authenticated by requiring the resolved output's script to be the pinned application validator — the read is bound by script identity, not by spending. | intended-but-unproven (#47) |
| `nativeSpend` | A phase-1 (native) script spend — the cancellation path the lifecycle rows mark `nativeSpend: true`, so a cancellation needs no Plutus spending witness on the request output. | intended-but-unproven (#47) |
| `requiredSigners` | The transaction's `requiredSigners` (extra key witnesses) that validators demand — minimally the controller's payment key hash on control-changing transitions. | intended-but-unproven (#47) |
| `quorumSigners` | The `retirementQuorum` members' key hashes: the retirement transitions check that at least `threshold` of the stored 28-byte member hashes appear among the transaction signatories. | intended-but-unproven (#47) |

## Where the encoding itself lives

The datum bytes these witnesses will carry are already fixed by the
contract, not by this record: the four-field codec and its vendored
vectors live in `naming/` (`naming/src/Naming/Datum.hs`, provably
byte-exact against v0.2.0's `wire` vectors). The vectors are the
contract's; the realisation table above is this epic's design.
