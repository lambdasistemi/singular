# #325 functions model

> **Replay supersedes the former local proof state.** This record preserves the
> #325 recovery design and its original requirement names. Under #381, ordinary
> commands reconstruct proof state from public state-token history. They neither
> read nor write a proof mirror or `state.json`, and the journal supplies no replay
> edge or root. Recovery still appends submission phases and observations; public
> history selects the trie, including after a rollback. References below to the
> former local mirror commit are historical and are superseded by this rule.

Signatures are binding in shape; auxiliary names and placement within the modules model are the commit owner's.

- reconcile-registry `reconcile :: registry-dir -> saved-registry -> View IO -> IO Reconciliation` — classifies every unresolved journalled transaction (included, rolled back, excluded, still unknown), applies the repairs of next-ordinary-command-on-registry-any-write/transaction-whose-inclusion-was-journalled-but-whose and returns what it did and what remains. No submission capability in scope (reconciliation-module-under-offchain-cli-name-commit).
- durable-file-replacement `replaceDurably :: FilePath -> ByteString -> IO ()` — whole-file replacement that is atomic under crash, used by the mirror and `state.json` writers (crash-atomic-replacement-mirror-state-json-lives).
- unresolved-write-refusal The write refusal over an unresolved transaction takes the reconciliation result and names the case (`unknown`, `timeout`, `rolled-back`) and transaction id (acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion, next-ordinary-command-on-registry-any-write).
