# Modules

| Module | Responsibility | Depends on | Must not take |
|---|---|---|---|
| `Singular.Model` | `trieErase`; both deletion arms store its result and commit `rootOf` of that trie | existing `Trie`, `applyEdge`, `Reachable` | a stored `.unknown` leaf |
| `Singular.Lemmas` | restated `applyEdge_deleteAbsent` and `applyEdge_deleteActive` | `Singular.Model` | a new mint, custody or refund conclusion |
| `Singular.Statements` | restated deletion inversions and the unknown-trie refusal row | the lemmas | a changed error string |
| `lean/DriverMain.lean` | regenerates the driver corpus from the statements | the restated surface | a hand-edited corpus |
| `Conformance.Edge.Sequence` | the re-admitted `deleteAbsent` step | the live interpreter | a second interpreter |
| `Conformance.Run.expectedSequenceOutcome` | `deleteAbsent` joins the agreeing outcomes | the sequence receipt | the `deleteActive` outcome |
| `Conformance.Book` | stops typing the disagreement | the sequence program and the receipt | a typed agreement sentence |
| `conformance/BOOK.md` | generated from one devnet book run | the receipt | a hand merge |

`Conformance.Compare.Registration` is unchanged. The off-chain builder and the on-chain validators are unchanged.
