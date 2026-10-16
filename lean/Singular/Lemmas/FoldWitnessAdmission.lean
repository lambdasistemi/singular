import Singular.Lemmas.FoldWitnessRegistry

/-! Every observed input and pending request is accounted for in the witness. -/

namespace Singular

theorem terminationWitnessUnspent_bound {world : World} {funding : Nat}
    {entry : OutRef × EconomicOutput} (member : entry ∈ terminationWitnessUnspent world funding) :
    entry.1.tx ≤ terminationWitnessFresh world := by
  simp only [terminationWitnessUnspent, List.mem_append, List.mem_map,
    List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with (⟨b, pending, rfl⟩ | ⟨b, pending, rfl⟩) | rfl | rfl
  · have := terminationWitnessFresh_bound
      (List.mem_append_left _ (List.mem_map.mpr ⟨b, pending, rfl⟩))
    exact Nat.le_of_lt this
  · have := terminationWitnessFresh_bound
      (List.mem_append_right _ (List.mem_map.mpr ⟨b, pending, rfl⟩))
    exact Nat.le_of_lt this
  · exact Nat.le_refl _
  · exact Nat.le_refl _

theorem terminationWitness_observation (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (time funding fee : Nat) :
    economicObservationRefusal world (terminationWitnessUnspent world funding)
      (terminationWitnessTransaction world booking time funding fee) = none := by
  have fresh : (terminationWitnessUnspent world funding).all
      (fun p => p.1.tx != terminationWitnessFresh world + 1) = true := by
    apply List.all_eq_true.mpr
    intro entry member
    have bound := terminationWitnessUnspent_bound member
    simp only [bne_iff_ne]
    omega
  simp [economicObservationRefusal, terminationWitnessUnspent_unique world reachable funding,
    terminationWitnessUnspent_observes world reachable funding, terminationWitnessTransaction,
    fresh, foldWitnessState, foldWitnessOrdinary]

theorem terminationWitness_prerequisite (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) :
    foldPrerequisite world (terminationWitnessUnspent world funding)
      (terminationWitnessTransaction world booking time funding fee) = none := by
  have member : booking.request.reference ∈ worldRequestReferences world :=
    List.mem_append_right _ (List.mem_map.mpr ⟨booking, pending, rfl⟩)
  have zero : booking.request.reference ≠ ⟨terminationWitnessFresh world, 0⟩ := by
    intro equal; exact terminationWitnessFresh_absent world 0 (equal ▸ member)
  have one : booking.request.reference ≠ ⟨terminationWitnessFresh world, 1⟩ := by
    intro equal; exact terminationWitnessFresh_absent world 1 (equal ▸ member)
  have distinct : ((terminationWitnessTransaction world booking time funding fee).transaction.inputs.map (·.ref)).Nodup := by
    simp [terminationWitnessTransaction, terminationWitnessInputs, foldWitnessInput, zero, one, OutRef.mk.injEq]
  have present : inputPresenceRefusal (terminationWitnessUnspent world funding).ledger
      (terminationWitnessTransaction world booking time funding fee).transaction = none := by
    have request : (terminationWitnessUnspent world funding).any
        (fun p => decide (p.1 = booking.request.reference)) = true := by
      apply List.any_eq_true.mpr
      refine ⟨(booking.request.reference, terminationWitnessOutput booking), ?_, by simp⟩
      simp only [terminationWitnessUnspent, List.mem_append, List.mem_map]
      exact Or.inl (Or.inr ⟨booking, pending, rfl⟩)
    have fresh (index : Nat) (bound : index = 0 ∨ index = 1) :
        (terminationWitnessUnspent world funding).any
          (fun p => decide (p.1 = ⟨terminationWitnessFresh world, index⟩)) = true := by
      rcases bound with rfl | rfl <;> simp [terminationWitnessUnspent]
    have all := And.intro request (And.intro (fresh 0 (Or.inl rfl)) (fresh 1 (Or.inr rfl)))
    simpa [inputPresenceRefusal, inputPresent, EconomicUtxo.ledger,
      terminationWitnessTransaction, terminationWitnessInputs, foldWitnessInput,
      List.any_map] using all
  have categories : (terminationWitnessUnspent world funding).all (fun p =>
      !inputsContainReference (terminationWitnessTransaction world booking time funding fee).transaction.inputs p.1 ||
      (foldMemberAt world p.1).isSome || p.2.output.stateTokens > 0 || foldOrdinary p.2) = true := by
    apply List.all_eq_true.mpr
    intro entry inWorld
    by_cases spent : inputsContainReference (terminationWitnessTransaction world booking time funding fee).transaction.inputs entry.1 = true
    · have selected : entry ∈ (terminationWitnessUnspent world funding).filter
          (fun p => inputsContainReference
            (terminationWitnessTransaction world booking time funding fee).transaction.inputs p.1) :=
        List.mem_filter.mpr ⟨inWorld, spent⟩
      rw [terminationWitness_spent_entries world reachable booking pending] at selected
      rcases List.mem_cons.mp selected with rfl | selected
      · simp [foldMemberAt_pending_termination world reachable booking pending]
      · rcases List.mem_cons.mp selected with rfl | selected
        · simp [foldWitnessState, foldWitnessOrdinary]
        · have same := List.mem_singleton.mp selected
          subst entry
          simp [foldOrdinary, foldWitnessOrdinary]
    · simp [spent]
  simp only [foldPrerequisite, distinct, not_true_eq_false, ↓reduceIte,
    present, terminationWitness_observation world reachable booking time funding fee,
    terminationWitness_members world reachable booking pending, List.isEmpty_cons]
  simp [terminationWitnessTransaction, disjointInputs, Interval.valid, foldMemberRefusal]
  intro ref output member spent unknown zero
  have yes := List.all_eq_true.mp categories (ref, output) member
  simpa [terminationWitnessTransaction, spent, unknown, zero] using yes

end Singular
