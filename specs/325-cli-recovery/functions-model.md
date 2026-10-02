# #325 functions model

Signatures are binding in shape; auxiliary names and placement within the modules model are the commit owner's.

- F1 `reconcile :: registry-dir -> saved-registry -> View IO -> IO Reconciliation` — classifies every unresolved journalled transaction (included, rolled back, excluded, still unknown), applies the repairs of next-ordinary-command-on-registry-any-write/transaction-whose-inclusion-was-journalled-but-whose and returns what it did and what remains. No submission capability in scope (reconciliation-module-under-offchain-cli-name-commit).
- F2 `replaceDurably :: FilePath -> ByteString -> IO ()` — whole-file replacement that is atomic under crash, used by the mirror and `state.json` writers (crash-atomic-replacement-mirror-state-json-lives).
- F3 The write refusal over an unresolved transaction takes the reconciliation result and names the case (`unknown`, `timeout`, `rolled-back`) and transaction id (acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion, next-ordinary-command-on-registry-any-write).
