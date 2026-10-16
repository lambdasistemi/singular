# Shared files and ownership

## Story

As the epic owner, I want to review the actual shared surfaces before coding starts, so that the first implementation child cannot silently take the state validator or a consumer's model from the next child.

This is the proposed touch list at `45cd8a754dbb695ae55e91b1cede942ff627d69f`. It is a fence for planning, not authorization to change every file beneath a directory. Before each slice, the writer's representation proposal supplies exact files and a repository-wide caller census; the ticket owner freezes that smaller list. A newly discovered caller outside it is a question.

| Surface | Proposed paths | Ownership and condition |
|---|---|---|
| Request types and booking policy | `onchain/lib/types.ak`, request-specific helpers under `onchain/lib/`, new trie-ready policy under `onchain/validators/`, `onchain/validators/request.ak`, request test modules | Owned by 529. New module names are fixed at the representation checkpoint. |
| Shared pins and state authentication | `onchain/lib/registry/genesis.ak`, `onchain/validators/shared.ak`, configuration portions of `onchain/lib/types.ak` | Pin representation, immutable binding and the shared reference-state authentication are assigned to 529 by the epic answer. |
| Fold and mismatch consumers | `onchain/lib/registry/fold.ak`, `modify.ak`, `admission.ak`, `settlement.ak`, `discharge.ak`, `onchain/validators/cage.ak`, naming validators | The epic assigned 529 the minimum fold/settlement changes needed for lawful booking and existing journeys. Exact burns, donation, carriers and only-folds-spend-state belong here. Mismatch proofs and residual state/batch admission stay with 495. |
| Wire and identities | `offchain/lib/Singular/Registry/Wire/{Request,State,Redeemer,Primitive}.hs`, `Blueprint/{Load,Params,Schema}.hs`, `Config.hs`, `Config/Application.hs`, `Types.hs` | 529 owns correspondence for its new wire and applied policies. Discover every constructor/caller before freezing. |
| Booking and exits | `offchain/lib/Singular/Registry/TxBuilder/{Edges,Request,Retract,Reject,Boot}.hs`, `TxBuilder/Update/{Context,Build,Duties}.hs`, `TxBuilder/Internal/{Identity,Lookup}.hs`, relevant public facades | 529 owns tag minting, economic fold construction needed by these paths, retraction and expiry construction. Mismatch evidence remains 496. |
| Discovery and command entry points | `offchain/local-services/Singular/Registry/SessionIO.hs`, provider query adapters, `offchain/cli/src/Singular/CLI/{Fold,Reject,Reclaim,Inspect,Registry,Entry}.hs` and discovered scan owners | 529 owns tag-indexed discovery, junk control and command paths. Provider capabilities stay explicit; no hidden fallback address scan. |
| Application boundary | `applications/open-datum/onchain/`, `applications/open-datum/offchain/`, corresponding keri-stub callers | A-005 assigns mechanical State fixtures and registration commitment plumbing to 529. Application name changes wait for the A-006 consumer-model amendment; termination custody stays held under Q-003. |
| Consumer-model amendment | `applications/open-datum/lean/` and generated consumer corpus/oracle outputs | A-006 authorizes nonce-bearing registration requests and application names, affected statements and regenerated corpus. Separate Astra high writer between Sonnet slices; same Sol auditor. Root Singular Lean stays frozen. |
| Tests and package wiring | Relevant `offchain/test/`, `offchain/e2e-test/`, `offchain/contract-test/`, `offchain/journey/`, cabal/flake declarations and `tools/` ownership inventory entries | Only checks and packaging for this ticket's changed paths. Product checks are hosted in the same diff; test-only controls excluded from ordinary release builds. |
| Public conformance | `conformance/{app,lib,test}/`, rows/book metadata and `conformance/coverage/` generated records | 529's product descriptions, real observations, receipt readers and compiled identity mappings. No hand-typed fulfilled state or silent removal of old unmet rows. |
| CI and docs | `.github/workflows/{registry,conformance,ci}.yml`, owning CI scripts, affected user/API pages and their generated speech/audio, `specs/529-request-tag/` | New obligations wired to hosted steps. No comment-posting step. Unchanged prose/receipts remain unchanged. |
| Generated identities | `onchain/script-identity.json`, `onchain/permanent-contract.json`, `naming-onchain/script-identity.json`, `offchain/cli/src/Singular/CLI/Permanent.hs`, compiled manifests and vectors | Tool regeneration only, with exact source/blueprint binding. A changed script identity is a behavior-version boundary. |

## Forbidden work

No root Singular Lean, root corpus oracle or simulator-law edits. Consumer-model edits are confined to A-006 above; no hand-edited expected corpus values. No main mutation, merge, release, other lane branch, old plan cherry-pick, issue-body rewrite or GitHub comment. No cleanup of another worker's changes. Unresolved model conflicts remain escalated.

## Consumers to verify before the first push

An on-chain change reaches the open-datum and keri-stub application scripts and their library/CLI builders, naming scripts, blueprint identities, generated wire vectors, conformance encoders and live rows, ordinary CLI journeys and release archives, generated API docs, speech and presentation checks. These are intake dependencies even when a narrow gate omits them. Their local and hosted evidence stays distinct. The next slice's exact changed-name search must account for every caller in these groups.
