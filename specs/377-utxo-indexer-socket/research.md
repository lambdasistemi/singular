# Research the replacement extent

As a reviewer, I want every old-backend dependency accounted for, so deleting
an adapter cannot leave an orphaned test, misleading guide or broken confirmation.
This is source discovery at 3b7a06bee8850ad6745f61ff5be7631fb8274909, not behavioral acceptance.

## Quantified tree inventory

The denominator is all `git ls-files -z` paths at the bound base: 1261
tracked paths, 1261 non-NUL textual files scanned. Case-insensitive matching
for `indexer|IndexGate|originProvider|followingGate|withDevnetIndexer|StubFollowing`
discovers 100 matching files and 1000 matching lines. The
method finds the known legacy adapter and also the unrelated HTTP mock, a
positive control against confusing no matches with absence. It includes speech,
Cabal declarations, Nix wiring, docs, harnesses and historical specs. This table
is generated over that extent; no file list from the brief is its denominator.

| Discovered path | Matching lines | Disposition to verify during replacement |
| --- | ---: | --- |
| `.github/workflows/registry.yml` | 5 | Inspect CI, archive or harness carrier; replace only legacy backend references |
| `CHANGELOG.md` | 6 | Historical record; keep clearly superseded, subject to docs checks |
| `conformance/app-cli/Conformance/Cli/Admission.hs` | 8 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/app-cli/Conformance/Cli/Backend.hs` | 14 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/app/Conformance/Run/Node.hs` | 3 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/evidence/page/contract/external.jsonl` | 11 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/evidence/page/contract/generated.jsonl` | 22 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/lib/Conformance/Cli/Controls.hs` | 101 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/test/Conformance/Support/CliAttach.hs` | 9 | Inspect dependency or unrelated index use; no blanket deletion |
| `conformance/test/Conformance/Support/CliControls.hs` | 38 | Inspect dependency or unrelated index use; no blanket deletion |
| `docs/conformance-evidence.md` | 15 | Update active claims and removed-module references |
| `docs/conformance-evidence.speech.json` | 6 | Redo with any changed companion page; history stays versioned |
| `docs/demo1-preprod.md` | 7 | Update active claims and removed-module references |
| `docs/demo1-preprod.speech.json` | 3 | Redo with any changed companion page; history stays versioned |
| `docs/demos/index.md` | 1 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `docs/offchain-node-ownership.md` | 20 | Update active claims and removed-module references |
| `docs/offchain-node-ownership.speech.json` | 4 | Redo with any changed companion page; history stays versioned |
| `docs/prior-art.md` | 1 | Update active claims and removed-module references |
| `docs/prior-art.speech.json` | 1 | Redo with any changed companion page; history stays versioned |
| `docs/singular-node.md` | 5 | Update active claims and removed-module references |
| `docs/singular-node.speech.json` | 4 | Redo with any changed companion page; history stays versioned |
| `flake.nix` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `offchain/cli/src/Singular/CLI/Command.hs` | 1 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/cli/src/Singular/CLI/Inspect.hs` | 1 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/cli/src/Singular/CLI/Node.hs` | 13 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/contract-test/Main.hs` | 7 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/contract-test/external.sh` | 1 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/e2e-test/Singular/Registry/E2E/Fixture.hs` | 6 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/lib/Singular/Registry/Node.hs` | 8 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/node-internal/Singular/Registry/Node/Confirmation.hs` | 10 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/node-internal/Singular/Registry/Node/IndexGate.hs` | 32 | Delete legacy address mechanism; migrate shared confirmation duties first |
| `offchain/node-internal/Singular/Registry/Node/Indexer.hs` | 65 | Delete legacy address mechanism; migrate shared confirmation duties first |
| `offchain/node-internal/Singular/Registry/Node/IndexerView.hs` | 61 | Delete legacy address mechanism; migrate shared confirmation duties first |
| `offchain/node-internal/Singular/Registry/Node/Options.hs` | 5 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/node-internal/Singular/Registry/Node/Session.hs` | 23 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/node-internal/Singular/Registry/Node/Wait.hs` | 2 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/singular-registry.cabal` | 11 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Main.hs` | 2 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/CLISpec.hs` | 5 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/PhaseLogFixture.hs` | 1 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/ContractMemory.hs` | 15 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/ContractNode.hs` | 10 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/ContractSuite.hs` | 5 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/IndexerRig.hs` | 37 | Delete legacy address mechanism; migrate shared confirmation duties first |
| `offchain/test/Singular/Registry/IndexerViewSpec.hs` | 73 | Delete legacy address mechanism; migrate shared confirmation duties first |
| `offchain/test/Singular/Registry/NodeCleanupSpec.hs` | 14 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/NodeSpec.hs` | 7 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/NodeWaitSpec.hs` | 44 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/PhaseLogSpec.hs` | 11 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `offchain/test/Singular/Registry/StubFollowing.hs` | 17 | Migrate imports, composition, manifests or tests; preserve surviving obligations |
| `onchain-release/DEMO1.md` | 8 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `specs/110-representative-name/spec.md` | 3 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/26-live-links/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/266-node-responsibilities/data-model.md` | 4 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/266-node-responsibilities/functions-model.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/266-node-responsibilities/modules-model.md` | 3 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/266-node-responsibilities/modules-model.speech.json` | 2 | Redo with any changed companion page; history stays versioned |
| `specs/266-node-responsibilities/plan.md` | 3 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/266-node-responsibilities/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/266-node-responsibilities/spec.speech.json` | 1 | Redo with any changed companion page; history stays versioned |
| `specs/281-bounded-confirmation/modules-model.md` | 2 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/281-bounded-confirmation/plan.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/281-bounded-confirmation/plan.speech.json` | 1 | Redo with any changed companion page; history stays versioned |
| `specs/281-bounded-confirmation/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/281-bounded-confirmation/spec.speech.json` | 1 | Redo with any changed companion page; history stays versioned |
| `specs/29-docs-links-recut/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/299-singular-cli/spec.md` | 2 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/299-singular-cli/spec.speech.json` | 1 | Redo with any changed companion page; history stays versioned |
| `specs/300-preprod-delivery/evidence-mapping.md` | 2 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/300-preprod-delivery/plan.md` | 4 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/300-preprod-delivery/plan.speech.json` | 3 | Redo with any changed companion page; history stays versioned |
| `specs/310-open-datum-application/plan.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/310-open-datum-application/ruling-token-data-findability.md` | 4 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/310-open-datum-application/ruling-token-data-findability.speech.json` | 2 | Redo with any changed companion page; history stays versioned |
| `specs/323-acquired-node-interface/plan.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/323-acquired-node-interface/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/324-indexer-view/data-model.md` | 3 | Historical record; keep clearly superseded, subject to docs checks |
| `specs/324-indexer-view/functions-model.md` | 2 | Historical record; keep clearly superseded, subject to docs checks |
| `specs/324-indexer-view/modules-model.md` | 5 | Historical record; keep clearly superseded, subject to docs checks |
| `specs/324-indexer-view/plan.md` | 9 | Historical record; keep clearly superseded, subject to docs checks |
| `specs/324-indexer-view/spec.md` | 9 | Historical record; keep clearly superseded, subject to docs checks |
| `specs/324-indexer-view/tasks.md` | 3 | Historical record; keep clearly superseded, subject to docs checks |
| `specs/325-cli-recovery/plan.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/325-cli-recovery/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/326-artifact-contract-evidence/plan.md` | 2 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/326-artifact-contract-evidence/spec.md` | 4 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/326-artifact-contract-evidence/tasks.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `specs/protocol/spec.md` | 1 | Inspect dependency or unrelated index use; no blanket deletion |
| `tools/api_reference.py` | 3 | Update active claims and removed-module references |
| `tools/assemble_onchain_release.py` | 1 | Inspect CI, archive or harness carrier; replace only legacy backend references |
| `tools/check_release.py` | 2 | Inspect CI, archive or harness carrier; replace only legacy backend references |
| `tools/demo1_cli_attach.sh` | 54 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `tools/demo1_cli_attach_check.sh` | 1 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `tools/demo1_cli_journey.sh` | 26 | Inspect CI, archive or harness carrier; replace only legacy backend references |
| `tools/demo1_mock_indexer.py` | 6 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `tools/demo1_readback.sh` | 18 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `tools/demo1_readback_check.sh` | 14 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `tools/demo1_readback_tamper.sh` | 4 | Separate HTTP readback / demo consumer; preserve and check packaging |
| `tools/node-confinement.allow` | 1 | Inspect CI, archive or harness carrier; replace only legacy backend references |
| `tools/node_confinement_check.sh` | 2 | Inspect CI, archive or harness carrier; replace only legacy backend references |

The broad search deliberately includes unrelated indexing. The disposition is
a source classification to verify, not authority to delete every match. After
implementation, rediscover the full extent and classify every survivor.

## Deletion and migration responsibilities

Delete the old address adapter, its index gate and its old view/rig tests.
The current follower module also owns confirmation and devnet adaptation;
move or replace those surviving duties before deleting it. Its current
`Following` includes the old gate, and `Node.Confirmation` calls
`awaitTxIn` using that follower. Removing it blindly breaks confirmations.
`StubFollowing`, `ContractMemory`, `ContractNode`, `ContractSuite`,
`PhaseLogSpec` and `NodeCleanupSpec` retain real obligations even when their
legacy adapter setup is removed. Cabal declarations and node-confinement
allowlist entries must match the surviving module extent.

Active docs and their speech, CLI parser/help, node options/session composition,
API ownership links and the journey's old second pass need migration together.
The dependency pin in `offchain/cabal.project` is
`0e73121dc1df516b69d69bdd554b12bebd28d072`; upstream changes to follower internals
make an isolated bump unsafe for the current wrapper. Historical changelog and
`specs/324-indexer-view/` describe an earlier decision; retain them as
superseded history if documentation checks allow, rather than imply the old
backend remains selectable.

## Why the HTTP mock survives

`tools/demo1_mock_indexer.py` serves Koios and Blockfrost HTTP shapes from
inspect receipts. `tools/demo1_cli_attach.sh` starts it for readback controls;
`tools/demo1_cli_attach_check.sh` and `tools/check_release.py` require it in
the archive. It neither implements the in-process follower nor the new socket
protocol. Preserve it and its controls. A mock agreeing with its consumer is
not evidence that the real socket protocol works.

## Why genesis needs a separate read

`offchain/devnet/Main.hs:fund` reads the genesis wallet through
`withExternalCapabilities`, builds and submits real funding transactions,
then confirms them before `spawn` prints the socket. The ordinary journey
passes `--fund-skey` for Alice and Bob with four outputs each; their usable
funding is therefore transaction-created, not merely assigned in genesis.
The bare-node control in `tools/demo1_cli_journey.sh` separately reads the
one-output genesis wallet through a node create preview and expects the old
indexer to refuse it as coverage-incomplete. These are source facts; no new
chain run is claimed.

A block index cannot reconstruct an output carried by no block. Preserving
node bootstrap reads and an explicit genesis preview is the proposed bounded
exception. Origin/all-address provenance alone must not silently make an
unobserved genesis output an authoritative empty answer. The epic owner accepted the named node-only genesis direction for intake on
2026-10-02 and will check its justification at intake acceptance. No upstream
genesis mechanism is requested.

## Published upstream boundary

The inspected immutable upstream revision is
`1b3bf8b03d44de7db073b766c4a18b1065febfcf`. Its usage page describes library
`IndexerHandle.readView`, taking a nonempty list of address and asset queries
and materializing all results and `ivPoint` from one storage transaction.
Results preserve query order and duplicates. Address-only composed views also
refuse when the asset index is unavailable. The operator's atomic-composition
note fixes this mechanism for the socket consumer: one composed request per
view.

The documented socket still answers one request per connection;
`utxos_at` returns outputs without an indexed point. `utxos_with_asset`
reports point, network, coverage, freshness and limits, but its independent
call does not join an address call into the same snapshot. Wait for the epic
owner's socket release, including published provenance and failure meanings.
This intake performs one immutable documentation read and does not poll
upstream or infer the unreleased wire.
