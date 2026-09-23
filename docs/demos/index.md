# Dated demo plays

As a presenter, I want each dated play to show a keripy `kli` identity and a `ckeri` transaction on Cardano preprod, so that the audience can inspect the identity event and ledger result together. A cast appears only after the connected preprod run has produced transaction IDs and fresh readbacks.

## Choose a dated play

| Target | Story and play | Current boundary |
| --- | --- | --- |
| 8 October 2026 | [Registry handoff](../first-demo.md) | [Draft PR #250](https://github.com/lambdasistemi/singular/pull/250) and its [preview](https://preview.dev.plutimus.com/lambdasistemi/singular/pr-250/docs/first-demo/) contain the preprod play plan; no connected Singular cast yet. |
| 23 October 2026 | [Maintain and recover a name](d02-naming.md) | Preprod `kli` + `ckeri` + Singular play plan; connected naming release and mapping remain open. |
| 30 October 2026 | [Name Your Address preprod stretch](d03-escrow.md) | Not yet playable as the connected preprod journey. |

The Cardano KERI [consumer mapping](https://github.com/lambdasistemi/cardano-keri/issues/324) is separate from Singular naming. Naming is not a prerequisite for Cardano KERI's identity path.
