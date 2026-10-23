import NoPin.Held.Equality
import NoPin.Witnesses

/-! Finite executed instances for the #741 hypotheses, not accepted law.
Expected economic values come from producer definitions; no expected acceptance
bit or observed payment is typed in a fixture. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 2000000

namespace NoPin.Held.Fixtures
open Singular

/-- Hypothesis fixture under #741, not accepted law; caller-supplied noncryptographic hash. -/
def hash : Hash := NoPin.Fixtures.demoHash
/-- Hypothesis fixture under #741, not accepted law; complete candidate registry identity. -/
def registry : TokenId := ⟨42, 77⟩
/-- Hypothesis fixture under #741, not accepted law; unchanged root configuration. -/
def config : Config := {
  root := rootOf [], minimumTip := 1, processTime := 100, retractTime := 100,
  applicationPolicy := 3, activePolicy := 4, absentPolicy := 5, terminalPolicy := 6,
  registryId := 42 }
/-- Hypothesis fixture under #741, not accepted law; genuine root genesis. -/
def initial : RegistryState := ⟨config, [], [], []⟩
/-- Hypothesis fixture under #741, not accepted law; request constructed through accepted booking syntax. -/
def insertion (key : Key) : Request :=
  let approval : Approval := {
    policy := config.applicationPolicy, edge := .insertActive,
    key := key, owner := 42, destination := 55,
    assetName := approvalAssetName .insertActive key 42 55 }
  { edge := .insertActive, key := key, owner := 42, output := 55,
    claimed := delta .insertActive, approval := some approval }
/-- Hypothesis fixture under #741, not accepted law; output obtained from the existing root producer. -/
def registered7 : Result := applyEdge initial (insertion 7)
/-- Hypothesis fixture under #741, not accepted law; second actual registration. -/
def registered8 : Result := applyEdge registered7.state (insertion 8)
/-- Executed root transition instance for #741, not accepted law of the candidate. -/
theorem initial_reachable : Reachable initial := Reachable.initial config
/-- Executed root transition instance for #741, not accepted law of the candidate. -/
theorem register7_accepted : step initial (insertion 7) = .ok registered7 := by rfl
/-- Executed root transition instance for #741, not accepted law of the candidate. -/
theorem register8_accepted : step registered7.state (insertion 8) = .ok registered8 := by rfl
/-- Executed root transition instance for #741, not accepted law of the candidate. -/
theorem registered_reachable : Reachable registered8.state :=
  Reachable.next (Reachable.next initial_reachable register7_accepted) register8_accepted
/-- Hypothesis fixture under #741, not accepted law; actual root holding producer. -/
def rootHolding (key : Key) : Singular.Holding := ⟨key, .active, 55, none⟩
/-- Hypothesis fixture under #741, not accepted law; abstract full witness identity and protected deposit. -/
def holding (key deposit : Nat) : Holding :=
  let token := roleAsset hash encode registry .witness key
  { reference := ⟨1, key⟩, family := 55, control := ⟨registry, key, 42, deposit⟩,
    token, quantity := 1, provenance := token, rootHolding := rootHolding key,
    payload := key + 100, lovelace := 10 + deposit }
/-- Hypothesis fixture under #741, not accepted law; exact root contents come from root naming. -/
def request (key : Key) : TerminationRequest :=
  let r : TerminationRequest := {
    reference := ⟨2, key⟩, registryId := config.registryId, key, destination := 55,
    declaredTip := 2, carrierAda := 8, singularTags := [config.singularTag key],
    contents := { lovelace := 10, applicationTags := [], trieReadyTags := [] }, nonce := key }
  { r with contents := { r.contents with trieReadyTags := [r.trieReadyTag config] } }
/-- Hypothesis fixture under #741, not accepted law; retained genuine custody and freshly observed tag. -/
def booking (key : Key) : TerminationBooking :=
  ⟨request key, [rootHolding key], [(request key).trieReadyTag config]⟩
/-- Hypothesis fixture under #741, not accepted law; disjoint physical value allocation. -/
def pending (key deposit : Nat) : Pending :=
  { holding := { holding key deposit with reference := (request key).reference }, booking := booking key }
/-- Hypothesis fixture under #741, not accepted law; two keys share one application family. -/
def before : ApplicationState :=
  { registryIdentity := registry, registry := registered8.state, registrations := [],
    outputs := [.live (holding 8 7), .live (holding 7 5)], treasury := 0 }
