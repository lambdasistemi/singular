# A registry joined from its state token: modules model

Only new or changed modules are listed. Fields are in the [data model](data-model.md) and
signatures in the [functions model](functions-model.md). Dependencies point downward: the CLI
depends on the registry library, and the library depends on the provider interface.
PR1 binds main `23964e667fa278b2027d0c05169c0f5e0e9233cb`, Lean tree
`16ee2d4a4233130460b7e36daffbe6f2b8b9a8ef` and constitution 1.13.0. No model or on-chain
change is authorised. The complete issue retains reference commands, closed-wallet funding and the page as the next
serial implementation boundaries under E371; PR1 alone cannot close the issue.

## The provider interface

`offchain/local-services/Singular/Registry/LedgerProvider.hs`, used by every slice.

- **Existence query for reference scripts.** It answers "live outputs carrying reference script H"
  (#439). This is a new kind of output query, so it composes with the existing ones.
- **Mint record of an asset.** It gives the minting transaction, the inputs that transaction spent,
  and the current supply.
- **Witness handling.** Both answers carry the session's witness type. A provider without
  witnesses answers them unverified.

## The Koios instance

`offchain/lib/Singular/Provider/Koios/` (wire, client, provider, fixtures), used by every slice.

- **Existence query.** Answered from `reference_script_utxos`. Each candidate's exact output comes
  from `tx_cbor` of its producing transaction, and `utxo_info` reports whether it is spent.
- **Mint record.** Answered from `asset_info` and `tx_info`.
- **Recorded fixtures.** They cover a hit, an empty answer, a spent candidate, and a candidate whose
  output carries a script other than the one its hash field claims.

## The development-network Koios facade

`offchain/private-facade/Singular/Registry/Private/Facade.hs`, used by every slice.

- **New endpoints.** It serves `reference_script_utxos`, `utxo_info` and `asset_info`, answered
  from the devnet ledger, so devnet runs exercise the same client path as preprod.

## Registry identity and references

A new library module under `offchain/lib/Singular/Registry/`, introduced in slice 1. It owns the
whole derivation from a state token.

- **The resolver.** It applies the identity checks and named refusals of the [spec](spec.md).
- **Expected script hashes.** It derives the six expected hashes from the release and the token.
- **Reference search.** It queries the provider, then reads the actor's wallet only for missing
  needed roles, applies the local hash check, and picks deterministically. No needed roles means
  no discovery reads.
- **Ownership.** It replaces resolution by saved output reference, which is deleted from
  `Singular/Registry/Deployment/Attach.hs`. The `Deployment` manifest stays only for the
  `offchain/deployment` and `offchain/journey` tools.
- **Placement.** It sits in the library, so CLI callers and library tests share one implementation;
  a future page can consume it in PR2.

## The CLI

`offchain/cli/src/Singular/CLI/`.

- **`Registry`.** Loses the saved identity: `RegistryConfig`, `registry.json` reading and writing,
  `checkWallet`, and `checkPins` against a record. It keeps the release loader, the pending identity
  used during `create`, and the refusal to create over an existing journal or pending identity.
- **`Live`, `Attached`, `Inspect`, `Preview`.** Build their view from the resolver instead of the
  saved identity.
- **`Command`.** Adds `--state-token` (with `SINGULAR_STATE_TOKEN`) to existing commands.
- **`Create`.**
  - It finds the state reference through the resolver's reference search.
  - It checks the funding for every publication before the boot (#406).
  - It writes no `registry.json` and prints the state token.
- **PR2: funding and the reference commands.** The closed wallet-output interface and narrowed
  fund inputs protect ordinary funding; a reference-command module handles publication and
  retirement. Before that phase, version the preserved PR2 wallet/read interface against the current main
  composition; keep ordinary funding inaccessible outside its opaque module.
- **PR2: the page.** `Singular.Registry.Page` owns deterministic public replay and archive facts;
  LedgerProvider and Koios/facade own its typed transaction-block read. The release assembler
  and checker own adjacent version.txt and its asset/checksum agreement.

## Public evidence and inherited fold inputs

The CLI description language explicitly retires the saved-selector promise with its history and
reason. Retirement does not conceal live clauses, reuse receipts or transfer state. Independently
derived report action identity remains a separate unmet PR2 requirement. Preserve the current
issue #419 history-withholding controls, carried datum and public fold consumers. Actor files contain
only their own in-flight submissions; no private preimage or Alice-file dependency is restored.

## Demo scripts, CI apps and docs

`tools/demo1_*.sh`, `flake.nix` apps, and `docs/` and `onchain-release/` pages that mention
`registry.json`.

- **Demo scripts.** They pass the state token instead of sharing a registry directory. Bob starts
  empty, receives no Alice context and follows the connected public-input path. The existing
  deliberate-open control must fail the hosted run on an Alice-file open.
- **Pages.** Updated in the slice that changes their subject, with stamped speech files.
