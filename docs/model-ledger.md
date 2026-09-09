# Executable logical model ledger

As a model reviewer, use this register to locate the exact requirement or finite scenario behind a behavior you observe, and check its conditions and omissions. The lookup identifiers below preserve links to executable evidence; the [design stories](design.md) explain the same behavior as a journey.

This is a **CANDIDATE at MODEL + PROOFS stage**. The executable Lean machine is `Singular.step` in [the model source](../lean/Singular/Model.lean). Its finite corpus executes accepted and refused cases. Every theorem is PROVED from the standard axioms without changing its statement; there is no audit verdict or acceptance claim.

## Authority and domain

The current protocol specification is the behavioral baseline. Its direct application-issued Insert and Withdraw action assets supersede early separate-native-policy prose. The authoritative transition function handles staged request construction, application release and evolution, outsider output creation, withdrawal, atomic selected folds, existing action movement and custody escape refusal. `foldOne` implements the three registry operations; `foldItems` applies them sequentially.

`Reachable` starts at an empty registry under a supplied configuration and closes over successful `step` executions. Supply, terminality and custody preservation claims quantify that ledger domain. Raw states can also be supplied for malformed-input tests; they are not all reachable. In particular UTxO-id uniqueness in raw state is not assumed by the executable parser. Successful request creation permanently records ids in `used`, and consumption removes the corresponding output. The withdrawal supply theorem assumes Reachable to exclude malformed aliasing of request and application ids.

## Requirements and semantic atoms

| Requirement | Executable decision and effect | Status and limits |
| --- | --- | --- |
| R1 | `foldOne`: absent→Active/+1; Active→Over/−1; Active→absent/−1; payload-free `Value`; `supply` counts both custody forms | Modeled; conservation and terminality PROVED |
| R2 | `insertNative`, `releaseNative`, `approved`, `recognized`; creation differs from later consumption; outsider output retains unauthenticated origin | Modeled with authenticated logical provenance/configuration abstraction; no physical receiving-validator execution |
| R3 | `Commitment.insert Proposal`, configured policy, `Approval.accepted`, exact initial Output; no current absence check at creation | Conditional on supplied application contract evidence; conformance bit is diagnostic and never inferred from issuer recognition |
| R4 | pending Insert holds no representative; absence/output/scope checked at fold; separate Withdraw commitment binds exact id and Refund | Modeled under explicit logical refund parameters; economics/disposal abstract |
| R5 | release evidence binds source and entire selected request; application spending witness; source NFT moves into request | Conditional on supplied legal-release evidence; request creation reads config and application NFT, not mutable registry entries |
| R6 | release removes application UTxO; escape always refused; completion consumes request and burns coupled NFT | Modeled; supply and single-spend guarantees PROVED; whole-transition completion-only terminal-custody statement missing |
| R7 | sequential `foldItems`; actor identity absent from Action; explicit output fields | Modeled atomic selected-batch profile; no automatic skipping, arbitrary semantic callback, capacity or fairness claim |
| R8 | permanent used ids; exact request consumption; explicit list of allowed incarnations; configurable asset reuse | Modeled proposed scope profile, not selected certificate encoding/lifecycle |
| R9 | witness fields checked at mint/release/consume; per-asset net quantity equality and nonzero policy checks | Modeled logical witness assignment; concrete ledger script partition remains abstract |

Output requirements are concrete fields: representative identity, quantity one, destination, datum and value. They are not a universal transaction-predicate language. `authenticatedOrigin` and approval records are logical provenance supplied by the modeled creating transactions, not a spendable boolean asserted by an outsider.

## Proposed abstractions and omissions

