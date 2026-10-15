import Singular.Lemmas.FoldFacts

/-! Finite accounting over references. Spending-input claims never contribute
value: these lemmas reorder the actual observed unspent outputs. -/

namespace Singular

theorem distinct_subset_filter_perm {α : Type} [BEq α] [LawfulBEq α]
    (xs ys : List α) (nx : xs.Nodup) (ny : ys.Nodup) (included : xs ⊆ ys) :
    xs.Perm (ys.filter fun y => xs.contains y) := by
  apply List.perm_iff_count.mpr
  intro value
  rw [nx.count, List.Nodup.count (ny.filter _)]
  simp only [List.mem_filter, List.contains_iff_mem]
  by_cases present : value ∈ xs
  · simp [present, included present]
  · simp [present]

theorem economicLookup_of_member {u : EconomicUtxo} {ref : OutRef} {output : EconomicOutput}
    (unique : (u.map Prod.fst).Nodup) (member : (ref, output) ∈ u) :
    economicLookup u ref = some output := by
  induction u with
  | nil => simp at member
  | cons entry rest ih =>
    have distinct := List.nodup_cons.mp unique
    rcases List.mem_cons.mp member with equal | later
    · subst entry; simp [economicLookup]
    · have different : entry.1 ≠ ref := by
        intro same
        exact distinct.1 (same ▸ List.mem_map.mpr ⟨(ref, output), later, rfl⟩)
      simpa [economicLookup, different] using ih distinct.2 later

theorem sum_filter_nat {α : Type} (values : List α) (predicate : α → Bool)
    (weight : α → Nat) :
    ((values.filter predicate).map weight).sum =
      (values.map fun value => if predicate value then weight value else 0).sum := by
  induction values with
  | nil => rfl
  | cons value rest ih => cases h : predicate value <;> simp [h, ih]

theorem sum_filterMap_nat {α β : Type} (values : List α) (f : α → Option β)
    (weight : β → Nat) :
    ((values.filterMap f).map weight).sum =
      (values.map fun value => ((f value).map weight).getD 0).sum := by
  induction values with
  | nil => rfl
  | cons value rest ih => cases h : f value <;> simp [h, ih]

def foldReferenceWeight (world : World) (weight : FoldMember → Nat) (reference : Option OutRef) : Nat :=
  ((reference.bind (foldMemberAt world)).map weight).getD 0

theorem fold_input_references {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (accepted : foldPrerequisite world u tx = none) :
    (tx.transaction.inputs.map (·.ref)).Perm
      ((u.filter fun p => inputsContainReference tx.transaction.inputs p.1).map
        (fun p => some p.1)) := by
  obtain ⟨observations, uniqueInputs, presence⟩ := foldPrerequisite_observations accepted
  have uniqueU := (rejectionObservation_world observations).2.1
  have present : ∀ input ∈ tx.transaction.inputs, inputPresent u.ledger input = true := by
    unfold inputPresenceRefusal at presence
    split at presence
    · contradiction
    next allPresent =>
      have h : tx.transaction.inputs.all (inputPresent u.ledger) = true := by simpa using allPresent
      exact List.all_eq_true.mp h
  have included : tx.transaction.inputs.map (·.ref) ⊆ u.map (fun p => some p.1) := by
    intro reference member
    obtain ⟨input, belongs, rfl⟩ := List.mem_map.mp member
    have found := present input belongs
    cases ref : input.ref with
    | none => simp [inputPresent, ref] at found
    | some value =>
      simp only [inputPresent, ref, EconomicUtxo.ledger, List.any_map,
        List.any_eq_true, Function.comp_def, decide_eq_true_eq] at found
      obtain ⟨entry, entryMem, same⟩ := found
      exact List.mem_map.mpr ⟨entry, entryMem, by simp [ref, same]⟩
  have uniqueOptions : (u.map fun p => some p.1).Nodup := by
    apply List.pairwise_map.mpr
    exact (List.pairwise_map.mp uniqueU).imp (fun different same => different (Option.some.inj same))
  have permutation := distinct_subset_filter_perm _ _ uniqueInputs uniqueOptions included
  have predicates : ∀ entry : OutRef × EconomicOutput,
      (tx.transaction.inputs.map (·.ref)).contains (some entry.1) =
        inputsContainReference tx.transaction.inputs entry.1 := by
    intro entry
    apply Bool.eq_iff_iff.mpr
    simp [inputsContainReference, List.contains_iff_mem, List.mem_map, List.any_eq_true]
  simpa only [List.filter_map, Function.comp_def, predicates] using permutation

/-- Sum the selected declaration weights once per observed spending reference.
The input list's order and its claimed lovelace do not change this census. -/
theorem fold_member_weight_sum {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (accepted : foldPrerequisite world u tx = none) (weight : FoldMember → Nat) :
    ((foldMembers world tx).map weight).sum =
      ((u.filter fun p => inputsContainReference tx.transaction.inputs p.1).map
        (fun p => foldReferenceWeight world weight (some p.1))).sum := by
  have sum := ((fold_input_references accepted).map (foldReferenceWeight world weight)).sum_nat
  unfold foldMembers
  rw [sum_filterMap_nat]
  simpa only [List.map_map, Function.comp_def] using sum

end Singular
