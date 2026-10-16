import Singular.Lemmas.FoldSums

/-! Exact observed partitions used to derive conservation of the declared
allocations. These are consequences of routing, not extra admission guards. -/

namespace Singular

def foldStateLovelace (outputs : List EconomicOutput) : Nat :=
  ((outputs.filter fun o => o.output.stateTokens > 0).map (·.output.lovelace)).sum

def foldCarrierLovelace (outputs : List EconomicOutput) : Nat :=
  ((outputs.filter fun o => !o.singularTags.isEmpty).map (·.output.lovelace)).sum

set_option maxRecDepth 4096 in
theorem foldRouting_partitions {world : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} {result : Result}
    (accepted : foldRoutingRefusal world u tx result = none) :
    foldStateLovelace (economicSpent u tx) = foldStateLovelace tx.outputs ∧
    (∀ member ∈ foldMembers world tx, foldCarrierRefusal world.registry.config tx.outputs member = none) ∧
    (tx.outputs.flatMap (·.singularTags)).Perm (foldCarrierTags world.registry.config (foldMembers world tx)) ∧
    (∀ o ∈ tx.outputs, o.contents.trieReadyTags = [] ∧ o.contents.applicationTags = []) ∧
    (∀ o ∈ tx.outputs, 0 < o.output.stateTokens → o.singularTags = []) := by
  unfold foldRoutingRefusal at accepted
  simp only [bind, pure, Option.bind] at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all [foldStateLovelace, requestTagsBurned,
    foldStateShape, List.all_eq_true, ← Option.eq_none_iff_forall_ne_some]
  all_goals
    intro output member state
    have selected : output ∈ tx.outputs.filter (fun o => decide (0 < o.output.stateTokens)) :=
      List.mem_filter.mpr ⟨member, by simpa using state⟩
    simp_all

set_option maxRecDepth 2048 in
theorem foldCarrier_checked {config : Config} {outputs : List EconomicOutput}
    {booking : RegistrationBooking}
    (accepted : foldCarrierRefusal config outputs (.registration booking) = none) :
    ∃ output,
      outputs.filter (fun o => o.singularTags.contains (config.singularTag booking.request.key)) = [output] ∧
      output.output.lovelace = booking.request.carrierAda ∧
      output.singularTags = [config.singularTag booking.request.key] ∧ output.output.stateTokens = 0 := by
  unfold foldCarrierRefusal at accepted
  simp only [bind, pure, Option.bind] at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all [foldBareValue] <;> grind

end Singular
