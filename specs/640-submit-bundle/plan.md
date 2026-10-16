# Plan for submitting a bundle

Issue 640. One pull request, three slices of at most 90 minutes each.

## Decisions

- Witnesses come as repeatable `--witnesses FILE`; a directory expands to its `.witness` files.
- The provider gains one read: where a transaction sits on the provider's chain, found with a chain point and confirmations, or not found. Its shape matches the `inclusion` read of the planned ledger-client library, so moving it later is a rename.
- Expiry uses one tip read before any send; the validity upper bound is exclusive; no bound means never expired.
- One new export in the signing module builds the opaque signed transaction from a transaction and verified witnesses; the frozen export list names it and the export-freeze check is a gate row.
- The receipt is JSON like the registry commands, with the optional `--receipt FILE`; its chain facts are read after the run.
- Hosted evidence: devnet rows in the existing end-to-end lane for node, boot, insert and config, and offline packaged refusals in the existing flags-and-refusals step. The packaged devnet control comes with issue 641.
- Lean is silent: submission order and witnesses sit outside the model. The journal phase moved to issue 641.

## Slices

- Provider read and assembly export, with unit specs.
- The planner: witness matching, needed keys, completeness, expiry, skip, order, and its specs.
- The verb, receipt, documentation with narration, and the end-to-end rows.

## Gate

Existing hosted commands, each as its step runs it. In `offchain/`: the focused suite with the submit and provider selections; the end-to-end lane for node, boot, insert and config; lint; the component build; the export-freeze check. At the root, inside the development shell: the repository lint, the effect-site inventory, the narration check; the documented-flags check and its controls; the wallet vault controls; the build graph check. Every run goes through a memory-capped, time-bounded scope with stdin closed.
