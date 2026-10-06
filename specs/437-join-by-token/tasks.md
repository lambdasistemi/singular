# A registry joined from its state token: tasks

Read the [plan](plan.md) for the slices. There is one commit per task, in order. Each acceptance
task is a review checkpoint.

## Slice: the token is the registry

As Bob, I start from an empty directory and the state token, and every command works or refuses by
name.

- [ ] **Failing tests for the slice.** Committed failing. They cover:
  - the existence query and mint record against recorded Koios fixtures;
  - every identity refusal;
  - reference search order, the local hash check and the deterministic choice;
  - a command run from an empty directory on the state token.
- [ ] **The provider finds outputs by reference-script hash.**
  - The existence query and the mint record are added to the provider interface.
  - The Koios instance answers them through `reference_script_utxos`, `tx_cbor`, `utxo_info`,
    `asset_info` and `tx_info`, with recorded fixtures.
  - The devnet facade serves the same endpoints.
- [ ] **One resolver turns a state token into a registry.**
  - Expected hashes are derived from the release and the token.
  - The seven identity refusals.
  - Reference search through the provider, then hints, then the wallet, with the local hash check.
- [ ] **Commands run on the state token.**
  - `--state-token` and `--reference-hint` on every command.
  - `registry.json` and its checks deleted.
  - `create` checks the funding for every publication before the boot, finds the state reference
    by hash, and prints the token.
  - `inspect` and preview resolve from the token.
- [ ] **Demo scripts and pages follow.**
  - Each actor in the demo scripts and CI apps starts from an empty directory with the state
    token.
  - Pages that describe `registry.json` are updated, with speech.

## Slice: anyone publishes

As anyone, I restore a registry's references from the release when no output carries them, and I
get my own back.

- [ ] Failing tests for publishing, retiring and coin selection. Committed failing.
- [ ] `publish-references`, `--publish-references` and `retire-references`.
- [ ] Coin selection skips outputs carrying a reference script.
- [ ] The devnet journey: references retired, a fold refused `reference-missing`, the references
  published again, then the fold succeeds.

## Slice: the page

As anyone, I generate the registry's page from the chain and compare it with a published copy.

- [ ] Failing tests for the page's sections and its determinism. Committed failing.
- [ ] `registry describe` as Markdown and as `--json`.
- [ ] The devnet page matches a replay, and regeneration is byte-identical.