| Decision | Proposed abstraction | Not modeled or established |
| --- | --- | --- |
| D1 | Authenticated Config and logical map entries; semantic policy roles may share Nat identifiers | Hash dependencies, physical MPF proofs, configuration authentication on Cardano |
| D2 | Collision-free tagged Commitment terms; persisted logical approval records; action movement is zero-net with unchanged authorization | Hash/serialization, token UTxO location/value conservation, disposal/reuse protocol, optional terminal-request token, application burn branch |
| D3 | Explicit Refund destination and value committed to exact Insert UTxO; supplied Withdraw approval | Deposits, refund economics, cancellation policy conditions or real outputs on ledger |
| D4 | Scope is an explicit finite list of allowed incarnation numbers; Delete increments incarnation; `reuseIdentity` selects reused or fresh representative naming | Concrete incarnation fence and deployed identity construction |
| D5 | Caller supplies a selected list; the modeled transaction accepts all sequential steps or refuses atomically | Batch builder, automatic omission/skipping, failure UI, limits, capacity |
| D6 | Logical executing witness flags; native spending required even when net representative mint is zero | Compiled scripts, real transaction contexts, bypass protection outside this closed action algebra, shared library APIs |
| D7 | Nat key/address datum, authenticated logical view, address/pending/absent/retired resolution | Normalization, signature/ownership policy, schema, indexer/ledger authentication implementation, deployment and economics |

A deliberately nonconforming configured application can approve a structurally recognized Insert in S18. That is an executed demonstration of the trust boundary, not a native rejection claim. The source `conforms` field records this diagnostic; no correctness theorem connects arbitrary application code to it. Applications needing fresh fold-time observations are outside demonstrated coverage.

With fresh representative identity (`reuseIdentity = false`), the certified initial output fixes one `assetScope`. A proposal therefore fits one incarnation even when its approval scope list contains several incarnations. Deliberately reusable approval across incarnations is represented by the reused-identity profile; fresh identity requires a newly certified output. D4 remains open: these executable profiles do not select a deployed identity or certificate lifecycle.

Completion-only terminal custody remains a statement-coverage gap across the whole transition function. The proved escape refusal and Reachable supply statements do not replace that general theorem. The corpus separately exercises terminal Withdraw refusal, with a recognized, exact-target Withdraw approval, while preserving all 41 declarations unchanged.

## Scenario inventory

The checked [corpus](../lean/corpus.json) carries the exact model, statements, corpus-source and theorem-manifest SHA-256 identities. Each transition row records input state, action, independently declared accepted/refused expectation, exact refusal reason where applicable, and Lean-computed result. Resolver rows record input state, authentication flag and expected result. `tools/check_model.py` verifies source identities and byte-for-byte regeneration; this is finite behavior evidence, not exhaustive verification.

