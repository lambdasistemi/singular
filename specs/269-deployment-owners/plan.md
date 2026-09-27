# Extract deployment owners behind one facade

As a contributor, I want each persistent record and node decision to have one owner while the existing deployment interface and its observed failures remain stable.

## Delivery order

1. Bind the live issue, clean base, accepted Lean tree, all facade exports and moved declarations, actual callers, active workflow commands and clean baseline. Open a draft issue PR before implementation.
2. Freeze one finite gate and a source-derived command budget. The supported `deployment` and `devnet` components provide the scoped executable script-identity check. Add its command to required off-chain CI in this ticket; classify that row `MISSING-CI-JOB` until the pushed head executes it. Add a focused `cage-tests` row that invokes `attach` itself through a provider fixture and checks the returned `Attached` values, query order and a reference-script refusal. Keep the retained three-runner script's current limitation explicit.
3. The approved GLM owner extracts `Manifest`, `Mirror` and `Attach` with one-way dependencies and a thin public facade. Use existing focused `TxBuilder.Internal.Identity` and `.Lookup` adapters. Preserve the entire external export set and every moved declaration once. In particular, do not make `attach` call `verifyDeployment`: only verification currently checks the live state datum's active policy and request windows. Adapt only necessary Cabal declarations, callers and focused checks.
4. The same owner ships the high-level deployment ownership guide, module purposes, navigation, complete generated API module/source extent and curated speech. It must correct any description that attributes the callers' mirror-root check to `attach` itself.
5. The independent approved Opus auditor checks the exact candidate at checkpoints. After evidence and task/speech stamps are complete, run the exact-head local gate, verify the pushed head and CI, then hand the draft PR to epic #272 for acceptance and merge. This ticket does no #270 work.

## Evidence limits and gates

The active `offchain-lint`, `offchain-component-build`, focused `cage-tests`, root `just ci`, docs and packaging checks establish their actual source and command boundaries. A build cannot establish attachment refusal. The new local-devnet identity test must report an intact verification, then alter the recorded script identity and observe the real `deployment verify` rejection and diagnostic; it must fail if the command never reaches that boundary. That test establishes the shared compiled-release identity check, not every `attach` query. The mirror-root comparison lives in retained journey callers, so its executable status remains a separate limit until a supported caller or focused harness proves it. No historical #268 or retained-script receipt transfers to #269.

Count direct and nested tool invocations from receipts. Freeze cheap, expensive and auditor launch ceilings before worker launch; stop before an exhausted tier. Planning artifacts target 4 KiB and 90 lines; worker briefs target 12 KiB.

## Source to criterion witnesses

| Criterion | Command and witness | Limit |
| --- | --- | --- |
| Manifest and mirror preservation | Required `nix run --quiet .#cage-tests` with focused codec/path/file controls; existing off-chain lint and component build. | Fixture and local file bytes, not a chain proof. |
| Moved attachment path | Required `nix run --quiet .#cage-tests` with a new focused row calling public `attach`, reading the provider's query record and returned `Attached` values; changed or absent reference script must raise its existing named refusal. | Stub provider and finite UTxOs, not a full journey or mirror-root comparison. |
| Supported script identity | `bash offchain/deployment-identity-check.sh` in a new required off-chain CI step; runtime gate `identity-gate-v1.sh` first proved the intact and tampered public `deployment verify` path at base. | This uses `verify`, not `attach`; the new CI step is pending until pushed-head success. |
