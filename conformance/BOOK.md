# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `300c58bdb36cdb72f2fdc4575a1bb720b7232181` (working tree had changes).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:67ef82d1e5f6a4c3fcf95ac3dcd4aeccbdb6f0e9849cc63b0286ab20 request:c404e3bf529fa8a92c9bd32ceceaa58fc48e7274d274a68ea3bfb4aa`.

Registration passed: exactly one active token reached the requested recipient.

Transaction: `07687c56c71be5caecd74317f5c7c5c0416e4074a75812a0847c270df9fe93ca`.

Code revision: `300c58bdb36cdb72f2fdc4575a1bb720b7232181` (working tree had changes).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:67ef82d1e5f6a4c3fcf95ac3dcd4aeccbdb6f0e9849cc63b0286ab20 request:c404e3bf529fa8a92c9bd32ceceaa58fc48e7274d274a68ea3bfb4aa`.

Retirement passed: the holder's active-token quantity changed from **1** to **0**, the token was burned, and the key became Terminal.

Registration transaction: `aeeec1f981851c97d07995a38e4d03a4ad99c34d6c409f3e02f47cf846799bbc`. Retirement transaction: `13d47ac87a051c43ff3d006ed16600362a1b47853b4a65c5906e2003ca31fd40`.

## Register a key and receive its active token

A requester registers a new key for a recipient. The recipient must receive exactly one active token for that key. A fresh key must work; registering the same key again must fail. The batch example checks that a correct token total cannot hide a wrong allocation between keys.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`.

### Registration delivers one active token to the requested recipient

- Request registration of **alice** in **registration**, deliver to the recipient wallet, and apply the request on chain.

- Compare the observed delivery and queried holdings with the Lean executable's result.

- Check on chain that the recipient wallet holds exactly **1 active token(s)** for **alice**; check its policy, destination, mint and resulting registry state.

- Successfully register the fresh key **bob** in **registration** for the recipient wallet, through the transaction builder used by the duplicate attempt.

- Check on chain that the recipient wallet holds exactly **1 active token(s)** for **bob**; check its policy, destination, mint and resulting registry state.

Formal specification: `Singular.Statements.fold_batch_claimed_mint_by_kind_key` @ `265c595`. Statement digest: `9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988`.

```text
assetKindTotal (claimedMint [b₁, b₂]) k
assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false
foldBatch s [b₁, b₂] = .error "net-mint-mismatch"
```

- Request **carol** and **david** in **registration** for the recipient wallet. Submit a balanced transaction putting both tokens at the first key: require a state-script rejection. Apply the same requests with one token per key: require success and read back the allocation.

- Try to register **alice** again in **registration**. Require the state script to reject it; **bob** is the successful comparison.

## Retire a registration and burn its active token

The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`.

### The holder receives the token that will be retired

- Request registration of **alice** in **retirement**, deliver to the holder wallet, and apply the request on chain.

- Compare the observed delivery and queried holdings with the Lean executable's result.

- Check on chain that the holder wallet holds exactly **1 active token(s)** for **alice**; check its policy, destination, mint and resulting registry state.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `871c5df529d30357e4da7f6f9f141dc02c103bf6`. Statement digest: `3448ca20f33bba9c3b5092136124f4cb0bf196132f485cae8b1a44343523963b`.

### Retirement spends and burns that token and leaves the key Terminal

- Request retirement of the **alice** registration just created in **retirement**. Apply it using the active token held by its recipient.

- Compare the burn, spent witness, remaining holdings and committed leaf with the Lean retirement result.

- Check that **alice** now has a Terminal leaf, the holder has **0 active token(s)** remaining, and exactly its original token was consumed and burned.

- In **retirement**, establish **never-active** as Absent for the holder wallet through a real transaction, then try to retire it. Require a script rejection, compared with the successful retirement of **alice**.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`.

### The comparison holder receives a token in the fresh registry

- Request registration of **control** in **comparison**, deliver to the holder wallet, and apply the request on chain.

- Compare the observed delivery and queried holdings with the Lean executable's result.

- Check on chain that the holder wallet holds exactly **1 active token(s)** for **control**; check its policy, destination, mint and resulting registry state.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `871c5df529d30357e4da7f6f9f141dc02c103bf6`. Statement digest: `3448ca20f33bba9c3b5092136124f4cb0bf196132f485cae8b1a44343523963b`.

### The comparison retirement burns its own registration token

- Request retirement of the **control** registration just created in **comparison**. Apply it using the active token held by its recipient.

- Compare the burn, spent witness, remaining holdings and committed leaf with the Lean retirement result.

- Check that **control** now has a Terminal leaf, the holder has **0 active token(s)** remaining, and exactly its original token was consumed and burned.

- Try to retire **never-registered**, which was never registered in **comparison**. Require a script rejection, compared with the successful retirement of **control** in this same registry.

## What these runs do not establish