| Corpus identity | Explicit status | Expected outcome |
| --- | --- | --- |
| S03b-configured-issuer-control | modeled | Accepted |
| S07c-second-pending-insert | modeled | Accepted |
| S07d-mint-second-withdraw | modeled | Accepted |
| S07e-valid-second-target | modeled | Accepted |
| S11b-mint-terminal-withdraw | modeled | Accepted |
| S11c-terminal-withdraw-refused | modeled | Refused: withdraw-insert-only |
| S17c-outsider-withdraw-refused | modeled | Refused: withdraw-insert-only |
| S13c-fresh-insert-created | proposed-fresh-identity-profile | Accepted |
| S13d-fresh-insert-folded | proposed-fresh-identity-profile | Accepted |
| S13e-fresh-delete-released | proposed-fresh-identity-profile | Accepted |
| S13f-fresh-delete-completed | proposed-fresh-identity-profile | Accepted |
| S13g-fresh-reinsert-created | proposed-fresh-identity-profile | Accepted |
| S13h-fresh-reinsert-folded | proposed-fresh-identity-profile | Accepted |
| S13i-stale-identity-created | proposed-fresh-identity-profile | Accepted |
| S13j-stale-identity-refused | proposed-fresh-identity-profile | Refused: representative-identity |
| S21c-fresh-batch-staged | proposed-fresh-identity-profile | Accepted |
| S21d-fresh-delete-insert | proposed-fresh-identity-profile | Accepted |
| S21e-fresh-wrong-zero-net | proposed-fresh-identity-profile | Refused: net-mint-mismatch |
| S19c-distinct-action-assets-do-not-net | abstract-disposal | Refused: application-mint-witness |
| S10b-release-varied-entry | modeled | Accepted |
| S10c-insert-varied-entry | modeled | Accepted |
| S01-approved-insert | modeled | Accepted |
| S02-no-approval | modeled | Refused: application-approval |
| S03-substitute-policy | modeled | Refused: insert-binding |
| S04-substituted-output | modeled | Refused: certified-output |
| S05-competing-inserts | modeled | Refused: occupied-key |
| S06-exact-withdraw | conditional-refund-profile | Accepted |
| S07-insert-cannot-withdraw | modeled | Refused: withdraw-binding |
| S07b-wrong-pending-withdraw | modeled | Refused: withdraw-binding |
| S08-local-evolution | conditional-application-contract | Accepted |
| S09-delete-substituted-update | modeled | Refused: exact-release-authorization |
| S10-release-without-registry-read | modeled | Accepted |
| S11-custody-escape | modeled | Refused: completion-only-custody |
| S12-update-completes | modeled | Accepted |
| S13-delete-completes | modeled | Accepted |
| S13b-reinsert | modeled | Accepted |
| S14-wrong-registry-nft | modeled | Refused: terminal-binding |
| S15-completed-replay | modeled | Refused: request-unavailable |
| S15b-incarnation-replay | modeled | Refused: approval-scope |
| S16-unrelated-folder | modeled | Accepted |
| S17-outsider-output-creation | modeled | Accepted |
| S17b-outsider-refused | modeled | Refused: unauthenticated-request |
| S18-issuer-not-semantics | conditional-application-contract-fails | Accepted |
| S19-action-burn-witness | abstract-disposal | Refused: application-mint-witness |
| S19b-action-burn-executes | abstract-disposal | Accepted |
| S20-existing-action-movement | abstract-token-location | Accepted |
| S21-zero-net-delete-insert | proposed-reused-identity-profile | Accepted |
| S21b-zero-net-no-spending-witness | modeled | Refused: native-witness |
| N01-register-address-A | proposed-naming-profile | Accepted |
| N02-occupied-name | modeled | Refused: occupied-key |
| N06-change-address-B | conditional-application-contract | Accepted |
| N07-unauthorized-change | modeled | Refused: application-evolution-authorization |
| N03-resolve-live | Proposed naming profile; authenticated logical view | `{"address": {"datum": 100}}` |
| N04-resolve-pending | Proposed naming profile; authenticated logical view | `"pending"` |
| N05-resolve-absent | Proposed naming profile; authenticated logical view | `"absent"` |
| N05b-resolve-over | Proposed naming profile; authenticated logical view | `"retired"` |
| N06b-resolve-new-address | Proposed naming profile; authenticated logical view | `{"address": {"datum": 200}}` |
| N07b-forged-view | Proposed naming profile; authenticated logical view | `"unauthenticated"` |

There are 58 finite rows: 52 transition cases and 6 resolver cases. S10 and S10b hold configuration/application custody fixed while varying mutable registry entries; S10c additionally demonstrates Insert staging under an occupied/retired raw registry view. These raw-state cases test independence, not reachability. Whole-step acceptance and exact refusal independence are separately PROVED. Per-action-asset quantities net only identical assets: S19c refuses opposite changes to distinct names without the application mint witness.

S03 binds proposal, token and approval consistently to substitute issuer99 while configuration remains issuer7; S03b accepts the configured issuer. S07c–S07e create a second pending Insert, mint its recognized Withdraw and accept the correct target, while S07b refuses that same approval against the first request. S17 places an outsider at the configured request address90 carrying an existing approved Insert-shaped token; its origin remains unauthenticated and both fold and withdrawal are refused.

S11b–S11c mint an exact-target terminal Withdraw approval and refuse its use against Delete custody. S13c–S13h execute fresh-identity Insert, release, Delete completion and reinsert with the new representative. S13i–S13j show that a multi-incarnation scope does not refresh the old certified identity. S21c–S21e stage fresh reinsert beside Delete, accept the distinct old burn and new mint, and refuse a claimed zero net. All earlier scenario identities remain present; these finite controls do not establish exhaustive coverage or an executed mutation campaign.
