import Singular.Lemmas.FoldSums

/-! The observed input value is partitioned into continued state, ordinary
funding and the held value of consumed booked requests. -/

namespace Singular

theorem foldOrdinary_state {output : EconomicOutput} (ordinary : foldOrdinary output = true) :
    output.output.stateTokens = 0 := by
  simp only [foldOrdinary, Bool.and_eq_true, beq_iff_eq] at ordinary
  exact ordinary.1.1.1

set_option maxRecDepth 2048 in
theorem foldPrerequisite_input_categories {world : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : foldPrerequisite world u tx = none) :
    ∀ entry ∈ u, inputsContainReference tx.transaction.inputs entry.1 = true →
      foldMemberAt world entry.1 = none →
      0 < entry.2.output.stateTokens ∨ foldOrdinary entry.2 = true := by
  unfold foldPrerequisite at accepted
  simp only [bind, pure, Option.bind] at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all [List.all_eq_true] <;> grind

set_option maxRecDepth 2048 in
theorem fold_observed_request_value {world : World} {u : EconomicUtxo}
    (reachable : WorldReachable world) (unique : (u.map Prod.fst).Nodup)
    (observations : observesWorld world u = true)
    {ref : OutRef} {output : EconomicOutput} (member : (ref, output) ∈ u)
    (known : (foldMemberAt world ref).isSome = true) :
    foldReferenceWeight world FoldMember.held (some ref) = output.output.lovelace ∧
    output.output.stateTokens = 0 ∧ foldOrdinary output = false := by
  have lookup := economicLookup_of_member unique member
  have observed := Bool.and_eq_true_iff.mp observations
  cases registration : world.pending.find? (fun b => b.request.reference == ref) with
  | some b =>
    have pending := List.mem_of_find?_eq_some registration
    have same : b.request.reference = ref := by simpa using List.find?_some registration
    have contents := List.all_eq_true.mp observed.1 b pending
    unfold observesRegistration at contents
    rw [same, lookup] at contents
    simp only [decide_eq_true_eq] at contents
    obtain ⟨_, shape, _, _, _, value, state, _⟩ := contents
    have tags := (Statements.booked_request_tags_commit_to_own_fields world reachable b pending).1
    exact ⟨by simp [foldReferenceWeight, foldMemberAt, registration, FoldMember.held, value],
      state, by simp [foldOrdinary, shape, tags]⟩
  | none =>
    cases termination : world.terminations.find? (fun b => b.request.reference == ref) with
    | none => simp [foldMemberAt, registration, termination] at known
    | some b =>
      have pending := List.mem_of_find?_eq_some termination
      have same : b.request.reference = ref := by simpa using List.find?_some termination
      have contents := List.all_eq_true.mp observed.2 b pending
      unfold observesTermination at contents
      rw [same, lookup] at contents
      simp only [decide_eq_true_eq] at contents
      obtain ⟨_, shape, _, _, _, value, state, _⟩ := contents
      have tags := (Statements.booked_termination_tag_commits_to_own_operation world reachable b pending).1
      exact ⟨by simp [foldReferenceWeight, foldMemberAt, registration, termination, FoldMember.held, value],
        state, by simp [foldOrdinary, shape, tags]⟩

theorem fold_input_partition {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (reachable : WorldReachable world) (accepted : foldPrerequisite world u tx = none)
    (entry : OutRef × EconomicOutput) (member : entry ∈ u)
    (spent : inputsContainReference tx.transaction.inputs entry.1 = true) :
    entry.2.output.lovelace =
      (if 0 < entry.2.output.stateTokens then entry.2.output.lovelace else 0) +
      (if foldOrdinary entry.2 then entry.2.output.lovelace else 0) +
      foldReferenceWeight world FoldMember.held (some entry.1) := by
  have facts := rejectionObservation_world (foldPrerequisite_observations accepted).1
  cases selected : foldMemberAt world entry.1 with
  | some chosen =>
    obtain ⟨value, state, ordinary⟩ := fold_observed_request_value reachable facts.2.1 facts.1 member
      (by simp [selected])
    simp [value, state, ordinary]
  | none =>
    have categories := foldPrerequisite_input_categories accepted entry member spent selected
    have zero : foldReferenceWeight world FoldMember.held (some entry.1) = 0 := by
      simp [foldReferenceWeight, selected]
    rcases categories with state | ordinary
    · have notOrdinary : foldOrdinary entry.2 = false := by
        apply Bool.eq_false_iff.mpr
        intro yes
        have := foldOrdinary_state yes
        omega
      simp [state, notOrdinary, zero]
    · simp [foldOrdinary_state ordinary, ordinary, zero]

theorem fold_members_allocate {world : World} {tx : EconomicTransaction}
    (reachable : WorldReachable world) (member : FoldMember)
    (selected : member ∈ foldMembers world tx) :
    member.held = member.donation + member.tip + member.carrier := by
  cases member with
  | registration b =>
    have exact := (Statements.booked_request_has_exact_contents world reachable b
      (foldMembers_registration selected).1).1
    simp only [exactContents, Bool.and_eq_true, decide_eq_true_eq] at exact
    exact exact.1.2
  | termination b =>
    have exact := (Statements.termination_request_carries_genuine_token world reachable b
      (foldMembers_termination selected).1).2.2.2.1
    simp only [terminationExactContents, Bool.and_eq_true, decide_eq_true_eq] at exact
    have value := exact.2.2.2.1
    simp only [FoldMember.held, FoldMember.donation, FoldMember.tip, FoldMember.carrier,
      terminationDeclaredLovelace] at value ⊢
    omega

end Singular
