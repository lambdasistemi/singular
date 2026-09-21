# The registry's promises

A registry commits a map of keys to a root. Requests ask it to change a key; a fold applies those requests. Active tokens witness active registrations.

Read the requirements first, then the active-registration and batch stories. Each case states what is accepted or refused, why, and the exact observation it changes.

## What has been demonstrated

The stories below passed against the receipt loader. They check the evidence a run must supply; they do not execute new chain transactions or turn uncovered requirements into demonstrated behavior. This book includes no live run receipts.

## Requirements and remaining evidence

These requirements and their planned states come directly from rows.json. Only a matching run receipt can establish execution. Bound-elsewhere points to existing evidence; uncovered remains uncovered.

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


## Insert active registrations

```text
Singular.Statements.insert_active_transaction_row @265c595 bfb4e317…
  the destination holds exactly one active token at the requested address
      · address := some r.output
      · assets := [((.active, r.key), 1)]
      · kindCount t.state .active r.key = 1
      accepts: one active token at the key, at the address the request named
          edit unchanged
      refuses: no token delivered
          because the conclusion is exactly one, so zero is a distinct defect from a wrong one
          edit deliver: nothing
      refuses: two tokens delivered at the key
          because a per-kind total cannot see a quantity right in kind and wrong in count
          edit deliver: activeToken "743137332d696e736572742d616374697665" 2
      refuses: a token delivered under the open policy instead of the active one
          because the policy is half the token identity; an open-policy token is never the active witness
          edit deliver: token "4a2f1c9e83b70d5641ae2c08df93b1760ea5c42d8f6b3019ac7e5d22" "743137332d696e736572742d616374697665" 1
      refuses: a token whose asset name is not the key
          because the asset name is the key; a token under another name is a different holding
          edit deliver: token "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "6f74686572" 1
      refuses: a token observed at an address the request did not name
          because the destination is the address the request named; the same token elsewhere misses it
          edit observedAddress "60ffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    ※ unexercised: the signature-set invariance conjunct
        no receipt field carries the approval's signature set
  the fold mints exactly one active token at the key
      · mint := [((.active, r.key), 1)]
      refuses: a mint that is not exactly one token at the key
          because the fold must mint what the destination holds; an empty mint funds nothing
          edit minted: nothing
  the open application declares no parameter
      · openPolicyParameters = []
      refuses: an open application that declares a parameter
          because the open policy is parameterless; a declared parameter names a different application
          edit openParameters 1
  the fold pays no refund
      · refunds := []
      refuses: a fold that paid a refund
          because the concluded transaction refunds nothing; a paid refund moves value the rule never sends
          edit refunds: lovelace 1000000
  the fold requires no signer
      · signers := []
      refuses: a fold that required a signer
          because the concluded transaction is unsigned; a required signer adds an authorization the rule never grants
          edit signers: signer "60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b"
  the request lovelace covers the tip
      · lovelaceCoversTip s.config lovelace = true
      refuses: a request whose lovelace does not cover the tip
          because the hypothesis needs the tip on hand; below it the rule does not apply
          edit requestLovelace 999999
  the destination is bound by the approval
      · destinationDatumBinds r = true
      refuses: a destination binding the approval does not carry
          because equality of the carried and recomputed approval name is the binding; a mismatch delivers where nothing authorized
          edit approvalRecomputed "00112233445566778899001122334455667788990011223344556677"
  only the root pin moves
      · onlyRootChanged s.config t.state.config = true
      refuses: a fold that moved a non-root configuration pin
          because only the root may move; any other difference is a configuration change the fold must not make
          edit configAfter: max fee 2000000; other pins unchanged
      refuses: a configuration observation that lost a pin
          because the pin comparison needs both sides; a lost pin is an unobserved configuration, not an unchanged one
          edit configBefore: no pins
  a second insert at the same key is refused
      · txOf t.state r₂ lovelace = .error "key-exists"
      accepts: a leg whose trace the ledger did not surface is accepted
          because a script-execution failure carries an empty log list, so absence is the normal case, not an incomplete leg
          edit onLeg duplicate: without trace
      refuses: a leg whose control is the transaction it refused
          because the control must be an accepted transaction; a leg that controls for itself proves the builder can build nothing
          edit onLeg duplicate: controlTxid: "bb22222222222222222222222222222222222222222222222222222222222222"
      refuses: a leg naming no failing script
          because attribution needs the failing script; without it the refusal blames nothing
          edit onLeg duplicate: hashes: no failing script
      refuses: a leg naming an empty failing script
          because an empty hash attributes to nothing
          edit onLeg duplicate: hashes: script ""
      refuses: a duplicate leg naming two keys
          because the duplicate names the one occupied key; a second key belongs to the other fixture
          edit onLeg duplicate: keys: key "743137332d696e736572742d616374697665"; key "743137332d6b6579656d696e742d62"
      refuses: a duplicate leg naming a key the fold did not insert
          because the refusal is key-exists on the inserted key; a key the fold never inserted cannot exist yet
          edit onLeg duplicate: keys: key "743137332d6b6579656d696e742d61"
      refuses: a duplicate leg carrying mint arithmetic
          because the duplicate is refused before any mint runs; arithmetic on it claims to be the keyed-mint witness
          edit onLeg duplicate: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 2
      refuses: a refused transaction that also landed as a fold
          because a refused transaction never lands; a landed txid identifies an acceptance, not a refusal
          edit onLeg duplicate: txid: "ee55555555555555555555555555555555555555555555555555555555555555"
      refuses: a control that never landed a fold
          because the control must be a landed accepting fold; a transaction the run never landed accepts nothing
          edit onLeg duplicate: controlTxid: "ff66666666666666666666666666666666666666666666666666666666666666"
```

