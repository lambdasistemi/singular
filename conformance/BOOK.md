# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `12249eac2e90ab79e7991223d1a3cc7546896d22` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:96328bafe9202b20978e19852d7e919d3d68abad34c84be7a414eb96`.

Rejection and retraction compared 8 requests: 2 accepted and 6 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `9b586cde971f2eb3a9f109bb229ccec16a2e97ad2e45af17cfef6a168c7e3022`); the model refused it for `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `003568771f5a8d701f42d14008ee9396127b8373eab0c07e6616ca7ff1791114`); the model refused it for `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `03afa97ffdfdcb8fde3b329072c7b6c76a8570c65c294cb97649ff52d35b5d86`); the model refused it for `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `ef01d49596aa4e9c2b758576729c9a6c76ff094679e7433a17c1c1028eb59c31`); the model refused it for `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `9e888a51e24fc49d641f4662902c23903017e534df65b2527cf69ab0cbdc3b86`); the model refused it for `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `dcb61350b1c7a1e4e13d2bf0395fae4e1f301d5788fc8ceb56a2c540f76b35ce`); the model refused it for `retract-state-spent`.

Code revision: `12249eac2e90ab79e7991223d1a3cc7546896d22` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:96328bafe9202b20978e19852d7e919d3d68abad34c84be7a414eb96`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

The extra-signer registration was accepted on chain (transaction `c62392f1b49b57306e6d9bfd6ca7d414ae74e8a59c8787247d9e6780373b4592`); the comparison detected the difference at `tx.signers`.

The other-address insertActive was refused on chain (transaction `842702aedfdd1d51acebc2bb96b47db9cdb7b472a7c09895c88b26a7ed1b491d`); the model refused it for `destination`.

The short-by-one insertActive was refused on chain (transaction `d98a76616c4382ef6a6cbadae45e78396d7e34b59cdad2e413e7d35b198e4868`); the model refused it for `deposit-returned`.

Code revision: `12249eac2e90ab79e7991223d1a3cc7546896d22` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:96328bafe9202b20978e19852d7e919d3d68abad34c84be7a414eb96`.

Unnamed sequence compared 8 requests: 8 accepted and 0 refused on chain.

Unsupported chain folds: 0.

Code revision: `12249eac2e90ab79e7991223d1a3cc7546896d22` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:96328bafe9202b20978e19852d7e919d3d68abad34c84be7a414eb96`.

Retirement compared 11 requests: 7 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The short-by-one deleteActive was refused on chain (transaction `0673426dd843e58e7b0ae2760b7eb3651e0683e1a5a380b76d321b6365d61ac9`); the model refused it for `deposit-returned`.

The other-address deleteActive was refused on chain (transaction `094f982870f76882e89844d1e096464ed1548d5f1d15992e983a8696155f59fe`); the model refused it for `deposit-returned`.

## Register a key and receive its active token

A requester submits two distinct active registrations and then repeats one key. The delivery is then sent to another address, and paid one lovelace short, beside the same untampered request. Every step is compared with the executable registry model.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `f1f50ac910b0ff0f5abb8d371bd82ce5007e8bfe861939c5972d62e8c85e8508`.

### Registration delivers one active token to the requested recipient

- Submit **insertActive** for **alice** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

- Submit **insertActive** for **bob** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **bob**.

- Compare **bob** and its observation with the executable registry model.

- Submit **insertActive** for **alice** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration** with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration** with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **cosigned** in **registration** with one required signer the model does not require. The ledger accepts it; the comparison must report the difference in the transaction's signers.

- Observe the complete registry, token, leaf and transaction boundary after **cosigned**.

- Compare **cosigned** and its observation with the executable registry model.

## Retire a registration and burn its active token

The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry. A deletion then owes its owner the deposit back: paid one lovelace short, and paid to another address, it must be refused beside the untampered deletion.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `f1f50ac910b0ff0f5abb8d371bd82ce5007e8bfe861939c5972d62e8c85e8508`.

### The holder receives the token that will be retired

- Submit **insertActive** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `88957e41876911a993c5d9a338f8ab006c9f6843`. Statement digest: `6792444e9887f9e579975eae2cca2be00048db6d5a7a8c147b72fe6462eb3068`.

### Retirement burns the holder's token and leaves the key Terminal

- Submit **updateTerminal** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

- Submit **insertAbsent** for **never-active** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **never-active**.

- Compare **never-active** and its observation with the executable registry model.

- Submit **updateTerminal** for **never-active** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **never-active**.

