# #324 plan

**Strategy.** Replace the point-agnostic `indexedReads` in `Singular.Registry.Node.Indexer` with an indexer adapter that yields #323 views at one chain point. Fact at the pin: the chain-sync follower mutates the index only through the caller-owned `IndexerHandle` record that Singular passes to `withChainSyncFollower` (`applyAtSlot`, `rollbackTo`, `pruneRollbacks`). Singular therefore owns the index's write path: while a view is held, the index does not advance, and a view is admitted only when the index's applied point equals the node view's point. The devnet produces ten blocks per second and the pinned node client cannot acquire at a named point, so agreement must be reached deterministically, never by chance. `followedProvider` keeps its signature; its devnet consumers (journeys, e2e) exercise the adapter live in adapter-contract-spec-adapter-its-failure-classes.

**Invariants.**

- one-point-view-read-one-indexer-adapter one-point view: every read of one indexer-adapter view (node fields and indexer address reads) is answered at the view's chain point. Fails if an address read returns content applied after, or absent at, the view point.
- immutable-index-during-view-apply-or-rollback immutable index during a view: an apply or rollback attempted while a view is held takes effect only after the view closes. Fails if a read inside the view observes it.
- named-refusal-lag-fork-tip-started-or named refusal: lag, fork, tip-started or filtered coverage, restoration in progress, disconnection and unsupported capability each fail with a distinct named class carrying the points; none yields an empty or partial answer. Fails if any of them returns a value.
- reachability-on-live-devnet-adapter-admits-views reachability: on a live DevNet the adapter admits views (agreement is reached, not rare). Fails as a lag refusal or timeout in the journey or e2e.
- no-deadlock-confirmation-waits-awaitindexed-submissions-never no deadlock: confirmation waits (`awaitIndexed`) and submissions are never inside a view (#323 indexer-actually-served-devnet-journey-proves-that carried); the held index releases on normal and exceptional view exit.
- selection-at-startup-singular-cli-reaches-indexer selection at startup only: `singular-cli` reaches the indexer adapter through composition configuration; commands and builders do not name it.
- model-preserved-conformance-cli-journey-e2e-verdicts model preserved: conformance, CLI, journey and e2e verdicts unchanged.
- no-upstream-reimplementation-no-index-state-reconstruction No index state reconstruction or chain-sync logic is copied into this indexer adapter. The ordinary CLI separately reconstructs registry proofs from public state-token history under #381; that replay does not reimplement the upstream indexer.

**Live boundaries.** In-process chain-sync follower and in-memory indexer over the DevNet node socket; node LocalStateQuery acquire.

**Slices.**

- adapter-contract-spec-adapter-its-failure-classes adapter and contract spec (gated-index-indexed-point-follower-writes-through..03): the adapter, its failure classes, `followedProvider` on it, the contract spec with positive and content-dependent negative controls. Independent of #323 cli-selection-devnet-journey-on-main-after.
- cli-selection-devnet-journey-on-main-after CLI selection, DevNet journey, docs (backend-selected-by-configuration-at-cli-startup..05), on main after #323 (`8cd0bcc7`).

**cli-selection-devnet-journey-on-main-after decisions (mandate v2).**

- The backend is one more composition setting of `singular` (node, the default, or indexer), resolved once in `Singular.CLI.Node` (#323's composition module, allowlisted for the confinement check) for reads and writes alike. Commands and builders do not name it.
- The indexer backend follows the node's chain from origin, so its coverage is every output a block carried. Outputs that exist only in the genesis ledger state are outside that coverage. The journey's wallets are funded by transactions (`devnet --fund-skey`), so they are covered.
- Each refusal class reaches the user as a named one-line diagnostic naming the points or setting involved, and a non-zero exit before any submission; never an empty registry, an empty wallet or a stack trace.

**cli-selection-devnet-journey-on-main-after invariants.**

- indexer-actually-served-devnet-journey-proves-that indexer actually served: the DevNet journey proves that the indexer adapter answered the commands' reads, through an observable the node path cannot produce. Fails if the same journey passes through the node adapter.
- coverage-honesty-wallet-whose-outputs-index-does coverage honesty: a wallet whose outputs the index does not cover is refused with the coverage diagnostic, never read as empty. Fails if a genesis-funded key reads as holding nothing.
- ordinary-command-create-insert-update-terminate-inspect every ordinary command (`create`, `insert`, `update`, `terminate`, `inspect`) runs end-to-end on a generated DevNet through the indexer backend, every write's journal carrying its view point (#323 R8).
- selection-at-startup-singular-cli-reaches-indexer selection at startup only is checked by #323's confinement check; any new allowlist entry carries its one-line reason.

**Constraints.** No `lean/`, validator, blueprint or conformance-row change. `Singular.Registry.Provider` and the #323 adapters are not edited; failure classes live in the indexer adapter's own module. No node-clients pin change. The ordinary CLI keeps its submission journal under #325 and derives proof state from public replay under #381, without a persisted mirror or saved root.