Every declared observation of a registration is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction, including the transaction's signers value, which a check changes to prove the difference is reported. Two things are named rather than compared: a ledger makes every output carry a minimum ada and the model says nothing about it, so outputMinimumAda is removed from both sides and earns no pass; and the model states no obligation about who must sign, so requiredSigners stays a named unobservable until the signer rules are stated and proved. Retirement effects still come from the oracle replay, which starts each example in an empty registry. Batch allocation and refusal checks still use Haskell predicates. The requirement that every Lean theorem has an executable consumer remains unmet. These examples exercise the open registry on one local devnet and one protocol-parameter set. They do not establish every case in the formal model. Signature-set invariance is not observed. Retirement of an already Terminal key and retirement without the token remain compiled-script controls rather than live examples here. The naming application's additional approval behavior is outside these stories.

## Requirements inventory

The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.

### The canonical registry token name is SHA-256 of the canonical seed's outRef; a consumer recomputes it from the published seed and matches the on-chain state UTxO.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri ruling 3 (aid utxo uniqueness).

### A rival registry initialized from a second seed exists and is accepted by the ledger; canonical authentication rejects it on name.

Expected: rival accepted on chain; authentication rejects. Planned evidence status: uncovered.

Source: cardano-keri ruling 3; epic-16 finding LI03.

### Negative control: an authenticator that checks only policy+address, not the derived name, accepts the rival.

Expected: control must fail. Planned evidence status: uncovered.

Source: CA02 discrimination control.

### Applied and unapplied validator identity layers stay distinct and derived: applied address = apply(pinned unapplied hash, declared parameters); parameter count published.

Expected: accept. Planned evidence status: uncovered.

Source: blueprint identity discipline (onchain #34 pattern).

### A forged output at the canonical address carrying no registry token is not a registry: creating an output does not execute the receiving script.

Expected: authentication rejects; no script ran. Planned evidence status: uncovered.

Source: ledger output semantics.

### Generic Insert: request, fold, leaf present, root advances, read back from chain.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri R1, R12.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: boots state and applies a request update

### Generic Update (OpUpdate old new) on an existing key folds; the root advances and the new value reads back from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec registry transitions.

### Generic Delete (OpDelete old) on an existing key folds; the key returns to absence, proved by a read from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec; issue #18 Delete preservation.

### After CG03, re-Insert the same key (reincarnation).

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec: Delete MUST permit a later Insert.

### Insert on a key that is already present.

Expected: refuse, attributed to the script that refused. Planned evidence status: uncovered.

Source: protocol spec: the fold MUST NOT accept Insert for an occupied key.

### Retract in phase 2 returns bond+tip, registry untouched.

Expected: accept; root unchanged. Planned evidence status: bound elsewhere.

Source: cardano-keri R9, R6, R11.

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

Expected: observe and report — refused+HeldQ002 (crossed allocation enforced by the state script); rejected-action refund-floor control separate. Planned evidence status: uncovered.

Source: cardano-keri R11_contribute_value, R11_retract_value; interface gist 2fb03c2e (registry mode).

### Every ToData/FromData instance in Singular.Registry.Types round-trips, and its constructor index and field order match the compiled blueprint's declared schema, not merely itself.

Expected: accept, byte-exact against the blueprint. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

### Datum bytes constructed in Haskell and submitted are read back from the chain identical.

Expected: accept, byte-compare submitted vs chain-observed. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

### Each UpdateRedeemer constructor (End 0, Contribute 1, Modify 2, Retract 3, Sweep 4) is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator.

Expected: partial: accept (Contribute 1, Modify 2, Retract 3 with executing witnesses); End 0 and Sweep 4 unexercised named residuals (no accepting path yet, E18 completes). Planned evidence status: uncovered.

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

### Hold a valid fold constant and remove only the state-owner required signer; the observation (accept or refuse) is recorded with its transaction — the regression property the independent verification (F-002) specified.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; the no-owner-signer property is recorded history, not a live gate). Planned evidence status: bound elsewhere.

Source: Singular.Statements.fold_iff sufficiency direction (Lean); observation history: FAILED against the pre-#79 candidate (owner gate), ACCEPTED against the repaired candidate by execution.

### One `insertActive` request folds on the open registry and places exactly one `(activePolicy, key)` token in the output at the address and inline datum the request named. A second `insertActive` at the same known key is refused `key-exists`. A two-request batch at two DISTINCT keys whose claimed mint agrees per kind but disagrees per `(kind, key)` is refused `net-mint-mismatch`.

Expected: accept the fold; refuse the same-key duplicate `key-exists`; refuse the two-key wrong-distribution batch `net-mint-mismatch`; both refusals carry an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.insert_active_transaction_row and Singular.Statements.fold_batch_claimed_mint_by_kind_key (Lean 854f56f); issue #173; A-001, A-006, NOTE-014.

### On a real devnet, `insertActive` then `updateTerminal` at one key: the active witness the insert delivered is the exact input the retirement burns, exactly one `(activePolicy, key)` is destroyed, no output carries it afterwards, and the committed trie leaf becomes Terminal. `updateTerminal` on an Unknown key and on an Absent key are refused with their own named reasons, each against an accepting control.

Expected: accept the insert and the retirement; the active quantity goes 1 -> 0 with the exact keyed `-1` mint burned from its token-bearing source input and the committed leaf reading `Terminal`; refuse `updateTerminal` on an Unknown key `key-unknown` and on an Absent key `not-booked`, each with an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.update_terminal_transaction_row and Singular.Statements.update_terminal_inversion (Lean 871c5df); issue #177; A-002.

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.
