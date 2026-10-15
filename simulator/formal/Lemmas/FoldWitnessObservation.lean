import Singular.Lemmas.FoldWitness

/-! Coherent finite observations for the termination existence witness. -/

namespace Singular

theorem member_le_nat_sum {values : List Nat} {value : Nat} (member : value ∈ values) :
    value ≤ values.sum := by
  induction values with
  | nil => simp at member
  | cons first rest ih =>
    simp only [List.mem_cons] at member
    rcases member with rfl | later
    · simp
    · have := ih later; simp only [List.sum_cons]; omega

theorem terminationWitnessFresh_bound {world : World} {ref : OutRef}
    (member : ref ∈ worldRequestReferences world) : ref.tx < terminationWitnessFresh world := by
  have bound := member_le_nat_sum (List.mem_map.mpr ⟨ref, member, rfl⟩ :
    ref.tx ∈ (worldRequestReferences world).map (·.tx))
  unfold terminationWitnessFresh
  omega

theorem terminationWitnessFresh_absent (world : World) (index : Nat) :
    (⟨terminationWitnessFresh world, index⟩ : OutRef) ∉ worldRequestReferences world := by
  intro member
  have := terminationWitnessFresh_bound member
  dsimp at this
  omega

theorem terminationWitnessUnspent_unique (world : World) (reachable : WorldReachable world)
    (funding : Nat) : ((terminationWitnessUnspent world funding).map Prod.fst).Nodup := by
  have unique := reachable_request_references world reachable
  have absent := terminationWitnessFresh_absent world
  simpa only [terminationWitnessUnspent, List.map_append, List.map_map, Function.comp_def,
    List.map_cons, List.map_nil, worldRequestReferences] using
    (show (worldRequestReferences world ++
      ([⟨terminationWitnessFresh world, 0⟩, ⟨terminationWitnessFresh world, 1⟩] : List OutRef)).Nodup from by
        simp only [List.nodup_append]
        refine ⟨unique, by simp [OutRef.mk.injEq], ?_⟩
        intro ref member other otherMember equal
        rcases List.mem_cons.mp otherMember with rfl | otherMember
        · exact absent 0 (equal ▸ member)
        · have same := List.mem_singleton.mp otherMember
          exact absent 1 ((equal.trans same) ▸ member))

theorem terminationWitnessUnspent_observes (world : World) (reachable : WorldReachable world)
    (funding : Nat) : observesWorld world (terminationWitnessUnspent world funding) = true := by
  have unique := terminationWitnessUnspent_unique world reachable funding
  simp only [observesWorld, Bool.and_eq_true, List.all_eq_true]
  constructor
  · intro booking member
    have lookup := economicLookup_of_member unique
      (show (booking.request.reference, registrationWitnessOutput booking) ∈
        terminationWitnessUnspent world funding from by
          simp only [terminationWitnessUnspent, List.mem_append, List.mem_map]
          exact Or.inl (Or.inl ⟨booking, member, rfl⟩))
    simp [observesRegistration, lookup, registrationWitnessOutput, foldWitnessOrdinary]
  · intro booking member
    have lookup := economicLookup_of_member unique
      (show (booking.request.reference, terminationWitnessOutput booking) ∈
        terminationWitnessUnspent world funding from by
          simp only [terminationWitnessUnspent, List.mem_append, List.mem_map]
          exact Or.inl (Or.inr ⟨booking, member, rfl⟩))
    simp [observesTermination, lookup, terminationWitnessOutput, foldWitnessOrdinary]

theorem distinct_key_filter {α β : Type} [DecidableEq β] (key : α → β)
    {values : List α} (unique : (values.map key).Nodup) {value : α} (member : value ∈ values) :
    values.filter (fun v => decide (key v = key value)) = [value] := by
  induction values with
  | nil => simp at member
  | cons first rest ih =>
    have distinct := List.nodup_cons.mp unique
    rcases List.mem_cons.mp member with rfl | later
    · have empty : rest.filter (fun v => decide (key v = key value)) = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro v member
        simp only [decide_eq_true_eq]
        intro same
        exact distinct.1 (same ▸ List.mem_map.mpr ⟨v, member, rfl⟩)
      simp [empty]
    · have different : key first ≠ key value := by
        intro same
        exact distinct.1 (same ▸ List.mem_map.mpr ⟨value, later, rfl⟩)
      simpa [different] using ih distinct.2 later

theorem foldMemberAt_pending_termination (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations) :
    foldMemberAt world booking.request.reference = some (.termination booking) := by
  have unique := reachable_request_references world reachable
  have split := List.nodup_append.mp unique
  have registration : world.pending.find? (fun b => b.request.reference == booking.request.reference) = none := by
    apply List.find?_eq_none.mpr
    intro b member
    simp only [beq_iff_eq]
    intro equal
    exact split.2.2 _
      (List.mem_map.mpr ⟨b, member, rfl⟩)
      _ (List.mem_map.mpr ⟨booking, pending, rfl⟩) equal
  have selected := distinct_key_filter (fun b : TerminationBooking => b.request.reference) split.2.1 pending
  have found : world.terminations.find? (fun b => b.request.reference == booking.request.reference) = some booking := by
    rw [← List.head?_filter]
    have predicates : (fun b : TerminationBooking => b.request.reference == booking.request.reference) =
        (fun b => decide (b.request.reference = booking.request.reference)) := by
      funext b; apply Bool.eq_iff_iff.mpr; simp
    rw [predicates, selected]; rfl
  simp [foldMemberAt, registration, found]

theorem foldMemberAt_absent {world : World} {ref : OutRef}
    (absent : ref ∉ worldRequestReferences world) : foldMemberAt world ref = none := by
  have reg : world.pending.find? (fun b => b.request.reference == ref) = none := by
    apply List.find?_eq_none.mpr
    intro b member
    simp only [beq_iff_eq]
    intro equal
    exact absent (List.mem_append_left _ (List.mem_map.mpr ⟨b, member, equal⟩))
  have term : world.terminations.find? (fun b => b.request.reference == ref) = none := by
    apply List.find?_eq_none.mpr
    intro b member
    simp only [beq_iff_eq]
    intro equal
    exact absent (List.mem_append_right _ (List.mem_map.mpr ⟨b, member, equal⟩))
  simp [foldMemberAt, reg, term]

end Singular
