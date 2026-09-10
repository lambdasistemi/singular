# Naming LI correspondence record

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
| `registry` (1) | The singleton registry state UTxO held at the naming application validator, carrying the registry state token; the abstract `registry` nat indexes it (the state token's name/incarnation). | status: realised (#47) — the UTxO `3f444e1300346875d8462a4af81f16ca8fd0e26ef1d232b515b14a79a8b672cf#0` at the applied state script address, carrying exactly 1 registry token named `0xc1f1c9b09607e0f63d1580f3e9d3eb88b7d8a208f5a3d4be01b8fd009eebb632` |
| `applicationPolicy` (7) | The `PolicyId` (script hash) of the application minting policy compiled from the naming blueprint — mints the insert-request token on `insert` and burns it when the request folds or is cancelled. | intended-but-unproven (#47) — not exercised by LI01 (`applicationMint` is false); its applied hash `0x8c7f99ec95884024eb74a500c8af1def3e60ade9ca64241f4c94e869` was named by derivation only |
| `representativePolicy` (8) | The `PolicyId` (script hash) of the representative minting policy — one representative NFT per naming record; `assetScope` is the record's incarnation, so reuse mints a fresh representative under the same policy. | intended-but-unproven (#47) — not exercised by LI01 (`representativeMint` is false); the frozen partition contains no representative minting policy at all, so this realisation has no object to bind to yet |
| `validatorScript` (12) | The compiled registry/application spending validator's script identity, from the pinned partition in `onchain/script-identity.json` (read at run time via `MPFS_BLUEPRINT`, never baked into the offchain tree). LI08 refuses a substituted validator script, so the identity is part of the initialization binding. | status: realised (#47) — the applied `state.state` script `0x874e476d7408de769e07a4ebf34f3c7379ebd7bd35ab8aad426b41d5` (derived from the pinned unapplied `0x64d1afbf…` with `previousPolicies=[]`), read back from the registry UTxO's address credential and carried as the tx's only script witness; the same script hash is the bootstrap minting policy |
| `canonicalSeed` (400) | The canonical seed UTxO: a unique outRef consumed by the initialization transaction (`seedConsumed: true`). Uniqueness (LI02, LI03, LI06) is enforced by *spending* it — a second registry can never consume it again — not by referencing it. | status: realised (#47) — the lexically first UTxO of the devnet genesis wallet, consumed by tx `3f444e1300346875d8462a4af81f16ca8fd0e26ef1d232b515b14a79a8b672cf`; bound on chain by the registry token name, which is SHA-256 of the seed outRef |

## `executingWitness` flag → intended concrete witness

| flag (LI rows) | intended concrete ledger witness | status |
|---|---|---|
| `seedSpend` | A transaction input spending the canonical seed UTxO, witnessed by the bootstrap/seed validator. The only flag set on the accepted `LI01`. | status: realised (#47) — the canonical seed outRef was a transaction input, and the witness is the applied state policy's *mint branch*: a `Minting(seed)` redeemer whose validator requires `find_input(inputs, seed)` and exactly one token named by the seed. There is no separate seed validator in the frozen partition; the bootstrap enforcement lives in the mint policy |
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

## What run #47 settled (2026-09-10)

The LI01 run (`naming-correspondence` entries above marked realised)
settled one open question and surfaced two findings.

**Settled — the bootstrap mint belongs inside LI01.** The ledger's
at-most-once bootstrap is enforced by the applied state policy's mint
branch, and the only transaction that can consume the canonical seed
with a script witness therefore mints exactly one registry identity
token (name = SHA-256 of the seed outRef) under that same policy. This
mint is under the `validatorScript` identity, not under
`applicationPolicy` or `representativePolicy`, so it contradicts no
flag the row calls absent; it is the ledger shape of "one mint per
chosen seed precedent". The row's `executingWitness` stays exactly
`seedSpend: true` over everything else absent.

**Finding — the checkpoint output has no validator-prescribed shape.**
The initialization also creates a naming checkpoint output at the
application validator address carrying the four-field naming datum
inline (control address, payment destination, next-control commitment,
retirement quorum). The frozen validator constrains only output 0 (the
registry state UTxO); the checkpoint's well-formedness is enforced
off-chain by the `Naming.Datum` codec, on chain by nothing. First
consumer: the claim rows.

**Finding — `representativePolicy` has no realisation in the frozen
partition, and LI01's `representativeMint: false` is realised as an
asserted absence, not as an unimplemented step.** The initialization
mints no representative, and the run *checks* that absence: control C2
raises the expected representative quantity to 1 and the run fails
naming expected 1 vs observed 0. No representative minting policy
exists in the blueprint at all, so the claim rows
(`representativeMint: true`) cannot execute against this partition
without new validator work.
