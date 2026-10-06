# #325 modules model

> **Replay supersedes the former local proof state.** This record preserves the
> #325 recovery design and its original requirement names. Under #381, ordinary
> commands reconstruct proof state from public state-token history. They neither
> read nor write a proof mirror or `state.json`, and the journal supplies no replay
> edge or root. Recovery still appends submission phases and observations; public
> history selects the trie, including after a rollback. References below to the
> former local mirror commit are historical and are superseded by this rule.

- singular-cli-receipt-stays-one-owner-journal `Singular.CLI.Receipt` stays the one owner of journal events and outcome classes; it gains the rollback and exclusion events and the receipt's naming of a submission's case (journal-events-existing-prepared-submitted-acknowledged-rejected, recovery-line-names-its-evidence-chain-point).
- reconciliation-module-under-offchain-cli-name-commit A reconciliation module under `offchain/cli` (name is the commit owner's) owns inclusion, rollback and exclusion evidence and the mirror/state/observation repair. It is extracted from `Singular.CLI.Inspect`'s resolver, which then calls it; every write's attach calls it before the unresolved refusal (reconcile-registry). It depends on the read interface (`View`) only; it has no submission capability.
- crash-atomic-replacement-mirror-state-json-lives Crash-atomic replacement of the mirror and `state.json` lives with their existing writers (`Singular.CLI.Registry`, `Singular.Registry.Deployment.Mirror`); no second writer of either file exists (durable-file-replacement).
- devnet-recovery-controls-live-beside-existing-cli DevNet recovery controls live beside the existing CLI controls under `tools/`, exposed as a flake app and run by a CI step (generated-devnet-controls-separate-singular-process-sequence).

Dependency direction is unchanged: `offchain/cli` → read/write capabilities (#323) → node adapter. Nothing here reaches `NodeSession` or `NodeMode`.