- Compare **never-active** and its observation with the executable registry model.

- Submit **insertActive** for **control** in **comparison**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **control**.

- Compare **control** and its observation with the executable registry model.

- Submit **updateTerminal** for **control** in **comparison**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **control**.

- Compare **control** and its observation with the executable registry model.

- Submit **updateTerminal** for **never-registered** in **comparison**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **never-registered**.

- Compare **never-registered** and its observation with the executable registry model.

- Submit **insertActive** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **deleteActive** for **deleted** in **retirement** with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **deleteActive** for **deleted** in **retirement** with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **deleteActive** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

## A request that is never folded

A request can leave the queue without a fold. Once it may no longer be folded, a folder rejects it and must refund its owner the deposit, keeping the tip; while it is still retractable, its owner retracts it and must get back everything it held, deposit and tip, through an output whose inline datum is the retracted request's own output reference. Each refund paid one lovelace short or to another address, a return bound to another request, and a retraction spending the registry's state beside it must be refused, each beside the untampered exit of the same request.

- Reject the **insertActive** for **rejected** in **rejection** once it may no longer be folded with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Reject the **insertActive** for **rejected** in **rejection** once it may no longer be folded with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Reject the **insertActive** for **rejected** in **rejection** once it may no longer be folded, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner with its return bound to another request's output reference. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner spending the registry's state beside it. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

## A sequence no chapter names

This program uses the same live interpreter for each listed request. Each step records its own model and chain outcome; any unsupported result carries the reason observed at the booking or fold boundary.

- Submit **insertAbsent** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **updateActive** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **updateTerminal** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **insertActive** for **sequence-direct** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-direct**.

- Compare **sequence-direct** and its observation with the executable registry model.

- Submit **insertAbsent** for **sequence-absent** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-absent**.

- Compare **sequence-absent** and its observation with the executable registry model.

- Submit **deleteAbsent** for **sequence-absent** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-absent**.

- Compare **sequence-absent** and its observation with the executable registry model.

- Submit **witnessTerminal** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **deleteActive** for **sequence-direct** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-direct**.

- Compare **sequence-direct** and its observation with the executable registry model.

## What these runs do not establish

Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none, and the comparison reads them from the submitted transaction. The two-request batch allocation has no driver comparison: the driver evaluates one request per transaction, leaving Singular.Statements.fold_batch_claimed_mint_by_kind_key without this executable consumer. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. Retraction admission is not modelled until #239: the model admits the retraction of any request, while the chain refuses one of an update or a deletion with `withdraw-insert-only`, and one its owner did not sign with `retract-owner`; the live retractions above are therefore of insertions only, signed by their owner, and no run establishes those two refusals against the model. Live refusal reason not observed: the deployed validators are compiled without traces; the same-reason claim is checked against the compiled Aiken suite. Tracked by #287. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.

## Requirements inventory

The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.

### The canonical registry token name is SHA-256 of the canonical seed's outRef; a consumer recomputes it from the published seed and matches the on-chain state UTxO.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri: canonical seed-derived registry identity.

### A rival registry initialized from a second seed exists and is accepted by the ledger; canonical authentication rejects it on name.

Expected: rival accepted on chain; authentication rejects. Planned evidence status: uncovered.

Source: cardano-keri: canonical registry authentication distinguishes a rival seeded registry; issue #16.

### Negative control: an authenticator that checks only policy+address, not the derived name, accepts the rival.

Expected: control must fail. Planned evidence status: uncovered.

Source: Rival-registry authentication discrimination control (CA02).

### Applied and unapplied validator identity layers stay distinct and derived: applied address = apply(pinned unapplied hash, declared parameters); parameter count published.

Expected: accept. Planned evidence status: uncovered.

