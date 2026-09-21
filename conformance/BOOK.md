# The registry's promises

The registry records keys and processes requests to change them. Registering an active key gives the requested recipient a token identifying that key. Applying several requests together must still create the right token for each key.

Read the requirements first, then the registration and batch stories. Each case explains what evidence is accepted or rejected and why. The exact test inputs and formal specification are available in expandable details.

## What has been demonstrated

The stories below check whether reports from a registry run contain the required evidence. All of these checks passed on example reports. This does not establish that the transactions were run on a blockchain; this book includes no reports from a live run. Requirements without evidence remain unproven.

## Requirements and remaining evidence

The wording and evidence status below come directly from the requirements inventory. 'Uncovered' means the required evidence is missing. 'Bound elsewhere' points to evidence maintained elsewhere. 'Outside the registry's scope' identifies responsibilities that belong to another system. A requirement is marked as executed only when a matching run report establishes that.

### The canonical registry token name is SHA-256 of the canonical seed's outRef; a consumer recomputes it from the published seed and matches the on-chain state UTxO.

Expected: accept. Evidence: uncovered.

Source: cardano-keri ruling 3 (aid utxo uniqueness).

### A rival registry initialized from a second seed exists and is accepted by the ledger; canonical authentication rejects it on name.

Expected: rival accepted on chain; authentication rejects. Evidence: uncovered.

Source: cardano-keri ruling 3; epic-16 finding LI03.

### Negative control: an authenticator that checks only policy+address, not the derived name, accepts the rival.

Expected: control must fail. Evidence: uncovered.

Source: CA02 discrimination control.

### Applied and unapplied validator identity layers stay distinct and derived: applied address = apply(pinned unapplied hash, declared parameters); parameter count published.

Expected: accept. Evidence: uncovered.

