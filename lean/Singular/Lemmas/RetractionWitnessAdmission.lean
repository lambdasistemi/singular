import Singular.Lemmas.RetractionWitness
import Singular.Lemmas.FoldWitnessRouting

/-! Presence, observation and selection for the finite retraction witness. -/

namespace Singular

theorem retractionWitness_observation (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (interval : Interval) (signers : List Nat) (funding fee : Nat) :
    economicObservationRefusal world (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) = none := by
  have fresh : (terminationWitnessUnspent world funding).all
      (fun p => p.1.tx != terminationWitnessFresh world + 1) = true := by
    apply List.all_eq_true.mpr
    intro entry member
    have bound := terminationWitnessUnspent_bound member
    simp only [bne_iff_ne]
    omega
  simp [economicObservationRefusal, terminationWitnessUnspent_unique world reachable funding,
    terminationWitnessUnspent_observes world reachable funding, retractionWitnessTransaction,
    fresh, foldWitnessOrdinary]

theorem retractionWitness_inputs (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (signers : List Nat) (funding fee : Nat) :
    retractionInputsRefusal (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) = none := by
  have member : booking.request.reference ∈ worldRequestReferences world :=
    List.mem_append_left _ (List.mem_map.mpr ⟨booking, pending, rfl⟩)
  have one : booking.request.reference ≠ ⟨terminationWitnessFresh world, 1⟩ := by
    intro equal; exact terminationWitnessFresh_absent world 1 (equal ▸ member)
  have distinct : ((retractionWitnessTransaction world booking interval signers funding fee).transaction.inputs.map (·.ref)).Nodup := by
    simp [retractionWitnessTransaction, retractionWitnessInputs, foldWitnessInput, one]
  have present : inputPresenceRefusal (terminationWitnessUnspent world funding).ledger
      (retractionWitnessTransaction world booking interval signers funding fee).transaction = none := by
    have request : (terminationWitnessUnspent world funding).any
        (fun p => decide (p.1 = booking.request.reference)) = true := by
      apply List.any_eq_true.mpr
      refine ⟨(booking.request.reference, registrationWitnessOutput booking), ?_, by simp⟩
      simp only [terminationWitnessUnspent, List.mem_append, List.mem_map]
      exact Or.inl (Or.inl ⟨booking, pending, rfl⟩)
    have fresh : (terminationWitnessUnspent world funding).any
        (fun p => decide (p.1 = ⟨terminationWitnessFresh world, 1⟩)) = true := by
      simp [terminationWitnessUnspent]
    simpa [inputPresenceRefusal, inputPresent, EconomicUtxo.ledger,
      retractionWitnessTransaction, retractionWitnessInputs, foldWitnessInput,
      List.any_map] using And.intro request fresh
  simp only [retractionInputsRefusal, distinct, not_true_eq_false, ↓reduceIte, spentOutputs_economic,
    retractionWitness_spent world reachable booking pending]
  simp only [registrationWitnessOutput, foldWitnessOrdinary, List.map_cons, List.map_nil,
    List.any_cons, List.any_nil]
  simpa [disjointInputs, retractionWitnessTransaction, inputsContainReference] using present

theorem retractionWitness_request (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (signers : List Nat) (funding fee : Nat) :
    retractionRequest world (retractionWitnessTransaction world booking interval signers funding fee) =
      .ok booking.request := by
  have selected := retractionWitness_selection world reachable booking pending
  have noTerm : world.terminations.any (fun b => inputsContainReference
      (retractionWitnessInputs world booking) b.request.reference) = false := by
    apply Bool.eq_false_iff.mpr
    intro yes
    obtain ⟨b, member, consumed⟩ := List.any_eq_true.mp yes
    have included : b ∈ world.terminations.filter (fun b => inputsContainReference
        (retractionWitnessInputs world booking) b.request.reference) :=
      List.mem_filter.mpr ⟨member, consumed⟩
    rw [selected.2] at included
    contradiction
  simp [retractionRequest, retractionWitnessTransaction, noTerm, selected.1,
    pure, Except.pure, bind, Except.bind]

theorem retractionWitness_balance (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (signers : List Nat) (funding fee : Nat) (funded : fee ≤ funding) :
    balanced (terminationWitnessUnspent world funding).ledger
      (retractionWitnessTransaction world booking interval signers funding fee).transaction = true := by
  have amount : booking.request.contents.lovelace + funding =
      booking.request.contents.lovelace + (funding - fee) + fee := by omega
  simp only [balanced, spentOutputs_economic,
    retractionWitness_spent world reachable booking pending]
  simp [retractionWitnessTransaction, foldWitnessOrdinary, registrationWitnessOutput,
    outputLovelace, outputAssets, stateTokenSupport, stateTokenValue, assetSame, amount]

end Singular
