# #326 plan

**Strategy.** One suite, written once against `Provider`/`View`, instantiated per adapter. Consumers move to the capabilities #323 froze; the confinement check grows to cover them instead of a second checker appearing. Artifact verification and the evidence page reuse the release and conformance pipelines; nothing new publishes.

**Invariants.**

- I1 One suite, every adapter (R1, R2): the same case list runs against each adapter; a per-adapter exception is named in the suite's output.
- I2 One view, one point (R2, R6): every read an operation makes, harness included, comes from one view whose point names slot and block hash.
- I3 No node call inside a view by another route (R3).
- I4 Signing is the only constructor of `SignedTx` (R4).
- I5 Backend and mode selection confined to adapter construction and fixture startup, by source check (R6).
- I6 Documented surface equals the binary's surface (R7, R10).
- I7 Evidence computed, never typed (R8, R9): every published verdict and state is derived from receipts, sums or the binary's own output.
- I8 Model effects unchanged (R11).

**Live boundaries.** Generated DevNet node (ordinary adapter, generated and external legs); the GitHub release assets of tag `v0.8.0`; the docs site build.

**Slices.** Ordered by the scope-cut rule (contract suite, then migration, then artifact).

- S1 Contract suite and interface controls: R1, R2, R3, R4, R5, R11. Node and in-memory first; the indexer instance binds after #324 lands on main (one rebase).
- S2 Consumer migration and confinement: R6, R7, R11.
- S3 Artifact and evidence: R8, R9, R10, R11, and the docs that describe them.

Each slice is bisect-safe and leaves `singular` runnable.

**Cut record.** Deadline 2026-10-02 morning. S1 is the floor. A slice not accepted by 2026-10-02T07:00Z is cut: its unmet requirements are filed as follow-up issues under #322, named in the PR, and the PR completes with the accepted slices. The v0.8.0 verification receipt exists only after the epic owner merges release PR #203; the PR states the assets it verified (name, sha256, tag) once that run is green.

**Constraints.** Owned: `offchain/test` contract suite and its registration, the consumers named in R6 and their compile-only callers, `tools/node_confinement_*` and its allowlist, CI workflow steps for R3/R4/R5/R7/R8, release assembly for R8, conformance evidence rendering and `docs/`. Not owned: `Provider.hs`/`View.hs` semantics (frozen by #323) and `Node/Indexer*.hs` (#324): a needed change there is a question. No public-chain submission, no funded keys.


**Amendments.**

- A1 (S1, gate synthesis): the suite is the `contract-tests` component with flake apps `contract-tests` and `contract-external`, run by the registry.yml `contract` job; an adapter's unsupported cases are a fixed list in its harness, each reported as not supported by that adapter with the reason, never counted as passed. I3 is enforced at run time by the node session: a node call issued from inside an acquired view by another route fails by name (`NodeCallInView`) instead of hanging.
- A2 (order, operator ruling): slices run serially, one pair at a time, in the order S1, S3a (R8, R10), S3b (R9), S2.
- A3 (R4 restated): outside `Node/Submit.hs` no route constructs a `SignedTx` (constructor, coerce, record syntax), proved by fixtures with a control; Submit's export list is frozen against a committed allowlist with a planted-export control. An already allowed export changed to forge, or an instance added in Submit, is caught by review, not CI.
- A4 (R10): the `SINGULAR_HARNESS_*` hooks are the production CLI's test-harness hooks, inert when unset (a control proves it on the ordinary journey) and documented; moving them out of the released binary is a follow-up.
- A5 (D2 extended): a spec may be allowlisted by the confinement check only as a backend's own test, its entry naming the backend module it exercises, which must itself be an allowlisted backend module; consumer specs never qualify. Components the inventory classifies `unverified` are excluded from the scan by derivation.
