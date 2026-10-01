# #323 plan

**Strategy.** Reuse the existing seam `Singular.Registry.Provider`: replace its record of independent queries with a read interface whose only entry is an acquire step yielding a view (data-model D1–D3). The node adapter wraps upstream `withAcquired` from the pinned node-clients, so one view is one LocalStateQuery acquired state and its chain point comes from that state's `LedgerSnapshot`. The in-memory adapter snapshots a mutable chain value at acquire. Builders and CLI commands take a view (or values read from it) instead of a provider; `NodeMode`/`NodeSession` move behind a composition boundary.

**Invariants (each has an observable failure and success).**

- I1 one-view-per-operation: an operation's preview, fee/outlay decision and built body cite the same view chain point and parameters. Fails if any builder or command path fetches protocol parameters or UTxOs outside the view it was given.
- I2 acquired-not-wrapped: the node view's reads are served from one acquired ledger state. Fails if a view field issues an independent one-shot query.
- I3 point-identity: every view carries network, era, slot and block hash; origin is refused. Fails if a write journals a point that differs from its view's point, or if an origin acquire yields a view.
- I4 no-late-entry: a parameter or UTxO change made after acquisition never appears in that operation's preview or body; a fresh acquisition does see it (reached control). Fails if the mutation is unobserved by a fresh acquire (control unreached) or observed by the old view.
- I5 read-cannot-submit / signed-only-write: no read type exposes submission; the write capability's argument type is constructible only by signing.
- I6 confinement: the CI source check passes on the head and fails on a planted `NodeMode` import in a non-allowlisted `offchain/cli` or `offchain/lib` module.
- I7 model-preserved: conformance rows, CLI journey and controls, journey runners and e2e stay green with unchanged verdicts.
- I8 scope-closed: a view used after its scope or across a lost connection fails explicitly with a named class, never as empty/absent.
- I9 no-node-call-in-view: no one-shot node query, submission or confirmation wait runs inside a view scope. Fails as a hang on the shared LocalStateQuery channel; judged by code reading, no CI row (residual).

**Clarification C-1 (A-002).** "Operation" means building one transaction and its preview: one transaction, one view, closed before signing and submitting. Functions that sign and submit one or several transactions take the read interface and acquire one fresh view per transaction; read-backs after confirmation acquire their own view.

**Live boundaries.** Node LocalStateQuery acquire/release; DevNet via `nix run .#devnet` inside `demo1-cli-check`; external node by socket and magic.

**Slices (serial, bisect-safe, one commit each).**

- S1 interface, adapters, builders: D1–D4 types, node adapter (M2), in-memory adapter (M3), every builder in `offchain/lib` consuming a view, compile-forced consumers adapted with one acquire per operation, interleaving/race spec (R1, R2, R3, R6, R7; I1–I5, I7, I8).
- S2 CLI composition and confinement: CLI commands on injected capabilities, `NodeMode`/`NodeSession` confined, write journals the view point, CI source check with its failing control, DevNet journey green, docs page (R4, R5, R8, R9; I3, I6, I7).

**Constraints.** No `lean/`, validator, blueprint or conformance-row change. Indexer-backed providers (`Singular.Registry.Node.Indexer.followedProvider`) may change only to compile and must not be reachable from `singular-cli`; their point agreement is #324's. Journeys, deployment, insert-active, update-terminal and e2e change only to compile, each operation acquiring one view.