Source: blueprint identity discipline (onchain #34 pattern).

### A forged output at the canonical address carrying no registry token is not a registry: creating an output does not execute the receiving script.

Expected: authentication rejects; no script ran. Planned evidence status: uncovered.

Source: ledger output semantics.

### Generic Insert: request, fold, leaf present, root advances, read back from chain.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri: registered-key consistency and registry leaves changing only through a fold.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: boots state and applies a request update

### Generic Update (OpUpdate old new) on an existing key folds; the root advances and the new value reads back from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec registry transitions.

### Generic Delete (OpDelete old) on an existing key folds; the key returns to absence, proved by a read from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec; issue #18 Delete preservation.

### After deleting a key, re-Insert the same key (reincarnation).

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec: Delete MUST permit a later Insert.

### Insert on a key that is already present.

Expected: refuse, attributed to the script that refused. Planned evidence status: uncovered.

Source: protocol spec: the fold MUST NOT accept Insert for an occupied key.

### Retract in phase 2 returns bond+tip, registry untouched.

Expected: accept; root unchanged. Planned evidence status: bound elsewhere.

Source: cardano-keri: retraction timing, unchanged registry state and the returned request value.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: retracts a phase-2 request

### Retract outside phase 2.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R9_retract_needs_phase2.

### Rejected when rejectable.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri R9_reject_enabled.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: rejects a phase-3 request

### Rejected when not rejectable.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R9_reject_needs_rejectable.

### Stale fold against a superseded root.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R7_stale_fold_refused.

### Empty fold (Modify []).

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri R8_empty_fold_refused.

### Surplus actions beyond the matched request inputs.

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri audit 2026-09-03.

### Owner/hook pinning: a Modify that changes the state owner.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-pin transfer asserted authority that does not exist). Planned evidence status: bound elsewhere.

Source: cardano-keri R5_plugin_pinned.

### stake_script hook set: a fold carrying the matching withdrawal.

Expected: could-not-execute — superseded imported-partition material. Planned evidence status: uncovered.

Source: imported partition shared.ak, types.ak.

### stake_script hook set, withdrawal absent.

Expected: could-not-execute — superseded imported-partition material. Planned evidence status: uncovered.

Source: imported partition shared.ak, types.ak.

### Sweep of a non-legitimate UTxO, owner-signed.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-signed sweep asserted authority that does not exist). Planned evidence status: bound elsewhere.

Source: cage custody.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: sweeps malformed request-address UTxOs

### Sweep by a non-owner.

Expected: SUPERSEDED by operator ruling (registry has no owner role): observation preserved, claim withdrawn. Planned evidence status: uncovered.

Source: cage custody.

### End burns the state token and closes the cage.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cage custody.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: ends a cage by burning the state token

### Refund routing follows the request: processed value routes to the request's destination minus the folder's tip; refunds go to the refund address recorded in custody; a crossed allocation is refused by the state script (interface, registry mode: no hook). Rejected produces refund owners at the recorded floor.

Expected: observe and report — refused, with the consumer-model conflict unresolved (crossed allocation enforced by the state script); rejected-action refund-floor control separate. Planned evidence status: uncovered.

Source: cardano-keri R11_contribute_value, R11_retract_value; interface gist 2fb03c2e (registry mode).

### Every ToData/FromData instance in Singular.Registry.Types round-trips, and its constructor index and field order match the compiled blueprint's declared schema, not merely itself.

Expected: accept, byte-exact against the blueprint. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

### Datum bytes constructed in Haskell and submitted are read back from the chain identical.

Expected: accept, byte-compare submitted vs chain-observed. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

### Each UpdateRedeemer constructor (End 0, Contribute 1, Modify 2, Retract 3, Sweep 4) is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator.

Expected: partial: accept (Contribute 1, Modify 2, Retract 3 with executing witnesses); End 0 and Sweep 4 unexercised named residuals (no accepting path yet, issue #18 tracks completion). Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

### A redeemer at a wrong constructor index is refused by the compiled validator.

Expected: refuse, attributed to the script. Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

### Each RequestAction (Update 0, Rejected 1) and MintRedeemer (Minting 0, Burning 2) constructor is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator; Migrating 1 unconditional refusal recorded with wire constructor retained.

Expected: partial: accept (Update 0, Rejected 1, Minting 0 with executing witnesses); Burning 2 unexercised named residual; Migrating 1 explicit gap. Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

### Script parameter application: parameter count and encoding published, applied hash derived in Haskell equals the on-chain address for every parameterized script.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 parameter binding.

### Each ProofStep variant (Branch 0, Fork 1, Leaf 2) and Neighbor exercised by a fold the validator accepted.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 proof coverage.

### OnChainTokenState's six fields (root, maxFee, processTime, retractTime, repPolicy, consumerPin) survive a chain round trip with the representative policy varied Base versus AltRepPolicy.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 state round trip.

### Present: resolve the active registration's application UTxO from the authenticated canonical registry.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 1 (Singular side).

### The token: exact policy, quantity one, derived asset name.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 2 (Singular side).

### Zero candidates resolves to reject.

Expected: reject, fail closed. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 3 (Singular side).

### Several candidates impossible: a second live representative for one registered key cannot be created.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 4 (Singular side).

### Resolve while the representative sits in a pending terminal request: report pending, not a usable output.

Expected: pending. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 5 (Singular side).

### Bonds, poison, the juvenility window W and the signature threshold: the checkpoint machine's and the treasury's policy, not Singular's.

Expected: out of scope — recorded, never claimed. Planned evidence status: outside the registry's scope.

Source: cardano-keri consumer-checklist points 3-6 (cardano-keri side).

### Execution units (mem, cpu) and transaction size measured for every accepting row, against the devnet's Conway protocol maxima, with headroom stated.

Expected: recorded. Planned evidence status: uncovered.

Source: issue #18 acceptance: limits measured.

### The fold batch-size boundary: the largest Modify batch that succeeds and the smallest that fails, with the failure reason.

Expected: an actual observed boundary, N accepted and N+1 refused. Planned evidence status: uncovered.

Source: issue #18 acceptance: limits measured.

### Exact environment: cardano-node version, GHC, Aiken toolchain, blueprint hashes, and the environments explicitly not supported.

Expected: recorded from the running node and the pinned flakes. Planned evidence status: uncovered.

Source: issue #18 acceptance: limits measured.

### Hold a valid fold constant and remove only the state-owner required signer; the observation (accept or refuse) is recorded with its transaction — the regression property the independent verification specified.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; the no-owner-signer property is recorded history, not a live gate). Planned evidence status: bound elsewhere.

Source: Singular.Statements.fold_iff sufficiency direction (Lean); observation history: FAILED against the pre-#79 candidate (owner gate), ACCEPTED against the repaired candidate by execution.

### One `insertActive` request folds on the open registry and places exactly one `(activePolicy, key)` token in the output at the address and inline datum the request named. A second `insertActive` at the same known key is refused `key-exists`. A two-request batch at two DISTINCT keys whose claimed mint agrees per kind but disagrees per `(kind, key)` is refused `net-mint-mismatch`.

Expected: accept the fold; refuse the same-key duplicate `key-exists`; refuse the two-key wrong-distribution batch `net-mint-mismatch`; both refusals carry an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.insert_active_transaction_row and Singular.Statements.fold_batch_claimed_mint_by_kind_key (Lean 854f56f); issue #173; open application, distinct refusal fixtures and the published trace limit.

### On a real devnet, `insertActive` then `updateTerminal` at one key: the active witness the insert delivered is the exact input the retirement burns, exactly one `(activePolicy, key)` is destroyed, no output carries it afterwards, and the committed trie leaf becomes Terminal. `updateTerminal` on an Unknown key and on an Absent key are refused with their own named reasons, each against an accepting control.

Expected: accept the insert and the retirement; the active quantity goes 1 -> 0 with the exact keyed `-1` mint burned from its token-bearing source input and the committed leaf reading `Terminal`; refuse `updateTerminal` on an Unknown key `key-unknown` and on an Absent key `not-booked`, each with an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.update_terminal_transaction_row and Singular.Statements.update_terminal_inversion (Lean 871c5df); issue #177; connected retirement and distinct refusal controls.

### On a real devnet, a request that is never folded leaves the queue by a reject or a retract. A reject once the request may no longer be folded must refund its owner the deposit; a retract by its owner must return everything the request held, through an output whose inline datum is the retracted request's own output reference. Each refund or return one lovelace short or to another key, a return bound to another request, and a retract spending the registry state beside it are refused by the chain and by the model, each beside the untampered exit of the same request, which both accept. The live consumer for the rule that only a retract returns the tip is the reject that keeps the tip beside the retract that returns it; fold consumers are in the fold rows. The guarantee that retract obligations depend only on the request remains a named gap: Lean proves this for every request and registry state, while this live run covers one registry state and no executable consumer varies it.

Expected: refuse a reject refunding the owner one lovelace short and to another key, `deposit-returned`, beside the accepted untampered reject; refuse a retraction returning one lovelace short, to another key and bound to another output reference, `deposit-returned`, and one spending the registry state beside it, `retract-state-spent`, beside the accepted untampered retraction. Planned evidence status: uncovered.

Source: Singular.Statements.exit_settles_on_lovelace_received and Singular.Statements.no_exit_strands_the_deposit; issue #258; Singular.Statements.only_retract_owes_the_tip: consumed by the live reject that keeps the tip and retract that returns it; fold consumers are in the registration (CG21) and retirement (CG22) rows. Singular.Statements.obligations_read_only_the_request: named gap, proved in Lean for every request and registry state, but the live run covers one registry state and no executable consumer varies it.

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.