/-- Hypothesis fixture under #741, not accepted law; first actual booked candidate output. -/
def one : ApplicationState := bookEffect before (.live (holding 7 5)) (pending 7 5)
/-- Hypothesis fixture under #741, not accepted law; second actual booked candidate output. -/
def two : ApplicationState := bookEffect one (.live (holding 8 7)) (pending 8 7)
/-- Hypothesis fixture under #741, not accepted law; selected public pending observations. -/
def selected : List Pending := [pending 7 5, pending 8 7]

-- Only concrete instances use this tactic; no candidate statement is proved.
macro "held_decide" : tactic => `(tactic| (
  by_cases tags : (request 7).trieReadyTag config = (request 8).trieReadyTag config <;>
  simp (config := { maxSteps := 200000 }) only [Singular.exitStep, Singular.ownerOutputs, Singular.txOfExit, Singular.txOf, Singular.publicView, Singular.buildFold, Singular.retractionInputsRefusal, Singular.retractionRequest, Singular.retractionRefusal, Singular.retractionEffect, Singular.retractionAccepted, Singular.registryStateTokens, Singular.registryDatumForm, Singular.approvalsIn, Singular.onlyRootChanged, Singular.destinationDatum, Singular.datumHash, Singular.destinationDatumBinds, Singular.requiredSigners, Singular.withSignatures, Singular.openPolicyParameters, Singular.openApproval, Singular.openTupleGrid, Singular.openAdmitsEveryTuple, Singular.crossRegistrySeparation, Singular.mintRoutedTo, Singular.routedPayment, Singular.burnSourceRole, Singular.heldDatum, Singular.heldValue, Singular.burnSourceDatum, Singular.burnSourceValue, Singular.txBurnInputs, Singular.txStateOutput, Singular.txDestinationOutputs, Singular.cageAddress, Singular.txCageOutputs, Singular.foldWitnessInput, Singular.terminationWitnessInputs, Singular.terminationWitnessResult, Singular.terminationWitnessTransaction, Singular.worldRequestReferences, Singular.terminationWitnessFresh, Singular.foldWitnessOrdinary, Singular.registrationWitnessOutput, Singular.terminationWitnessOutput, Singular.foldWitnessState, Singular.terminationWitnessUnspent, Singular.EconomicUtxo, Singular.EconomicUtxo.ledger, Singular.economicLookup, Singular.economicSpent, Singular.applyEconomicTransaction, Singular.observesRegistration, Singular.observesTermination, Singular.observesWorld, Singular.economicObservationRefusal, Singular.exactBurns, Singular.applicationTagIdentity, Singular.requestTagsBurned, Singular.foldMemberAt, Singular.foldMembers, Singular.FoldMember.tip, Singular.FoldMember.donation, Singular.FoldMember.carrier, Singular.FoldMember.held, Singular.foldLegacyRequest, Singular.foldProjectedRegistry, Singular.foldRemainingTerminations, Singular.foldRegistryEffect, Singular.foldObligations, Singular.refundAmount, Singular.refundOwed, Singular.refundObligations, Singular.refundPaid, Singular.refundRefusal, Singular.rejectedRequests, Singular.obligations, Singular.presentsDatum, Singular.paysRecipient, Singular.unpaidReason, Singular.owedTo, Singular.receivedBy, Singular.requiresCarrier, Singular.settle, Singular.paymentPaid, Singular.spendRefusal, Singular.Utxo, Singular.inputsContainReference, Singular.disjointInputs, Singular.inputPresent, Singular.inputPresenceRefusal, Singular.applyTx, Singular.spentOutputs, Singular.outputLovelace, Singular.outputAssets, Singular.stateTokenValue, Singular.stateTokenSupport, Singular.balanced, Singular.RequestPool, Singular.book, Singular.bookTermination, Singular.bookTerminations, Singular.terminationDeclaredLovelace, Singular.terminationContentsShape, Singular.terminationExactContents, Singular.terminationCustody, Singular.terminationBookingRefusal, Singular.carriedSingularCount, Singular.pendingTerminationCount, Singular.worldSingularSupply, Singular.WorldSupplyConsistent, Singular.foldOrdinary, Singular.foldOrdinaryLovelace, Singular.foldBareValue, Singular.foldStateShape, Singular.foldSameQuantities, Singular.foldMint, Singular.foldCarrierTags, Singular.foldCarrierRefusal, Singular.foldRoutingRefusal, Singular.registrationRejectionGround, Singular.terminationRejectionGround, Singular.rejectionMemberRefusal, Singular.rejectionStateRefusal, Singular.rejectionInputsRefusal, Singular.rejectionSupplyUnchanged, Singular.rejectionRefusal, Singular.rejectionEffect, Singular.rejectionAccepted, Singular.Config.trieReadyTag, Singular.RegistrationRequest.operation, Singular.RegistrationRequest.trieReadyTag, Singular.Key, Singular.stateByte, Singular.encodeState, Singular.decodeState, Singular.retractableEdge, Singular.inPhase2, Singular.retractAdmission, Singular.inPhase1, Singular.foldAdmission, Singular.admittedFoldBatch, Singular.rejectAdmission, Singular.exitAdmission, Singular.admittedExitStep, Singular.admittedTxOfExit, Singular.exitRefusal, Singular.custodyKey, Singular.Interval.width, Singular.Interval.valid, Singular.Interval.contains, Singular.Config.bookingWidthSized, Singular.Config.stateToken, Singular.kindPolicy, Singular.tokenAssetName, Singular.Trie, Singular.trieGet, Singular.trieSet, Singular.trieErase, Singular.leafByte, Singular.datumFormName, Singular.datumFormOf, Singular.datumJson, Singular.datumOfJson, Singular.heldObservationJson, Singular.leafJson, Singular.kindCount, Singular.custodyCount, Singular.deltaKind, Singular.Asset, Singular.assetKind, Singular.assetPlus, Singular.assetSame, Singular.assetKindTotal, Singular.allowed, Singular.delta, Singular.transition, Singular.Action, Singular.assetDelta, Singular.requestClaim, Singular.claimedMint, Singular.actualMint, Singular.route, Singular.canonicalRequest, Singular.admitsFor, Singular.admits, Singular.refusal, Singular.emptyResult, Singular.combineResults, Singular.applyEdge, Singular.step, Singular.foldActions, Singular.batchConsumesCreated, Singular.foldBatch, Singular.Consistent, Singular.edgeOrdinal, Singular.Request.mk, Singular.deliveredDatum, Singular.requestDestination, Singular.Config.singularTag, Singular.TerminationRequest.operation, Singular.TerminationRequest.trieReadyTag, Singular.registrationApplicationTagValid, Singular.registrationDeclaredLovelace, Singular.registrationContentsShape, Singular.exactContents, Singular.registrationBookingRefusal, Singular.retractionFunding, Singular.retractionFundingRefusal, Singular.retractionFundingLovelace, Singular.requestAddressSpend, Singular.sweepAccepted, Singular.foldMemberRefusal, Singular.foldPrerequisite, Singular.foldEffect, Singular.foldAccepted, NoPin.Held.applyGuard, NoPin.Held.holdingOf, NoPin.Held.projectWith, NoPin.Held.project, NoPin.Held.liveSpend, NoPin.Held.genuine, NoPin.Held.book, NoPin.Held.bookEffect, NoPin.Held.releasedTo, NoPin.Held.localPayments, NoPin.Held.pendingRelease, NoPin.Held.couplingCheck, NoPin.Held.discoverWith, NoPin.Held.discover, NoPin.Held.consumeWith, NoPin.Held.consume, NoPin.Held.economicAvailability, NoPin.Held.controllerDeposit, NoPin.Held.inputDeposit, NoPin.Held.allocated, NoPin.Held.economicInputs, NoPin.Held.valuePartitionWith, NoPin.Held.valuePartition, NoPin.Held.physicalBalanced, NoPin.Held.acceptedFold, NoPin.Held.canonicalFold, NoPin.Held.canonicalTransaction, NoPin.Held.canonicalResult, NoPin.Held.canonicalPhysical, NoPin.Held.canonicalAssetView, NoPin.Held.canonicalLocal, NoPin.Held.composedWith, NoPin.Held.composed, before, one, two, pending, booking, request, holding, rootHolding, registered8, registered7, insertion, initial, config, registry, hash, NoPin.Fixtures.demoHash, NoPin.roleAsset, NoPin.encode, reduceBEq, List.erase, List.filterMap, List.filter, List.map, List.flatMap, List.foldl, List.foldr, List.sum, List.countP, List.count, List.find?, List.eraseDups, List.eraseDupsBy, List.zipIdx, List.zipIdx_cons, List.zipIdx_nil, List.eraseDupsBy.loop, List.contains, List.any, List.all, List.isEmpty, List.append, List.nodup_cons, List.nodup_nil, List.mem_cons, List.not_mem_nil, Option.bind, Option.map, Option.isSome, Option.toList, Except.isOk, Except.toOption, Bool.and_true, Bool.true_and, Bool.and_false, Bool.false_and, Bool.or_true, Bool.true_or, Bool.or_false, Bool.false_or, Bool.not_true, Bool.not_false, Bool.false_eq_true, Bool.true_eq_false, ite_true, ite_false, decide_true, decide_false, beq_self_eq_true, tags]
  <;> simp_all <;> try decide +kernel))

/-- Executed root projection instance for #741, not accepted candidate law. -/
theorem before_projects : (project before).registry = registered8.state := by rfl
/-- Executed actual root booking instance for #741, not accepted candidate law. -/
theorem book7_accepted : bookTermination (project before) (booking 7) = .ok (project one) := by held_decide
/-- Executed actual root booking instance for #741, not accepted candidate law. -/
theorem book8_accepted : bookTermination (project one) (booking 8) = .ok (project two) := by held_decide
/-- Executed reachable-world instance for #741, not accepted candidate law. -/
theorem before_reachable : WorldReachable (project before) := by
  rw [show project before = ⟨registered8.state, [], [], 0⟩ by rfl]
  exact WorldReachable.initial _ registered_reachable
/-- Executed reachable-world instance for #741, not accepted candidate law. -/
theorem one_reachable : WorldReachable (project one) :=
  WorldReachable.termination before_reachable (booking 7) book7_accepted
/-- Executed reachable-world instance for #741, not accepted candidate law. -/
theorem two_reachable : WorldReachable (project two) :=
  WorldReachable.termination one_reachable (booking 8) book8_accepted
/-- Hypothesis fixture under #741, not accepted law; actual root batch result, not an expected state. -/
def rootResult : Result := canonicalResult two selected
/-- Hypothesis fixture under #741, not accepted law; actual two-member economic fold. -/
def folded : FoldObservation := canonicalFold two selected 1000 20 1
/-- Hypothesis fixture under #741, not accepted law; physical amounts derived from the root plus deposits. -/
def physical : PhysicalView := canonicalPhysical selected folded
/-- Hypothesis fixture under #741, not accepted law; actual physical controller payments. -/
def localTx : LocalTransaction := canonicalLocal registry selected folded physical
/-- Executed candidate instance for #741, not accepted law; both views balance. -/
theorem fold_prerequisites : foldPrerequisite folded.before folded.unspent folded.transaction = none := by
  simp only [folded, selected]
  held_decide
/-- Executed candidate instance for #741, not accepted law; selected members are actual inputs. -/
theorem fold_members : foldMembers folded.before folded.transaction = selected.map (fun p => FoldMember.termination p.booking) := by
  rfl
/-- Executed candidate instance for #741, not accepted law; actual root batch result. -/
theorem fold_registry : foldBatch (foldProjectedRegistry folded.before)
    ((foldMembers folded.before folded.transaction).map (foldLegacyRequest folded.before.registry.config)) = .ok rootResult := by rfl
/-- Executed candidate instance for #741, not accepted law; actual selected unspent outputs. -/
theorem fold_spent : economicSpent folded.unspent folded.transaction =
    [terminationWitnessOutput (booking 8), terminationWitnessOutput (booking 7),
      foldWitnessState (project two).registry.config, foldWitnessOrdinary 20] := by rfl
/-- Kernel algebra for the #741 instance, not candidate behavioral law; collisions count twice. -/
theorem burns_two (a b : TokenId) : exactBurns [b, a] [(a, -1), (b, -1)] = true := by
  by_cases same : a = b
  · subst b; simp [exactBurns]
  · simp [exactBurns, same, Ne.symm same]
/-- Executed candidate instance for #741, not accepted law; actual tags, including possible collision. -/
theorem fold_tag_burns : requestTagsBurned folded.unspent folded.transaction = true := by
  change ((exactBurns [(request 8).trieReadyTag config, (request 7).trieReadyTag config]
    [((request 7).trieReadyTag config, -1), ((request 8).trieReadyTag config, -1)] &&
    exactBurns ([] : List TokenId) []) && true) = true
  rw [burns_two]
  rfl
/-- Executed candidate instance for #741, not accepted law; actual complete singular mint support. -/
theorem fold_singular_mint : foldSameQuantities folded.transaction.singularMint
    (foldMint folded.before.registry.config (foldMembers folded.before folded.transaction)) = true := by
  rw [fold_members]
  change foldSameQuantities (foldMint (project two).registry.config (selected.map (fun p => FoldMember.termination p.booking)))
    (foldMint (project two).registry.config (selected.map (fun p => FoldMember.termination p.booking))) = true
  simp [foldSameQuantities]
/-- Kernel shape normalization for #741, not accepted candidate law. -/
theorem witness_state_shape (c : Config) : foldStateShape c (foldWitnessState c) = true := by
  simp [foldStateShape, foldWitnessState, foldWitnessOrdinary, foldBareValue]
/-- Executed candidate instance for #741, not accepted law; produced economic outputs. -/
theorem fold_outputs : folded.transaction.outputs =
    [foldWitnessState rootResult.state.config,
      foldWitnessOrdinary (20 + (foldObligations (selected.map (fun p => FoldMember.termination p.booking))).tips - 1),
      { foldWitnessOrdinary 0 with output := { (foldWitnessOrdinary 0).output with address := some 42 } }] := by rfl
/-- Executed candidate instance for #741, not accepted law; root-selected ordinary funding. -/
theorem fold_ordinary : foldOrdinaryLovelace (economicSpent folded.unspent folded.transaction) = 20 := by decide +kernel
/-- Executed candidate instance for #741, not accepted law; actual root routing. -/
theorem fold_routing : foldRoutingRefusal folded.before folded.unspent folded.transaction rootResult = none := by
  have root := reachable_world_root (project two) two_reachable
  have balance : balanced folded.unspent.ledger folded.transaction.transaction = true := by decide +kernel
  simp only [foldRoutingRefusal, fold_spent, fold_tag_burns, fold_singular_mint, balance,
    fold_outputs, fold_ordinary]
  simp only [folded, canonicalFold] at root ⊢
  have membersRaw : foldMembers (project two) (canonicalTransaction two selected 1000 20 1) =
      selected.map (fun p => FoldMember.termination p.booking) := fold_members
  simp only [membersRaw]
  simp [canonicalTransaction, terminationWitnessOutput, foldWitnessState, foldWitnessOrdinary, witness_state_shape, foldStateShape,
    foldBareValue, root, fold_members, foldCarrierRefusal, foldCarrierTags, selected,
    foldObligations, FoldMember.donation, FoldMember.tip, pending, booking, request,
    foldOrdinaryLovelace, foldOrdinary, Config.singularTag, reduceBEq, List.findSome?,
    Bool.false_eq_true, Bool.true_eq_false]
/-- Executed candidate instance for #741, not accepted law; actual root admission. -/
theorem fold_executes : acceptedFold folded = true := by
  simp only [acceptedFold, foldAccepted, fold_prerequisites, fold_registry, fold_routing]
  have same : folded.after = foldEffect folded.before folded.transaction rootResult := by rfl
  rw [same]
  exact beq_self_eq_true _
/-- Executed candidate instance for #741, not accepted law; disjoint physical projection. -/
theorem partition_executes : valuePartition selected folded physical = true := by decide +kernel
/-- Executed candidate instance for #741, not accepted law; real pending authenticity. -/
theorem genuine7_executes : genuine .none hash encode config (.pending (pending 7 5)) = true := by
  held_decide
/-- Executed candidate instance for #741, not accepted law; real pending authenticity. -/
theorem genuine8_executes : genuine .none hash encode config (.pending (pending 8 7)) = true := by
  held_decide
/-- Executed candidate instance for #741, not accepted law; actual local release. -/
theorem release7_executes : pendingRelease .none hash encode config (pending 7 5) localTx = true := by
  simp only [pendingRelease, applyGuard]
  simp only [reduceBEq, ite_false, genuine7_executes, Bool.true_and]
  have spent : localTx.spent.contains (pending 7 5) = true := by
    change [pending 7 5, pending 8 7].contains (pending 7 5) = true
    simp
  rw [spent]
  decide +kernel
/-- Executed candidate instance for #741, not accepted law; actual local release. -/
theorem release8_executes : pendingRelease .none hash encode config (pending 8 7) localTx = true := by
  simp only [pendingRelease, applyGuard]
  simp only [reduceBEq, ite_false, genuine8_executes, Bool.true_and]
  have spent : localTx.spent.contains (pending 8 7) = true := by
    change [pending 7 5, pending 8 7].contains (pending 8 7) = true
    simp
  rw [spent]
  decide +kernel
/-- Executed candidate instance for #741, not accepted law; composed n>1 witness. -/
theorem composition_executes : composed hash encode registry selected folded physical = true := by
  change (((acceptedFold folded && valuePartition selected folded physical) && physicalBalanced folded physical) &&
    selected.all (fun p => pendingRelease .none hash encode config p localTx)) = true
  rw [fold_executes, partition_executes]
  have balance : physicalBalanced folded physical = true := by decide +kernel
  rw [balance]
  simp only [Bool.true_and, selected, List.all_cons, List.all_nil,
    release7_executes, release8_executes, Bool.and_true]
/-- Executed candidate instance for #741, not accepted law; pending is not counted as live custody. -/
theorem two_supplies : worldSingularSupply (project two) 7 = 1 ∧
    worldSingularSupply (project two) 8 = 1 := by decide +kernel
/-- Executed candidate instance for #741, not accepted law; actual root balance. -/
theorem root_balances : balanced folded.unspent.ledger folded.transaction.transaction = true := by decide +kernel
/-- Executed candidate instance for #741, not accepted law; actual physical balance. -/
theorem physical_balances : physicalBalanced folded physical = true := by decide +kernel
/-- Executed candidate instance for #741, not accepted law; producer-derived n>1 deposit sum. -/
theorem additive_deposits : localPayments localTx 42 =
    (holding 7 5).control.deposit + (holding 8 7).control.deposit := by decide +kernel
/-- Executed violating twin for #741, not accepted law; overlap fails the exact value partition. -/
theorem overlapping_deposit_refused :
    valuePartition selected folded { physical with inputs := economicInputs folded } = false := by
  decide +kernel
/-- Executed violating twin for #741, not accepted law; absent controller slice cannot settle deposits. -/
theorem missing_deposit_refused : pendingRelease .none hash encode config (pending 7 5)
    { localTx with payments := localTx.payments.map fun p =>
      if p.controller == 42 then { p with lovelace := 0 } else p } = false := by
  simp only [pendingRelease, applyGuard, reduceBEq, Bool.false_eq_true, ite_false]
  have unpaid : (releasedTo localTx.spent (pending 7 5).holding.family (pending 7 5).holding.control.controller <=
    localPayments { localTx with payments := localTx.payments.map fun p =>
      if p.controller == 42 then { p with lovelace := 0 } else p } (pending 7 5).holding.control.controller) = False := by decide +kernel
  simp only [unpaid, decide_false, Bool.false_eq_true, ite_false, Bool.and_false]
/-- Executed violating twin for #741, not accepted law; one correct fold cannot release another key. -/
theorem wrong_key_coupling_refused : couplingCheck .none registry 9
    (roleAsset hash encode registry .witness 9) localTx.assets folded = false := by
  simp only [couplingCheck, applyGuard, reduceBEq, Bool.false_eq_true, ite_false, fold_members]
  change (((_ && _) && false) && _) = false
  simp
/-- Executed violating twin for #741, not accepted law; a burn without a fold gives no coupling. -/
theorem no_fold_coupling_refused : couplingCheck .none registry 7 (holding 7 5).token localTx.assets
    { folded with transaction := { folded.transaction with transaction := {
      folded.transaction.transaction with inputs := [] } } } = false := by decide +kernel

/-- Executed #741 violating twin, not accepted law; equal policy with a different registry name refuses coupling. -/
theorem wrong_registry_coupling_refused : couplingCheck .none registry 7 (holding 7 5).token localTx.assets
    { folded with registryIdentity := { registry with name := registry.name + 1 } } = false := by decide +kernel
end NoPin.Held.Fixtures
