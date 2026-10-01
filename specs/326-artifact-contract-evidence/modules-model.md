# #326 modules model

- M1 A contract-suite module under `offchain/test` owns the shared case list, parameterised by a `Provider IO` plus the adapter's harness (how to advance the chain, lose the connection, start at origin). Per-adapter instances live beside it; the existing per-adapter specs keep only adapter-specific cases (D1, F1).
- M2 The external-node leg is a test entry (or flake app) that receives a socket path and network magic and builds the ordinary node adapter from them, the same constructor the CLI uses (R5).
- M3 Compile-failure controls (R4) and the I3 control live in CI-run checks beside the confinement check under `tools/`; each has a fixture that must be refused.
- M4 The consumers of R6 depend on `Provider`/`View` and `SignedSubmitter` only; each one's composition root (its `Main` or fixture startup) is where a backend is constructed. `tools/node_confinement_check.sh` scans every one of them.
- M5 Release assembly gains the model-revision member (D3); a verification app under `tools/` with its flake app consumes published assets (F3).
- M6 The conformance evidence page is rendered from receipts by the conformance package and checked by `docs-check` (D4, F4).

Dependency direction: consumers → capabilities (#323) → adapters. Nothing outside composition roots reaches `NodeSession`, `NodeMode` or a raw `Submitter`.
