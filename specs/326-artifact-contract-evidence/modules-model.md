# #326 modules model

- contract-suite-module-under-offchain-test-owns A contract-suite module under `offchain/test` owns the shared case list, parameterised by a `Provider IO` plus the adapter's harness (how to advance the chain, lose the connection, start at origin). Per-adapter instances live beside it; the existing per-adapter specs keep only adapter-specific cases (contract-case-name-kind-success-refusal-consistency, F1).
- external-node-leg-test-entry-or-flake The external-node leg is a test entry (or flake app) that receives a socket path and network magic and builds the ordinary node adapter from them, the same constructor the CLI uses (node-adapter-s-external-leg-already-running).
- compile-failure-controls-control-live-in-ci Compile-failure controls (signedtx-can-be-obtained-by-signing-ci) and the no-node-call-inside-view-by-another control live in CI-run checks beside the confinement check under `tools/`; each has a fixture that must be refused.
- consumers-depend-on-provider-view-signedsubmitter-one The consumers of journeys-deployment-insert-active-update-terminal-runners depend on `Provider`/`View` and `SignedSubmitter` only; each one's composition root (its `Main` or fixture startup) is where a backend is constructed. `tools/node_confinement_check.sh` scans every one of them.
- release-assembly-gains-model-revision-member-verification Release assembly gains the model-revision member (release-model-revision-application-model-commit-release); a verification app under `tools/` with its flake app consumes published assets (F3).
- conformance-evidence-page-rendered-from-receipts-by The conformance evidence page is rendered from receipts by the conformance package and checked by `docs-check` (evidence-state-per-requirement-executed-or-partial, F4).

Dependency direction: consumers → capabilities (#323) → adapters. Nothing outside composition roots reaches `NodeSession`, `NodeMode` or a raw `Submitter`.
