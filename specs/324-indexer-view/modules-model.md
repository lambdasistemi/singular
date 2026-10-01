# #324 modules model

Dependency direction: composition → indexer adapter (M2) → read interface (#323 `Singular.Registry.Provider`) and node adapter (#323 `Singular.Registry.Node.View`); M2 → pinned `lib-utxo-indexer` handle and follower.

- M1 `Singular.Registry.Node.Indexer` (existing, `offchain/node-internal`): keeps follower ownership, confirmation waits and `followedProvider`. `followChain` hands the follower a write path Singular controls (M3). `indexedReads` is removed; `followedProvider` returns M2's provider.
- M2 indexer adapter (new module under `Singular.Registry.Node`, name the commit owner's): builds a `Provider IO` from a node provider plus a gated index (D2) and follower readiness. Owns point agreement, the named failure classes (D3) and the bounded wait. Library code, so #326's contract suite reuses it.
- M3 gated index (inside M2 or its own module): wraps the pinned `IndexerHandle` so writes and view-holding exclude each other and the index's applied point is known without a separate upstream read.
- M4 composition (`offchain/cli` startup, S2 only): selects node or indexer backend from configuration once.

Promotion: none. A future upstream read view over the index (gap G1, node-clients) would replace M3; record the dependency, do not build it here.
