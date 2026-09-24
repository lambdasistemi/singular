# Dated demo plays

As a presenter, I want each dated play to show a keripy `kli` identity and a `ckeri` transaction on Cardano preprod, so that the audience can inspect the identity event and ledger result together. A cast appears only after the connected preprod run has produced transaction IDs and fresh readbacks.

For Cardano KERI identity actions, the planned source is its local follower indexer: `ckeri` writes use `--store PATH` or `CKERI_STORE`, and reads use explicit `--backend local --store PATH` (or an indexer-backed endpoint where supported). Record the indexed chain point and freshness. Singular's session follower confirms new preprod transactions, but older address outputs still come from its node provider; [#107](https://github.com/lambdasistemi/singular/issues/107) tracks a persistent registry follower. A Koios asset lookup alone does not close these demo stories. The [Cardano KERI indexer contract](https://github.com/lambdasistemi/cardano-keri/blob/docs/demo-series-2026-2027/docs/demos/index.md#indexer-contract-for-the-dated-plays) tracks the identity side. The older V1 cast used Koios and remains historical evidence.

## Choose a dated play

| Target | Story and play | Current boundary |
| --- | --- | --- |
| 8 October 2026 | [Registry handoff](../first-demo.md) | The merged registry handoff page contains the preprod play plan; no connected Singular cast yet. |
| 23 October 2026 | [Maintain and recover a name](d02-naming.md) | Preprod `kli` + `ckeri` + Singular play plan; connected naming release and mapping remain open. |
| 30 October 2026 | [Name Your Address preprod stretch](d03-escrow.md) | Not yet playable as the connected preprod journey. |

The Cardano KERI [consumer mapping](https://github.com/lambdasistemi/cardano-keri/issues/324) is separate from Singular naming. Naming is not a prerequisite for Cardano KERI's identity path.

## Planned major release tags

| Singular milestone | Plays | Planned tag | Gate |
| --- | --- | --- | --- |
| Registry handoff | 8 October | `v1.0.0` | Released archive and connected preprod registry replay. |
| Naming and escrow | 23 and 30 October | `v2.0.0` | 30 October connected preprod acceptance. |

These tags are release targets, not published artifacts. Candidate demos cite their actual build and manifest until the relevant milestone release is cut.
