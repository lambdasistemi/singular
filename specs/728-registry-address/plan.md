# Plan: a registry has an address in the style of a Cardano address

## The class of change

Both pull requests change product behaviour: a new spelling of the registry's identity read and printed by three programs, a new standing setting, a new command, new receipt fields, a packaged data file with a refusal that reads it, and in the second pull request a different way of reaching a key. The full process applies: one coder and one persistent auditor, with checkpoints at the failing tests and before the push. No validator, script hash or formal model changes.

## Slices

| Slice | Pull request carries | Says |
|---|---|---|
| The address | the address module; the shared reading of the registry with `--registry` in the three programs; the address, asset id and fingerprint in `create`, `describe` and `inspect`; the command `registry address`; the table from contract hash to release with its filling script, its hosted check and the refusal that names a release; a hosted devnet journey using the address alone; the documentation | `Part of #728` |
| The key reached by its witness token | `inspect --key` by the key's witness token; its hosted check; its documentation | `Closes #728` |

The second starts only after the first is merged on the desk's grant.

## Where each piece lives

- **The address** is one pure module of the library, next to the state token module: the four prefixes, the encoding and decoding of the 60-byte body with the reading refusals in their order, and the CIP-14 fingerprint. It performs no effect. The encoder is the `bech32` package, in its form without the length limit; the hash is one the build already has.
- **The shared reading of the registry** replaces the three functions that read `--state-token` today (one in each program). It takes the settings after the sources have filled them and returns the state token and the network magic, applying the agreement rules. The renamed-flag refusal of `--registry` is removed from the two places that read options.
- **`--registry`** is declared once with the other standing settings, with its variable and key, and taken by every command that takes `--state-token`.
- **The receipt fields** come from one function of the command library used by both `create` commands, `describe` and both `inspect` commands, so they never disagree on a spelling.
- **`registry address`** is one leaf of the registry group of `singular`. It reads no chain and needs no provider.
- **The table** is a data file of the off-chain package, listed with the packaged network-time data and found the same way. One function reads it and looks a hash up; the foreign-release refusal calls it, before any chain read. The script that fills it from the published release assets sits under `tools/`, marked as a tool.
- **The table's hosted check** runs in an existing hosted job: the state-contract hash of the blueprint being built must be a row of the table. A second check, in the journey that runs a program from a release bundle, shows the bundled program finds its table.

## Consumers of the change

- the shared declarations and the help declarations of the programs, with the help snapshots re-recorded by the snapshot spec's own switch;
- the parser corpora of both programs: a changed line keeps `result` and gains `after`, a newly accepted line is added; the lines that expected the renamed-flag refusal of `--registry` change;
- the application settings spec of `open-datum`;
- `keri-stub`, the third program that reads `--state-token`, with its component build and tests;
- the package description, for the new module and the new data file;
- the release bundles, which must carry the new data file;
- the settings table of `docs/singular-node.md` and the documented-flags check that holds it to the real help, which also scans invocations in pages, so a page shows the new command only once the help names it;
- the narration clips of every page the change touches;
- the journeys that read a state token from a receipt, which keep working unchanged.

## The gate

Existing commands only, narrowed by the suites' own filters to what the pull request can break. Every build and test runs in a memory-capped scope with a timeout, from the package's own development shell, never from the root.

| What | Command |
|---|---|
| Format | `just format` twice, then `just format-check` |
| Lint | the library's and the application's lint from their folders, and `just lint` from the root |
| Build | the singular suite and executable; the `open-datum` suite and executable; the `keri-stub` suite and executable |
| Tests | the singular suite filtered to the command layer, the address and the table; the whole `open-datum` suite, whose 14 specs that need flake-staged fixtures cannot run in a plain checkout; the `keri-stub` suite with its data directory set |
| Help and corpora | re-recorded with their own switches and read as a diff |
| Documentation | the documented-flags check, then the documentation check with the staged files |
| Ownership | the effect-ownership, node-confinement and inventory checks |

The hosted checks at the exact head of each pull request are the net; the whole board is awaited by name before a merge is asked for.

## Checkpoints

The auditor is persistent for the ticket and mute toward the coder. The coder asks for a verdict when its failing tests are committed and before the push, when everything is green and the documentation is regenerated. A commit that only changes documentation, narration or generated files needs no checkpoint. A block needs a concrete failure scenario.

## Hosted checks

The first pull request extends a journey that already runs on a devnet in a hosted job: the registry is created, the printed address is taken from the receipt alone, and the later commands name no state token and no network magic, with controls that could fail. The table's check runs in an existing hosted job with a control. The coder names each journey and the workflow step that runs it at the start of the work. A workflow file changes only to wire a check into an existing job, and only after a question to the ticket owner.

## Notes for the tutorial's owner

`handoffs/singular-demo-route.md` in the ticket's runtime root names the tutorial lines, at a named commit fetched first, that carry the state token or the network, and what the address replaces.
