# Plan for registry writes that end in a bundle

Issue 641. One pull request, six slices of at most about 90 minutes of writing each. The plan was approved by the M1 desk on 16 October 2026.

## Decisions

- Two staged signer modes beside the unchanged key-file path: the external signer (address and bundle file) and the vault (vault file, passphrase descriptor or prompt). Exactly one signer per run. The signer is read by the shared flag group's write reader, which both parsers call (desk, 16 October); retiring the key file from the four registry writes is issue 672.
- One bundle per run through a chained view: a session whose reads answer as if the transactions staged so far had landed. Every write already goes through one build-and-submit function; in the staged modes it builds from the chained view and stages the unsigned body instead of signing and sending it. The commands' code, the funding preparation included, is unchanged.
- The commands' readbacks run on the chained view and become the bundle's effect lines. Receipts state as fact only what was found on chain by identity; the rest sits under expected.
- A new outcome, waiting-for-signatures, with exit status 19, the next free one. The scripts that copy the exit table get the row.
- The journal phase as the spec states it: membership by identity for life; landed, dead and pending; one bundle state for admission and reporting.
- The vault mode signs the in-memory bundle and calls the core of `singular submit`, which this ticket separates from its file-reading front without changing `submit`.
- Deadlines unchanged. The Demo 1 play has Bob fold within the default ten-minute processing windows and no external reject on stage; the documentation states each command's window.
- Hosted evidence: the focused off-chain suite for every in-process row, the documented-flags job, and one new packaged devnet job whose name goes on the required list in the same change.
- Lean is silent: signing, witnesses, bundles, journal phases and submission order sit outside the model, and the transactions are the existing builders' bodies. No on-chain code, script hash or blueprint changes.

## What this ticket takes from issue 640

The provider's inclusion read (where the chain holds a transaction identity: found at a chain point with confirmations, or not on chain), the assembly export that replaces the whole key-witness set with the supplied one, and `singular submit`'s planner and core. Slice 1 starts from main before issue 640 merges; every later slice starts after it merges, and the ticket owner rebinds this list to the merged interface first.

## Slices

1. The chained view: the pure answers, the session that serves them, and their specs.
2. Staging and the external signer for fold, reject and reclaim: the write mode, staged builds, effect claims, the bundle, the waiting lines, status 19, the receipt.
3. Create's chain in the external mode, with its pending identity.
4. The journal phase: membership, the bundle state, reconciliation, admission and the report.
5. The vault mode through the core of `singular submit`.
6. The packaged devnet control, its hosted job, and the documentation with narration.

## Gate

Existing hosted commands, each as its step runs it, narrowed to what each slice can break, inside a memory-capped, time-bounded scope with standard input closed. In `offchain/`: the focused suite with the selections each slice names; lint; the component build. At the root, inside the development shell: the repository lint, the IO-ownership inventory, the narration check, the documented-flags check and its controls, the packaged vault controls, the build graph. Slice 6 adds the packaged devnet control, a CI change in this ticket. The aggregate local CI runs once on the final candidate; hosted CI is the net.
