# #325 tasks

> **Replay supersedes the former local proof state.** This record preserves the
> #325 recovery design and its original requirement names. Under #381, ordinary
> commands reconstruct proof state from public state-token history. They neither
> read nor write a proof mirror or `state.json`, and the journal supplies no replay
> edge or root. Recovery still appends submission phases and observations; public
> history selects the trie, including after a rollback. References below to the
> former local mirror commit are historical and are superseded by this rule.

The ticket owner stamps tasks at acceptance.

- [x] distinct-outcome-naming-in-journal-receipt-for (outcomes-durable-local-commit-reconciliation-on-next) Distinct outcome naming in journal and receipt for acknowledged, unknown, rejected, included and timeout (journal-events-existing-prepared-submitted-acknowledged-rejected, unresolved-write-refusal) (acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion; distinct-outcomes-submission-ends-command-in-exactly).
- [x] crash-atomic-mirror-state-json-replacement-f2 (outcomes-durable-local-commit-reconciliation-on-next) Crash-atomic mirror and `state.json` replacement (durable-file-replacement, crash-atomic-replacement-mirror-state-json-lives) (local-commit-after-inclusion-mirror-state-json; crash-atomic-local-files).
- [x] reconciliation-extracted-from-inspect-run-by-write (outcomes-durable-local-commit-reconciliation-on-next) Reconciliation extracted from `inspect` and run by every write before the unresolved refusal; edge applied at most once (reconcile-registry, reconciliation-module-under-offchain-cli-name-commit, local-commit-state-mirror-root-state-json, invariant-for-journalled-fold-edge-number-applications) (next-ordinary-command-on-registry-any-write, original-journal-lines-saved-bodies-printed-receipts; reconcile-on-next-command-at-most-once, append-evidence).
- [x] devnet-controls-lost-acknowledgement-interrupted-persistence-killed (outcomes-durable-local-commit-reconciliation-on-next) DevNet controls: lost acknowledgement, interrupted persistence (killed after inclusion, before and during the local commit), accepting; flake app and CI step (transaction-s-prepared-identity-signed-body-id, generated-devnet-controls-separate-singular-process-sequence; prepared-before-send, reconcile-on-next-command-at-most-once, model-effects-unchanged).
- [x] page-outcomes-user-s-next-step (outcomes-durable-local-commit-reconciliation-on-next) `docs/` page: outcomes of outcomes-durable-local-commit-reconciliation-on-next and the user's next step (describes-outcome-what-user-does-next).
- [x] rollback-exclusion-evidence-rolled-back-line-mirror (rollback-rollback-exclusion-parts-devnet-rolled-back) Rollback and exclusion evidence, `rolled-back` line, mirror and state restored to root before (journal-events-existing-prepared-submitted-acknowledged-rejected, recovery-line-names-its-evidence-chain-point, reconcile-registry) (acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion, transaction-whose-inclusion-was-journalled-but-whose; rollback-invalidates-by-appended-line-restores-mirror, append-evidence).
- [x] devnet-rolled-back-inclusion-control (rollback-rollback-exclusion-parts-devnet-rolled-back) DevNet rolled-back inclusion control (generated-devnet-controls-separate-singular-process-sequence; rollback-invalidates-by-appended-line-restores-mirror, model-effects-unchanged).
- [x] page-completed-rollback-exclusion (rollback-rollback-exclusion-parts-devnet-rolled-back) `docs/` page completed with rollback and exclusion (describes-outcome-what-user-does-next).