Source: blueprint identity discipline (onchain #34 pattern).

### A forged output at the canonical address carrying no registry token is not a registry: creating an output does not execute the receiving script.

Expected: authentication rejects; no script ran. Evidence: uncovered.

Source: ledger output semantics.

### Generic Insert: request, fold, leaf present, root advances, read back from chain.

Expected: accept. Evidence: bound elsewhere.

Source: cardano-keri R1, R12.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: boots state and applies a request update

### Generic Update (OpUpdate old new) on an existing key folds; the root advances and the new value reads back from chain.

Expected: accept. Evidence: uncovered.

Source: protocol spec registry transitions.

### Generic Delete (OpDelete old) on an existing key folds; the key returns to absence, proved by a read from chain.

Expected: accept. Evidence: uncovered.

Source: protocol spec; issue #18 Delete preservation.

### After CG03, re-Insert the same key (reincarnation).

Expected: accept. Evidence: uncovered.

Source: protocol spec: Delete MUST permit a later Insert.

### Insert on a key that is already present.

Expected: refuse, attributed to the script that refused. Evidence: uncovered.

Source: protocol spec: the fold MUST NOT accept Insert for an occupied key.

### Retract in phase 2 returns bond+tip, registry untouched.

Expected: accept; root unchanged. Evidence: bound elsewhere.

Source: cardano-keri R9, R6, R11.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: retracts a phase-2 request

### Retract outside phase 2.

Expected: refuse. Evidence: uncovered.

Source: cardano-keri R9_retract_needs_phase2.

### Rejected when rejectable.

Expected: accept. Evidence: bound elsewhere.

Source: cardano-keri R9_reject_enabled.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: rejects a phase-3 request

### Rejected when not rejectable.

Expected: refuse. Evidence: uncovered.

Source: cardano-keri R9_reject_needs_rejectable.

### Stale fold against a superseded root.

Expected: refuse. Evidence: uncovered.

Source: cardano-keri R7_stale_fold_refused.

### Empty fold (Modify []).

Expected: observe and report. Evidence: uncovered.

Source: cardano-keri R8_empty_fold_refused.

### Surplus actions beyond the matched request inputs.

Expected: observe and report. Evidence: uncovered.

Source: cardano-keri audit 2026-09-03.

### Owner/hook pinning: a Modify that changes the state owner.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-pin transfer asserted authority that does not exist). Evidence: bound elsewhere.

Source: cardano-keri R5_plugin_pinned.

### stake_script hook set: a fold carrying the matching withdrawal.

Expected: could-not-execute — superseded imported-partition material. Evidence: uncovered.

Source: imported partition shared.ak, types.ak.

### stake_script hook set, withdrawal absent.

Expected: could-not-execute — superseded imported-partition material. Evidence: uncovered.

Source: imported partition shared.ak, types.ak.

### Sweep of a non-legitimate UTxO, owner-signed.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-signed sweep asserted authority that does not exist). Evidence: bound elsewhere.

Source: cage custody.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: sweeps malformed request-address UTxOs

### Sweep by a non-owner.

Expected: SUPERSEDED by operator ruling (registry has no owner role): observation preserved, claim withdrawn. Evidence: uncovered.

Source: cage custody.

### End burns the state token and closes the cage.

Expected: accept. Evidence: bound elsewhere.

Source: cage custody.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: ends a cage by burning the state token

### Refund routing follows the request: processed value routes to the request's destination minus the folder's tip; refunds go to the refund address recorded in custody; a crossed allocation is refused by the state script (interface, registry mode: no hook). Rejected produces refund owners at the recorded floor.

Expected: observe and report — refused+HeldQ002 (crossed allocation enforced by the state script); rejected-action refund-floor control separate. Evidence: uncovered.

Source: cardano-keri R11_contribute_value, R11_retract_value; interface gist 2fb03c2e (registry mode).

### Every ToData/FromData instance in Singular.Registry.Types round-trips, and its constructor index and field order match the compiled blueprint's declared schema, not merely itself.

Expected: accept, byte-exact against the blueprint. Evidence: uncovered.

Source: issue #18 serialization boundary.

### Datum bytes constructed in Haskell and submitted are read back from the chain identical.

Expected: accept, byte-compare submitted vs chain-observed. Evidence: uncovered.

Source: issue #18 serialization boundary.

### Each UpdateRedeemer constructor (End 0, Contribute 1, Modify 2, Retract 3, Sweep 4) is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator.

Expected: partial: accept (Contribute 1, Modify 2, Retract 3 with executing witnesses); End 0 and Sweep 4 unexercised named residuals (no accepting path yet, E18 completes). Evidence: uncovered.

Source: issue #18 constructor coverage.

### A redeemer at a wrong constructor index is refused by the compiled validator.

Expected: refuse, attributed to the script. Evidence: uncovered.

Source: issue #18 constructor coverage.

### Each RequestAction (Update 0, Rejected 1) and MintRedeemer (Minting 0, Burning 2) constructor is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator; Migrating 1 unconditional refusal recorded with wire constructor retained.

Expected: partial: accept (Update 0, Rejected 1, Minting 0 with executing witnesses); Burning 2 unexercised named residual; Migrating 1 explicit gap. Evidence: uncovered.

Source: issue #18 constructor coverage.

### Script parameter application: parameter count and encoding published, applied hash derived in Haskell equals the on-chain address for every parameterized script.

Expected: accept. Evidence: uncovered.

Source: issue #18 parameter binding.

### Each ProofStep variant (Branch 0, Fork 1, Leaf 2) and Neighbor exercised by a fold the validator accepted.

Expected: accept. Evidence: uncovered.

Source: issue #18 proof coverage.

### OnChainTokenState's six fields (root, maxFee, processTime, retractTime, repPolicy, consumerPin) survive a chain round trip with the representative policy varied Base versus AltRepPolicy.

Expected: accept. Evidence: uncovered.

Source: issue #18 state round trip.

### Present: resolve the active registration's application UTxO from the authenticated canonical registry.

Expected: accept. Evidence: uncovered.

Source: cardano-keri consumer-checklist point 1 (Singular side).

### The token: exact policy, quantity one, derived asset name.

Expected: accept. Evidence: uncovered.

Source: cardano-keri consumer-checklist point 2 (Singular side).

### Zero candidates resolves to reject.

Expected: reject, fail closed. Evidence: uncovered.

Source: cardano-keri consumer-checklist point 3 (Singular side).

### Several candidates impossible: a second live representative for one registered key cannot be created.

Expected: refuse. Evidence: uncovered.

Source: cardano-keri consumer-checklist point 4 (Singular side).

### Resolve while the representative sits in a pending terminal request: report pending, not a usable output.

Expected: pending. Evidence: uncovered.

Source: cardano-keri consumer-checklist point 5 (Singular side).

### Bonds, poison, the juvenility window W and the signature threshold: the checkpoint machine's and the treasury's policy, not Singular's.

Expected: out of scope — recorded, never claimed. Evidence: outside the registry's scope.

Source: cardano-keri consumer-checklist points 3-6 (cardano-keri side).

### Execution units (mem, cpu) and transaction size measured for every accepting row, against the devnet's Conway protocol maxima, with headroom stated.

Expected: recorded. Evidence: uncovered.

Source: issue #18 acceptance: limits measured.

### The fold batch-size boundary: the largest Modify batch that succeeds and the smallest that fails, with the failure reason.

Expected: an actual observed boundary, N accepted and N+1 refused. Evidence: uncovered.

Source: issue #18 acceptance: limits measured.

### Exact environment: cardano-node version, GHC, Aiken toolchain, blueprint hashes, and the environments explicitly not supported.

Expected: recorded from the running node and the pinned flakes. Evidence: uncovered.

Source: issue #18 acceptance: limits measured.

### Hold a valid fold constant and remove only the state-owner required signer; the observation (accept or refuse) is recorded with its transaction — the regression property the independent verification (F-002) specified.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; the no-owner-signer property is recorded history, not a live gate). Evidence: bound elsewhere.

Source: Singular.Statements.fold_iff sufficiency direction (Lean); observation history: FAILED against the pre-#79 candidate (owner gate), ACCEPTED against the repaired candidate by execution.

### One `insertActive` request folds on the open registry and places exactly one `(activePolicy, key)` token in the output at the address and inline datum the request named. A second `insertActive` at the same known key is refused `key-exists`. A two-request batch at two DISTINCT keys whose claimed mint agrees per kind but disagrees per `(kind, key)` is refused `net-mint-mismatch`.

Expected: accept the fold; refuse the same-key duplicate `key-exists`; refuse the two-key wrong-distribution batch `net-mint-mismatch`; both refusals carry an accepting control. Evidence: uncovered.

Source: Singular.Statements.insert_active_transaction_row and Singular.Statements.fold_batch_claimed_mint_by_kind_key (Lean 854f56f); issue #173; A-001, A-006, NOTE-014.

### On a real devnet, `insertActive` then `updateTerminal` at one key: the active witness the insert delivered is the exact input the retirement burns, exactly one `(activePolicy, key)` is destroyed, no output carries it afterwards, and the committed trie leaf becomes Terminal. `updateTerminal` on an Unknown key and on an Absent key are refused with their own named reasons, each against an accepting control.

Expected: accept the insert and the retirement; the active quantity goes 1 -> 0 with the exact keyed `-1` mint burned from its token-bearing source input and the committed leaf reading `Terminal`; refuse `updateTerminal` on an Unknown key `key-unknown` and on an Absent key `not-booked`, each with an accepting control. Evidence: uncovered.

Source: Singular.Statements.update_terminal_transaction_row and Singular.Statements.update_terminal_inversion (Lean 871c5df); issue #177; A-002.


## Registering a key

The example starts with a request to register one key and send its active token to the requested address. The run report describes applying that request and then attempting to register the same key again. A separate successful transaction provides a comparison for the rejected duplicate. Each case below changes one part of that report.

<details>
<summary>Formal specification for this chapter</summary>

```text
Singular.Statements.insert_active_transaction_row
Revision: 265c595
Statement digest: bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737
```

</details>

### The requested address must receive exactly one active token for the registered key

<details>
<summary>Rules quoted from the formal specification</summary>

```text
address := some r.output
assets := [((.active, r.key), 1)]
kindCount t.state .active r.key = 1

```

</details>

#### A registration report is accepted when the requested address receives one active token for the key

Expected result: the report is accepted.

<details>
<summary>Exact change made to the example report</summary>

```text
unchanged
```

</details>

#### A registration report is rejected if no active token is delivered

The recipient must receive one active token; receiving none does not establish registration.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
deliver: nothing
```

</details>

#### A registration report is rejected if two active tokens are delivered for the same key

The recipient must receive exactly one active token for this key, not two.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
deliver: activeToken "743137332d696e736572742d616374697665" 2
```

</details>

#### A registration report is rejected if the delivered token comes from the wrong minting policy

The open-policy token cannot stand in for the active token required by this registration.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
deliver: token "4a2f1c9e83b70d5641ae2c08df93b1760ea5c42d8f6b3019ac7e5d22" "743137332d696e736572742d616374697665" 1
```

</details>

#### A registration report is rejected if the token names a different key

The token name must identify the registered key. A token naming another key does not meet the requirement.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
deliver: token "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "6f74686572" 1
```

</details>

#### A registration report is rejected if the token goes to the wrong address

The request specifies who receives the token. Delivery to another address does not satisfy it.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
observedAddress "60ffffffffffffffffffffffffffffffffffffffffffffffffffffff"
```

</details>

### Not yet demonstrated: Registration preserves the signatures supplied with the approval

Not demonstrated: the report does not record which signatures the approval carried

### Applying the registration request must create one active token for its key

<details>
<summary>Rules quoted from the formal specification</summary>

```text
mint := [((.active, r.key), 1)]

```

</details>

#### A registration report is rejected if no active token was created for the key

Applying the request must create the active token that the recipient receives.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
minted: nothing
```

</details>

### The open registry application takes no parameters

<details>
<summary>Rules quoted from the formal specification</summary>

```text
openPolicyParameters = []

```

</details>

#### A registration report is rejected if the open application declares a parameter

The open application takes no parameters. A report describing an application with a parameter does not describe it.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
openParameters 1
```

</details>

### Applying this registration request pays no refund

<details>
<summary>Rules quoted from the formal specification</summary>

```text
refunds := []

```

</details>

#### A registration report is rejected if applying the request also pays a refund

This registration is specified to pay no refund. A reported refund contradicts that result.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
refunds: lovelace 1000000
```

</details>

### Applying this registration request requires no additional signer

<details>
<summary>Rules quoted from the formal specification</summary>

```text
signers := []

```

</details>

#### A registration report is rejected if applying the request requires a signer

This request-processing transaction requires no signer. The report must not add that requirement.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
signers: signer "60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b"
```

</details>

### The request must supply enough ada to pay the processing tip

<details>
<summary>Rules quoted from the formal specification</summary>

```text
lovelaceCoversTip s.config lovelace = true

```

</details>

#### A registration report is rejected if the request cannot pay the processing tip

The request supplies 999,999 lovelace, which is below the 1,000,000-lovelace processing tip in this example.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
requestLovelace 999999
```

</details>

### The delivery address must match the approval

<details>
<summary>Rules quoted from the formal specification</summary>

```text
destinationDatumBinds r = true

```

</details>

#### A registration report is rejected if the approval does not match the delivery address

The recorded approval must match the approval calculated for the requested destination.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
approvalRecomputed "00112233445566778899001122334455667788990011223344556677"
```

</details>

### Applying a request may update the registry contents but must preserve its other settings

<details>
<summary>Rules quoted from the formal specification</summary>

```text
onlyRootChanged s.config t.state.config = true

```

</details>

#### A registration report is rejected if applying the request changes the maximum fee

Processing a registration updates the registry contents, not the maximum fee or other settings.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
configAfter: max fee 2000000; other pins unchanged
```

</details>

#### A registration report is rejected if the original settings are missing

The report needs the settings from before and after processing so they can be compared.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
configBefore: no pins
```

</details>

### Registering an already registered key must fail

<details>
<summary>Rules quoted from the formal specification</summary>

```text
txOf t.state r₂ lovelace = .error "key-exists"

```

</details>

#### Evidence of a rejected duplicate registration is accepted without a script log

A script can fail without emitting a log. The report still identifies the rejected transaction and failing script.

Expected result: the report is accepted.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: without trace
```

</details>

#### Rejects duplicate-registration evidence that calls the same transaction both rejected and successful

The example needs a separate successful transaction to show that the duplicate key caused the rejection.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: controlTxid: "bb22222222222222222222222222222222222222222222222222222222222222"
```

</details>

#### Rejects duplicate-registration evidence that does not identify the script that failed

A failed transaction alone does not show that the intended script rejected the duplicate key.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: hashes: no failing script
```

</details>

#### Rejects duplicate-registration evidence with a blank identifier for the failing script

A blank script identifier cannot establish which script rejected the transaction.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: hashes: script ""
```

</details>

#### Rejects duplicate-registration evidence naming two keys instead of the one already registered

This example attempts to register the one key already registered earlier in the run.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: keys: key "743137332d696e736572742d616374697665"; key "743137332d6b6579656d696e742d62"
```

</details>

#### Rejects duplicate-registration evidence naming a key this run never registered

To demonstrate a duplicate, this run must first register the same key.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: keys: key "743137332d6b6579656d696e742d61"
```

</details>

#### Rejects duplicate-registration evidence mixed with token allocation data from the separate batch example

The duplicate-registration example and the token-allocation example must remain separate reports.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 2
```

</details>

#### Rejects duplicate-registration evidence if the rejected transaction also appears among successful transactions

The same transaction cannot be reported as both rejected and successfully applied.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: txid: "ee55555555555555555555555555555555555555555555555555555555555555"
```

</details>

#### Rejects duplicate-registration evidence if the successful comparison transaction is absent from the run

The report must show that the successful comparison transaction was actually applied during this run.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg duplicate: controlTxid: "ff66666666666666666666666666666666666666666666666666666666666666"
```

</details>

## Allocating tokens across a batch of requests

Two requests register two different keys. Each needs one active token. Creating both tokens for the first key gives the right total but the wrong allocation: the second key receives none. The rejection report must describe that mistake and a successful comparison that creates one token for each key. These cases check the report supporting that claim.

<details>
<summary>Formal specification for this chapter</summary>

```text
Singular.Statements.fold_batch_claimed_mint_by_kind_key
Revision: 265c595
Statement digest: 9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988
```

</details>

### A batch must create the right number of tokens for each key, even when the total is correct

<details>
<summary>Rules quoted from the formal specification</summary>

```text
assetKindTotal (claimedMint [b₁, b₂]) k
assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false
foldBatch s [b₁, b₂] = .error "net-mint-mismatch"

```

</details>

#### A batch rejection report must explain what differs from the successful comparison

The report must explain why the rejected transaction differs from its successful comparison.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: distinguisher: ""
```

</details>

#### A batch rejection report cannot reuse the transaction from the duplicate-registration example

The wrong-allocation example and the duplicate-registration example are different transactions.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: txid: "bb22222222222222222222222222222222222222222222222222222222222222"
```

</details>

#### The batch and duplicate-registration examples must each identify their own successful comparison transaction

Each rejection example needs its own successful comparison so the cause of failure can be checked.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: controlTxid: "cc33333333333333333333333333333333333333333333333333333333333333"
```

</details>

#### A report about a two-key batch is rejected if it lists only one key

This example compares token allocation across two different keys, so both must be identified.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"
```

</details>

#### A report about a two-key batch is rejected if it lists the same key twice

Listing one key twice does not describe two separate registration requests.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"; key "743137332d6b6579656d696e742d61"
```

</details>

#### A report about a two-key batch is rejected if it lists three keys

This example processes two keys. A report about three keys does not describe the same batch.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"; key "743137332d6b6579656d696e742d62"; key "743137332d696e736572742d616374697665"
```

</details>

#### A report about a two-key batch is rejected if either key is blank

Both registration keys must be identified; a blank entry does not identify a key.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"; key ""
```

</details>

#### A batch rejection report cannot borrow a key from the separate single-registration example

The two-key batch is separate from the earlier single registration. Its report must name its own keys.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: keys: key "743137332d696e736572742d616374697665"; key "743137332d6b6579656d696e742d62"
```

</details>

#### Rejects a report that claims the total is correct while listing three tokens where two are required

This example is meant to expose a wrong allocation despite a correct total of two tokens. A total of three tests a different mistake.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 3
```

</details>

#### A report claiming a wrong allocation is rejected if each key actually receives its required token

One token for each key is the correct allocation. It cannot demonstrate rejection for an incorrect allocation.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 1; mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d62" 1
```

</details>

#### A batch rejection report is rejected if the claimed tokens name a key outside the batch

The claimed tokens must refer to the two registration keys named in this batch.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d696e736572742d616374697665" 2
```

</details>

#### A batch rejection report is rejected if the required tokens name a key outside the batch

The required tokens come from the requests in this batch, not from a registration elsewhere.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: entailedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d696e736572742d616374697665" 1; mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d62" 1
```

</details>

#### A batch rejection report must say which tokens the rejected transaction tried to create

Without the proposed token allocation, the report cannot show how it differs from the required allocation.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: claimedMint: no mint
```

</details>

#### A successful comparison must correct the allocation, not put both tokens at the first key again

The successful comparison must create one token per key. Putting both tokens at the first key repeats the rejected mistake.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: controlMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 2
```

</details>

#### A successful comparison must allocate its tokens to the two keys in the batch

The successful comparison must create one token for each of the two requested keys.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
onLeg keyedMint: controlMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 1; mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d696e736572742d616374697665" 1
```

</details>

#### A registration run report is rejected if the required batch-rejection example is missing

This run report is required to include the batch-rejection example. Leaving it out does not remove the requirement.

Expected result: the report is rejected.

<details>
<summary>Exact change made to the example report</summary>

```text
without keyedMint
```

</details>

### Not yet demonstrated: Every successful batch creates exactly the tokens its requests require

Not demonstrated as a separate claim: the reports record successful comparison transactions but do not establish this general rule

## Appendix: how this evidence is checked

The supporting tests check that reports are readable and complete, identify the script responsible for a rejection, and preserve the requirements inventory. Other checks make sure a published story describes the report actually tested and quotes the specification accurately. They make no additional registry promise. Tests for recognising the intended registry are compiled but are not yet run by this suite.
