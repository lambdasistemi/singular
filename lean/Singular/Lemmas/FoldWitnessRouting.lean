import Singular.Lemmas.FoldWitnessAdmission

/-! Conservation and exact routing of the finite termination witness. -/

namespace Singular

theorem spentOutputs_economic (unspent : EconomicUtxo) (transaction : EconomicTransaction) :
    spentOutputs unspent.ledger transaction.transaction =
      (economicSpent unspent transaction).map (·.output) := by
  simp [spentOutputs, EconomicUtxo.ledger, economicSpent, List.filter_map,
    List.map_map, Function.comp_def]

theorem terminationWitness_balance (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) (funded : fee ≤ funding) :
    balanced (terminationWitnessUnspent world funding).ledger
      (terminationWitnessTransaction world booking time funding fee).transaction = true := by
  have contents := (Statements.termination_request_carries_genuine_token world reachable booking pending).2.2.2.1
  have held : booking.request.contents.lovelace = booking.request.declaredTip + booking.request.carrierAda := by
    simp only [terminationExactContents, terminationDeclaredLovelace, Bool.and_eq_true, decide_eq_true_eq] at contents
    exact contents.2.2.2.1
  have amount : booking.request.contents.lovelace + funding =
      funding + booking.request.declaredTip - fee +
        (booking.request.contents.lovelace - booking.request.declaredTip) + fee := by omega
  simp only [balanced, spentOutputs_economic,
    terminationWitness_spent world reachable booking pending]
  simp [terminationWitnessTransaction, terminationWitnessResult, combineResults, emptyResult,
    applyEdge, foldLegacyRequest, foldProjectedRegistry, foldWitnessState, foldWitnessOrdinary,
    terminationWitnessOutput, outputLovelace, outputAssets, stateTokenSupport, stateTokenValue,
    assetSame, amount, Config.stateToken]

theorem terminationWitness_routing (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) (funded : fee ≤ funding) :
    foldRoutingRefusal world (terminationWitnessUnspent world funding)
      (terminationWitnessTransaction world booking time funding fee)
      (terminationWitnessResult world booking) = none := by
  have provenance := Statements.termination_request_carries_genuine_token world reachable booking pending
  have contents := provenance.2.2.2.1
  have shape : booking.request.contents.otherAssets = [] ∧
      booking.request.contents.applicationTags = [] := by
    simp only [terminationExactContents, Bool.and_eq_true, decide_eq_true_eq,
      terminationContentsShape] at contents
    exact ⟨contents.1.2.1, contents.1.2.2.2.2⟩
  have tags := Statements.booked_termination_tag_commits_to_own_operation world reachable booking pending
  have burned : requestTagsBurned (terminationWitnessUnspent world funding)
      (terminationWitnessTransaction world booking time funding fee) = true := by
    simp only [requestTagsBurned, terminationWitness_spent world reachable booking pending]
    simp [terminationWitnessTransaction, terminationWitnessOutput, foldWitnessState,
      foldWitnessOrdinary, tags.1, tags.2, exactBurns]
  have ordinary : foldOrdinaryLovelace
      [terminationWitnessOutput booking, foldWitnessState world.registry.config,
        foldWitnessOrdinary funding] = funding := by
    simp [foldOrdinaryLovelace, foldOrdinary, terminationWitnessOutput, foldWitnessState,
      foldWitnessOrdinary, tags.1]
  have root := reachable_world_root world reachable
  have balance := terminationWitness_balance world reachable booking pending time funding fee funded
  simp only [foldRoutingRefusal, terminationWitness_spent world reachable booking pending,
    terminationWitness_members world reachable booking pending, burned, balance, ordinary]
  simp [terminationWitnessTransaction, terminationWitnessOutput, foldWitnessState, foldWitnessOrdinary,
    foldStateShape, foldBareValue, root, shape.1, foldCarrierRefusal, foldSameQuantities,
    foldMint, foldCarrierTags, foldObligations, FoldMember.donation, funded]

end Singular
