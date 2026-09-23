# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `073ba48b6c331c272615822f4c2920665cc0c0f2` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:67ef82d1e5f6a4c3fcf95ac3dcd4aeccbdb6f0e9849cc63b0286ab20 request:c404e3bf529fa8a92c9bd32ceceaa58fc48e7274d274a68ea3bfb4aa`.

Registration compared 5 requests: 3 accepted and 2 refused on chain.

Unsupported chain folds: 0.

Code revision: `073ba48b6c331c272615822f4c2920665cc0c0f2` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:67ef82d1e5f6a4c3fcf95ac3dcd4aeccbdb6f0e9849cc63b0286ab20 request:c404e3bf529fa8a92c9bd32ceceaa58fc48e7274d274a68ea3bfb4aa`.

Unnamed sequence compared 8 requests: 7 accepted and 0 refused on chain.

Unsupported chain folds: 1.

Code revision: `073ba48b6c331c272615822f4c2920665cc0c0f2` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:67ef82d1e5f6a4c3fcf95ac3dcd4aeccbdb6f0e9849cc63b0286ab20 request:c404e3bf529fa8a92c9bd32ceceaa58fc48e7274d274a68ea3bfb4aa`.

Retirement compared 7 requests: 5 accepted and 2 refused on chain.

Unsupported chain folds: 0.

## Register a key and receive its active token

A requester submits two distinct active registrations and then repeats one key. A redirected delivery is tried beside the same untampered request. Every step is compared with the executable registry model.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`.

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

- Submit **insertActive** for **redirect** in **registration** with redirect delivery. The same request without redirection is the untampered control.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

## Retire a registration and burn its active token

The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`.

### The holder receives the token that will be retired

- Submit **insertActive** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `88957e41876911a993c5d9a338f8ab006c9f6843`. Statement digest: `c85a4eb0a61907d71a0861658097e7ab839655023e39bfc4e11a8209553e31c2`.

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

Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada and the rule for required signers remain named unobservables. The two-request batch allocation has no driver comparison: the driver evaluates one request per transaction, leaving Singular.Statements.fold_batch_claimed_mint_by_kind_key without this executable consumer. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.

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

### witnessTerminal — observed gap

Reading a Terminal key is not yet supported: the node rejects the booking transaction before a fold is submitted.

The observed reason follows from the receipt.