## Batch minting at distinct keys

```text
Singular.Statements.fold_batch_claimed_mint_by_kind_key @265c595 9c01e278…
  a two-key batch agreeing per kind but not per key is refused
      · assetKindTotal (claimedMint [b₁, b₂]) k
      · assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false
      · foldBatch s [b₁, b₂] = .error "net-mint-mismatch"
      refuses: a leg whose distinguisher is empty
          because the pair's value is exactly one differing thing; an empty distinguisher states none
          edit onLeg keyedMint: distinguisher: ""
      refuses: a keyed-mint leg reusing the duplicate's transaction
          because each refusal names its own transaction; a shared txid merges two distinct facts
          edit onLeg keyedMint: txid: "bb22222222222222222222222222222222222222222222222222222222222222"
      refuses: two legs sharing one accepting control
          because each refusal carries its own accepting control; one control for both proves neither pair
          edit onLeg keyedMint: controlTxid: "cc33333333333333333333333333333333333333333333333333333333333333"
      refuses: a keyed-mint leg naming one key
          because the witness names two distinct keys; one key cannot disagree with itself
          edit onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"
      refuses: a keyed-mint leg naming the same key twice
          because two entries for one key are one key; the batch must name two distinct ones
          edit onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"; key "743137332d6b6579656d696e742d61"
      refuses: a keyed-mint leg naming three keys
          because the witness is a two-key batch; a third key is a different batch
          edit onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"; key "743137332d6b6579656d696e742d62"; key "743137332d696e736572742d616374697665"
      refuses: a keyed-mint leg naming an empty key
          because an empty key is not a key the batch consumed
          edit onLeg keyedMint: keys: key "743137332d6b6579656d696e742d61"; key ""
      refuses: a keyed-mint leg reusing the fold's own key
          because the witness is a batch of its own; the fold's key belongs to the other observation
          edit onLeg keyedMint: keys: key "743137332d696e736572742d616374697665"; key "743137332d6b6579656d696e742d62"
      refuses: a keyed-mint leg whose claim also disagrees per kind
          because a claim that also disagrees per kind is a net mismatch, not the keyed fault this witness exhibits
          edit onLeg keyedMint: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 3
      refuses: a keyed-mint leg whose claim agrees per key as well
          because a claim matching the entailment per key agrees everywhere; nothing distinguishes it from its control
          edit onLeg keyedMint: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 1; mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d62" 1
      refuses: a keyed-mint leg claiming a mint at neither named key
          because the claim must sit at a named key; a mint elsewhere is unobserved arithmetic
          edit onLeg keyedMint: claimedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d696e736572742d616374697665" 2
      refuses: a keyed-mint leg entailing a mint at neither named key
          because the entailment is read off the batch's own edges; an edge elsewhere entails nothing here
          edit onLeg keyedMint: entailedMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d696e736572742d616374697665" 1; mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d62" 1
      refuses: a keyed-mint leg with no claimed mint at all
          because a claim with nothing to compare is not an observation; the pair comes whole or not at all
          edit onLeg keyedMint: claimedMint: no mint
      refuses: a keyed-mint control that minted the refused claim
          because the control is the same batch with the right distribution; minting the refused claim repeats the defect
          edit onLeg keyedMint: controlMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 2
      refuses: a keyed-mint control that minted at another key
          because the control must mint exactly what the batch entails; another key is another distribution
          edit onLeg keyedMint: controlMint: mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d6b6579656d696e742d61" 1; mint "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c" "743137332d696e736572742d616374697665" 1
      refuses: an absent keyed-mint leg is refused
          because an absent leg is an incomplete row, never an absent requirement
          edit without keyedMint
    ※ unexercised: the accepted-fold agreement conjunct
        agreement on an accepted fold as a standalone conclusion; the controls witness landings, not the asset-same equation
```

## Appendix: how this evidence is checked

The Support modules check receipt parsing, refusal attribution, inventory and observation completeness. Story modules check the language and its two interpreters. They make no additional registry promise. Authentication checks remain compiled but unwired, tracked separately.
