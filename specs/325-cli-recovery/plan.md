# #325 plan

**Strategy.** Keep the #299 journal as the single record and extend it; do not introduce a second store. Recovery reads only the journal, the saved bodies and one acquired view (#323); it never submits. Rollback and exclusion are decided from chain evidence about the exact journalled transaction.

**Invariants.**

- distinct-outcomes-submission-ends-command-in-exactly Distinct outcomes (acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion): every submission ends each command in exactly one named case; the receipt carries it.
- prepared-before-send Prepared before send (transaction-s-prepared-identity-signed-body-id).
- crash-atomic-local-files Crash-atomic local files (local-commit-after-inclusion-mirror-state-json).
- reconcile-on-next-command-at-most-once Reconcile on next command, at most once per edge, without submission (next-ordinary-command-on-registry-any-write).
- rollback-invalidates-by-appended-line-restores-mirror Rollback invalidates by appended line and restores the mirror to the journalled root before (transaction-whose-inclusion-was-journalled-but-whose).
- append-evidence Append-only evidence (original-journal-lines-saved-bodies-printed-receipts).
- model-effects-unchanged Model effects unchanged (lean-governed-behaviour-unchanged-authorizations-state-root).

**Live boundaries.** The DevNet node; process kill and harness hold points (existing `SINGULAR_HARNESS_*` convention, inert when unset); a rollback produced on a generated DevNet (mechanism is the commit owner's; if none exists without new infrastructure, that is a question, not a substitute control).

**Slices.**

- outcomes-durable-local-commit-reconciliation-on-next Outcomes, durable local commit and reconciliation on the next command: acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion (without rollback), transaction-s-prepared-identity-signed-body-id, local-commit-after-inclusion-mirror-state-json, next-ordinary-command-on-registry-any-write, original-journal-lines-saved-bodies-printed-receipts, lean-governed-behaviour-unchanged-authorizations-state-root; DevNet controls lost acknowledgement, interrupted persistence and accepting; docs for those outcomes.
- rollback-rollback-exclusion-parts-devnet-rolled-back Rollback: transaction-whose-inclusion-was-journalled-but-whose and the rollback/exclusion parts of acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion; DevNet rolled-back inclusion control; docs completed (describes-outcome-what-user-does-next).

Each slice is bisect-safe and leaves `singular-cli` runnable.

**Constraints.** Owned: `offchain/cli` command flow (`Receipt`, `Session` submission path, `Entry`, `Create`, `Inspect` resolver), the local-file writers they use, recovery controls under `tools/` and their flake app and CI step, `docs/`. Not owned: `Node/Indexer*.hs` and the indexer adapter (#324), `Node/View.hs` semantics (#323). A needed change there is a question to the epic owner.

**Amendments.**

- A1 (outcomes-durable-local-commit-reconciliation-on-next, CLI controls): the earlier process-boundary clauses asserting that a write while a killed fold is unresolved is refused, and that inspecting another key observes nothing, are restated to next-ordinary-command-on-registry-any-write in `conformance/lib/Conformance/Cli/Controls.hs` and `tools/demo1_cli_journey.sh`: the next write either reconciles the fold from chain evidence and proceeds (applied and observed once, never resubmitted) or, while the fold is not on chain, is refused before submitting, naming its case and transaction. R299-05's "no implicit repair" continues to govern stale, concurrent or altered local state.
- A2 (rollback-rollback-exclusion-parts-devnet-rolled-back, rulings on rollback): exclusion is decided only from chain evidence — not included at a view whose tip slot is past the transaction's validity upper bound. A transaction without an upper bound stays unresolved after a rollback (named residual; giving every built transaction an upper bound is a follow-up). The generated-DevNet rollback control restores a node database snapshot and proves the block is gone and the inputs live again before asserting the CLI's behaviour; it is labelled a DevNet mechanism, not a public-chain fork.