```text
HardForkApplyTxErrFromEra S (S (S (S (S (S (Z (WrapApplyTxErr {unwrapApplyTxErr = ConwayApplyTxError (ConwayUtxowFailure (UtxoFailure (UtxosFailure (ValidationTagMismatch (IsValid True) (FailedUnexpectedly (PlutusFailure "\nThe PlutusV3 script failed:\nBase64-encoded script bytes:\n\"WQKqAQEAKYAKuiq6GroKq5+queqrnauaSIiIiWYAJkZTABMAgAGYBBgEgAzcOkAAkRLMAEwATAHN1QAUTMiMpgAkYAQAMiMjMAEAEAMiWYAIAMUwAQPYeoAAiZGSzABM3IgCgAxWYAJm48AUAGJm6VIAAzATMBEAJL1wRTABA9h6gABAPRMwBABDAVADQDxuuMA8AEwEgAUBBMlmACZuHSACMAs3VAAxS9b3tjBE3VmAeYBhuqABQChkZgAgAm6swDzAQMBAwEDAQMAw3VGAeASRLMAEAGKYAQPYeoAAiZGSzABM3IgDgAxWYAJm48AcAGJm6VIAAzARMA8AJL1wRTABA9h6gABANRMwBABDATADQDRuuMA0AEwEAAUA4kRLMAEyWYAIAMUoRMjMAEAEAIiWYAIAMUoxMlmACYBZgIm6oAGKzABM3EG60wFTASN1QAKQAETMAMAMwFgAopQQEEUoICAzAFAEN1xgKAAoCRAQGAGADFKMVmACYA5gGm6oAmJkZGRkswATAWABjMAE3WmAqAJN1xgKgBzdcYCoAU3WGAqACkREZGZEswATAdADiswAZgArMAEzcSkAAAPEzcSAOkAVFKCAupQpRQF0UoRMyJZgAgAwAorMAEwHwAYmSzABmACZuvMwEADwAUwBBdh5nwH/AKUKUUBpFKEVmADMAEzceACblDNxRm4ozcUZuKmAClGkAFAKXkgCQCDdcYD4A5uuMB8wIAB6UKUUBpFKEUooDRAaG64wHgAYASA4QHApQMA4AxAXRZAaG64wGgATdcYDQARgNAAosgJjAVABMBQAEwEwATAON1QBMWQDCAYGACACbrjALMAg3VABESzABABil64ImYBhgEmAaACZgBABGAcACgFosgDBgEAAmAGbqgCIpNE2VkAEAQ==\"\nThe script hash is:ScriptHash \"7a9e1742831da087e14275f99552ef8cc825ad7f6c30d309abe100f9\"\nThe plutus evaluation error is: CekError An error has occurred:\nThe machine terminated because of an error, either from a built-in function or from an explicit use of 'error'.\nCaused by: error\nThe protocol version is: Version 10\nScriptInfo: MintingScript 7a9e1742831da087e14275f99552ef8cc825ad7f6c30d309abe100f9\nTxInfo:\n  TxId: e477cfe7bae6c3c2cd5289931789ff05b8d2ead2678701d05e6e7370c4f79aac\n  Inputs: [ 64d968dbd1b4748aeec141974e66f4b1735a2c487455ebef6ac48272a7350335!3 -> - Value {getValue = Map {unMap = [(,Map {unMap = [(\"\",29999999319239234)]})]}} addressed to\n                                                                                    PubKeyCredential: f92331d882d35e05978c558352a66c61f476838e1e2fd1c4ae7fc0d6 (no staking credential)\n                                                                                    with datum\n                                                                                    no datum\n                                                                                    with referenceScript\n                                                                                     ]\n  Reference inputs: []\n  Outputs: [ - Value {getValue = Map {unMap = [(,Map {unMap = [(\"\",4000000)]}),(7a9e1742831da087e14275f99552ef8cc825ad7f6c30d309abe100f9,Map {unMap = [(0xd837bcaad19a6d7d3cd356b107e306b5327e6e64ec13b8db519a5a03dfd90c1b,1)]})]}} addressed to\n               ScriptCredential: d7a22557c28c88c065eee563ce6fd2db1c573c3de486d24751fd498d (no staking credential)\n               with datum\n               inline datum :  <<<WRxAuW5RA0lmUur5yCW1TjReom4krcr0pc9S9YZlYEw=>,\n               +SMx2ILTXgWXjFWDUqZsYfR2g44eL9HErn/A1g==,\n               c2VxdWVuY2UtYWN0aXZl,\n               6,\n               3000000,\n               1790155938684,\n               [YPkjMdiC014Fl4xVg1KmbGH0doOOHi/RxK5/wNY=, ]>>\n               with referenceScript\n\n           , - Value {getValue = Map {unMap = [(,Map {unMap = [(\"\",29999999313239234)]})]}} addressed to\n               PubKeyCredential: f92331d882d35e05978c558352a66c61f476838e1e2fd1c4ae7fc0d6 (no staking credential)\n               with datum\n               no datum\n               with referenceScript\n                ]\n  Fee: 2000000\n  Value minted: UnsafeMintValue {unMintValue = Map {unMap = [(7a9e1742831da087e14275f99552ef8cc825ad7f6c30d309abe100f9,Map {unMap = [(0xd837bcaad19a6d7d3cd356b107e306b5327e6e64ec13b8db519a5a03dfd90c1b,1)]})]}}\n  TxCerts: []\n  Wdrl: []\n  Valid range: (-\8734 , +\8734)\n  Signatories: [f92331d882d35e05978c558352a66c61f476838e1e2fd1c4ae7fc0d6]\n  Redeemers: [ ( Minting 7a9e1742831da087e14275f99552ef8cc825ad7f6c30d309abe100f9\n             , <6,\n             c2VxdWVuY2UtYWN0aXZl,\n             +SMx2ILTXgWXjFWDUqZsYfR2g44eL9HErn/A1g==,\n             [YPkjMdiC014Fl4xVg1KmbGH0doOOHi/RxK5/wNY=, ]> ) ]\n  Datums: []\n  Votes: []\n  Proposal Procedures: []\n  Current Treasury Amount: \n  Treasury Donation: \nRedeemer:\n  <6,\n  c2VxdWVuY2UtYWN0aXZl,\n  +SMx2ILTXgWXjFWDUqZsYfR2g44eL9HErn/A1g==,\n  [YPkjMdiC014Fl4xVg1KmbGH0doOOHi/RxK5/wNY=, ]>\n" "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" :| []))))) :| [])})))))))
```

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.
