# #324 plan

**Strategy.** Replace the point-agnostic `indexedReads` in `Singular.Registry.Node.Indexer` with an indexer adapter that yields #323 views at one chain point. Fact at the pin: the chain-sync follower mutates the index only through the caller-owned `IndexerHandle` record that Singular passes to `withChainSyncFollower` (`applyAtSlot`, `rollbackTo`, `pruneRollbacks`). Singular therefore owns the index's write path: while a view is held, the index does not advance, and a view is admitted only when the index's applied point equals the node view's point. The devnet produces ten blocks per second and the pinned node client cannot acquire at a named point, so agreement must be reached deterministically, never by chance. `followedProvider` keeps its signature; its devnet consumers (journeys, e2e) exercise the adapter live in S1.

**Invariants.**

- I1 one-point view: every read of one indexer-adapter view (node fields and indexer address reads) is answered at the view's chain point. Fails if an address read returns content applied after, or absent at, the view point.
- I2 immutable index during a view: an apply or rollback attempted while a view is held takes effect only after the view closes. Fails if a read inside the view observes it.
- I3 named refusal: lag, fork, tip-started or filtered coverage, restoration in progress, disconnection and unsupported capability each fail with a distinct named class carrying the points; none yields an empty or partial answer. Fails if any of them returns a value.
- I4 reachability: on a live DevNet the adapter admits views (agreement is reached, not rare). Fails as a lag refusal or timeout in the journey or e2e.
- I5 no deadlock: confirmation waits (`awaitIndexed`) and submissions are never inside a view (#323 I9 carried); the held index releases on normal and exceptional view exit.
- I6 selection at startup only: `singular-cli` reaches the indexer adapter through composition configuration; commands and builders do not name it.
- I7 model preserved: conformance, CLI, journey and e2e verdicts unchanged.
- I8 no upstream reimplementation: no index state reconstruction, history replay or chain-sync logic copied into Singular.

**Live boundaries.** In-process chain-sync follower and in-memory indexer over the DevNet node socket; node LocalStateQuery acquire.

**Slices.**

- S1 adapter and contract spec (T324-01..03): the adapter, its failure classes, `followedProvider` on it, the contract spec with positive and content-dependent negative controls. Independent of #323 S2.
- S2 CLI selection, DevNet journey, docs (T324-04..05): parks until #323 merges and this branch is rebased on main.

**Constraints.** No `lean/`, validator, blueprint or conformance-row change. `Singular.Registry.Provider` and the #323 adapters are not edited; failure classes live in the indexer adapter's own module. No node-clients pin change. Journal, mirror and recovery flow are #325's.
