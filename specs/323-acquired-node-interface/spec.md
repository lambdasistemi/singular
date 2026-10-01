# #323 Ordinary CLI through an acquired node interface

Parent epic #322. Base `origin/main` 3f04e50d293b80360a3234ebf3114abc8172d851. Application model pin `de34300540223ccedf1ca85216b131fd09a148b4` (`conformance/lib/Conformance/Cli/Controls.hs`). Node-clients pin `0e73121dc1df516b69d69bdd554b12bebd28d072` (`offchain/cabal.project`), which already provides `withAcquired`, `QueryHandle` and `LedgerSnapshot` (era, chain point, tip slot) in `Cardano.Node.Client.Provider`.

**Story.** As a CLI user, I run the ordinary `singular registry create`, `insert`, `update`, `terminate` and `inspect` against a configured node, and every preview, fee/outlay decision, built body and readback of one operation is derived from one acquired chain view: the same protocol parameters, selected inputs, registration facts, time conversion and script evaluation, at one identified chain point.

**Requirements.**

- R1 One injected read interface with an explicit acquire step. An operation acquires one view; the view names its chain point (network, era, slot, block hash) and answers UTxO reads, protocol parameters, script-credential registration, POSIX-time-to-slot conversion and script evaluation from that one acquired ledger state. A wrapper that issues independent per-call queries is not a view.
- R2 Within one operation, preview, fee/outlay decisions and the built body consume one view only. Protocol parameters are fetched once per view; no builder fetches them again.
- R3 Read capabilities cannot submit: neither the read interface nor a view carries submission. The write capability accepts only signed transactions, distinguished from unsigned ones by type.
- R4 CLI commands (`offchain/cli`) and transaction builders (`offchain/lib`) depend on the interface's capabilities only. `NodeMode`, `NodeSession`, `NodeReads`, sockets, the process-global follower and backend selection are confined to adapter construction and fixture startup. A CI source check enforces the confinement over `offchain/cli` and `offchain/lib` against an explicit allowlist and is shown able to fail.
- R5 Generated DevNet and an external node reach `singular-cli` through the same node adapter; their differences live in startup composition only.
- R6 A deterministic in-memory adapter implements the same interface. A reached interleaving control shows that a protocol-parameter change and a UTxO change made between acquisition and build cannot enter the operation; the P1/P2 race from the #300 review (parameters fetched for preview, fetched again by the builder) is shown on the pre-change path and rejected after it.
- R7 Lean-governed behaviour is unchanged: authorizations, state/root effects, custody, refunds and refusals. Existing conformance, CLI and journey suites stay green.
- R8 Every ordinary command runs end-to-end on a generated DevNet through the new interface, and each write journals the chain point of the view it was built from.
- R9 `docs/` describes the backend configuration a user sets.

**Rejection behaviour.** Acquiring at the chain origin (no block hash), using a view after its acquire scope has ended, and a lost node connection during an acquire are explicit failures with a named outcome class; none is reported as an empty UTxO set or as absence.

**Non-goals.** Indexer-backed reads and node/indexer point agreement (#324); recovery after uncertain submission or rollback (#325); the installed-artifact contract suite and migration of journeys, deployment, insert-active, update-terminal and e2e runners beyond what compiles (#326); validator or Lean changes; Demo 1 (#300/#301).

**Observable success.** `nix develop --quiet -c just ci` and every CI job green on the PR head; the adapter and interleaving specs named in the PR; the DevNet CLI journey (`nix run --quiet .#demo1-cli-check`) green with each write receipt carrying a view chain point.
