import Singular.Economics.Fold
import Singular.Lemmas.Batch
import Singular.Lemmas.EconomicRejection

/-! Inversions of observed fold admission and the exact registry projection.
No legacy approval or timing admission is asserted to be economic authority. -/

namespace Singular

/-- An accepted fold has passed economic observations, applied the unchanged
registry batch to its explicit projection, and passed exact output routing. -/
theorem foldAccepted_checks {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : foldAccepted world u tx = .ok after) :
    foldPrerequisite world u tx = none ∧ ∃ result,
      foldBatch (foldProjectedRegistry world)
        ((foldMembers world tx).map (foldLegacyRequest world.registry.config)) = .ok result ∧
      foldRoutingRefusal world u tx result = none ∧ after = foldEffect world tx result := by
  unfold foldAccepted at accepted
  split at accepted
  · contradiction
  next prerequisite =>
    split at accepted
    · contradiction
    next result registry =>
      split at accepted
      · contradiction
      next routing =>
        cases accepted
        exact ⟨prerequisite, result, registry, routing, rfl⟩

/-- The registry's own result supplies every component, with only unconsumed
pending custody projected out. The adapter's syntactic approval has no
application authorization meaning; economic request checks are the authority. -/
theorem economic_fold_registry_correspondence {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : foldAccepted world u tx = .ok after) :
    ∃ result, foldBatch (foldProjectedRegistry world)
        ((foldMembers world tx).map (foldLegacyRequest world.registry.config)) = .ok result ∧
      after.registry = foldRegistryEffect world tx result := by
  obtain ⟨_, result, registry, _, effect⟩ := foldAccepted_checks accepted
  exact ⟨result, registry, by rw [effect]; rfl⟩

theorem foldAccepted_config {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : foldAccepted world u tx = .ok after) :
    after.registry.config = { world.registry.config with root := after.registry.config.root } := by
  obtain ⟨result, registry, effect⟩ := economic_fold_registry_correspondence accepted
  have config := foldActions_config_root _ _ _ (foldBatch_inv _ _ _ registry).2
  simpa [effect, foldRegistryEffect, foldProjectedRegistry] using config

theorem foldAccepted_pending {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : foldAccepted world u tx = .ok after) :
    after.pending = world.pending.filter (fun b =>
      !inputsContainReference tx.transaction.inputs b.request.reference) ∧
    after.terminations = foldRemainingTerminations world tx := by
  obtain ⟨_, result, _, _, effect⟩ := foldAccepted_checks accepted
  rw [effect]
  exact ⟨rfl, rfl⟩

theorem foldMembers_termination {world : World} {tx : EconomicTransaction}
    {b : TerminationBooking} (member : FoldMember.termination b ∈ foldMembers world tx) :
    b ∈ world.terminations ∧ inputsContainReference tx.transaction.inputs b.request.reference = true := by
  obtain ⟨input, inputMem, chosen⟩ := List.mem_filterMap.mp member
  cases reference : input.ref with
  | none => simp [reference] at chosen
  | some ref =>
    simp only [reference, Option.bind_some] at chosen
    unfold foldMemberAt at chosen
    cases registration : world.pending.find? (fun b => b.request.reference == ref) with
    | some r => simp [registration] at chosen
    | none =>
      simp only [registration] at chosen
      cases termination : world.terminations.find? (fun b => b.request.reference == ref) with
      | none => simp [termination] at chosen
      | some found =>
        simp only [termination, Option.map_some, Option.some.injEq,
          FoldMember.termination.injEq] at chosen
        subst found
        have same : b.request.reference = ref := by simpa using List.find?_some termination
        refine ⟨List.mem_of_find?_eq_some termination, ?_⟩
        apply List.any_eq_true.mpr
        exact ⟨input, inputMem, by simp [reference, same]⟩

end Singular
