# #325 modules model

- M1 `Singular.CLI.Receipt` stays the one owner of journal events and outcome classes; it gains the rollback and exclusion events and the receipt's naming of a submission's case (D1, D2).
- M2 A reconciliation module under `offchain/cli` (name is the commit owner's) owns inclusion, rollback and exclusion evidence and the mirror/state/observation repair. It is extracted from `Singular.CLI.Inspect`'s resolver, which then calls it; every write's attach calls it before the unresolved refusal (F1). It depends on the read interface (`View`) only; it has no submission capability.
- M3 Crash-atomic replacement of the mirror and `state.json` lives with their existing writers (`Singular.CLI.Registry`, `Singular.Registry.Deployment.Mirror`); no second writer of either file exists (F2).
- M4 DevNet recovery controls live beside the existing CLI controls under `tools/`, exposed as a flake app and run by a CI step (R8).

Dependency direction is unchanged: `offchain/cli` → read/write capabilities (#323) → node adapter. Nothing here reaches `NodeSession` or `NodeMode`.
