import Singular.Lemmas.FoldInputValue
import Singular.Lemmas.FoldCarrierValue

/-! Gross reward is derived by cancelling exact state and carrier allocations
from observed conservation. No reward equation is an admission premise. -/

namespace Singular

instance : LawfulBEq TokenKind where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq TxOutput where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqTxOutput.beq _ _ = true at h
    simpa only [instBEqTxOutput.beq, Bool.and_eq_true, beq_iff_eq, TxOutput.mk.injEq] using h
  rfl {a} := by
    cases a
    change instBEqTxOutput.beq _ _ = true
    simp only [instBEqTxOutput.beq, beq_self_eq_true, Bool.and_self]

theorem sum_three_parts {α : Type} (values : List α) (whole a b c : α → Nat)
    (parts : ∀ value ∈ values, whole value = a value + b value + c value) :
    (values.map whole).sum = (values.map a).sum + (values.map b).sum + (values.map c).sum := by
  induction values with
  | nil => simp
  | cons value rest ih =>
    have first := parts value (by simp)
    have tail := ih (fun x member => parts x (by simp [member]))
    simp only [List.map_cons, List.sum_cons, first, tail]
    omega

theorem fold_input_lovelace {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (reachable : WorldReachable world) (accepted : foldPrerequisite world u tx = none) :
    outputLovelace (spentOutputs u.ledger tx.transaction) =
      foldStateLovelace (economicSpent u tx) + foldOrdinaryLovelace (economicSpent u tx) +
      ((foldMembers world tx).map FoldMember.held).sum := by
  rw [fold_member_weight_sum accepted]
  have reorder (p q : Prop) [Decidable p] [Decidable q] (n : Nat) :
      (if p then if q then n else 0 else 0) = (if q ∧ p then n else 0) := by
    by_cases hp : p <;> by_cases hq : q <;> simp [hp, hq]
  have total := sum_three_parts (u.filter fun p => inputsContainReference tx.transaction.inputs p.1)
    (fun p => p.2.output.lovelace)
    (fun p => if 0 < p.2.output.stateTokens then p.2.output.lovelace else 0)
    (fun p => if foldOrdinary p.2 then p.2.output.lovelace else 0)
    (fun p => foldReferenceWeight world FoldMember.held (some p.1))
    (fun p member => fold_input_partition reachable accepted p
      (List.mem_filter.mp member).1 (List.mem_filter.mp member).2)
  simpa [outputLovelace, spentOutputs, EconomicUtxo.ledger, economicSpent,
    foldStateLovelace, foldOrdinaryLovelace, sum_filter_nat, List.filter_map,
    List.map_map, Function.comp_def, reorder] using total

theorem fold_declared_allocation {world : World} {tx : EconomicTransaction}
    (reachable : WorldReachable world) :
    ((foldMembers world tx).map FoldMember.held).sum =
      (foldObligations (foldMembers world tx)).donation +
      (foldObligations (foldMembers world tx)).tips +
      (foldObligations (foldMembers world tx)).carriers :=
  sum_three_parts _ _ _ _ _ (fold_members_allocate reachable)

set_option maxRecDepth 2048 in
theorem fold_output_observations {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (accepted : foldPrerequisite world u tx = none) :
    tx.outputs.map (·.output) = tx.transaction.outputs := by
  have observations := (foldPrerequisite_observations accepted).1
  unfold economicObservationRefusal at observations
  repeat (split at observations <;> try contradiction)
  all_goals simp_all

theorem fold_output_partition {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    {result : Result} (accepted : foldRoutingRefusal world u tx result = none)
    (output : EconomicOutput) (member : output ∈ tx.outputs) :
    output.output.lovelace =
      (if 0 < output.output.stateTokens then output.output.lovelace else 0) +
      (if foldOrdinary output then output.output.lovelace else 0) +
      (if !output.singularTags.isEmpty then output.output.lovelace else 0) := by
  have parts := foldRouting_partitions accepted
  have tags := parts.2.2.2.1 output member
  by_cases state : 0 < output.output.stateTokens
  · have singular := parts.2.2.2.2 output member state
    have ordinary : foldOrdinary output = false := by
      apply Bool.eq_false_iff.mpr
      intro yes
      have := foldOrdinary_state yes
      omega
    simp [state, singular, ordinary]
  · have zero : output.output.stateTokens = 0 := by omega
    cases singular : output.singularTags <;>
      simp [zero, foldOrdinary, tags.1, tags.2, singular]

theorem fold_output_lovelace {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    {result : Result} (prerequisite : foldPrerequisite world u tx = none)
    (accepted : foldRoutingRefusal world u tx result = none) :
    outputLovelace tx.transaction.outputs = foldStateLovelace tx.outputs +
      foldOrdinaryLovelace tx.outputs + foldCarrierLovelace tx.outputs := by
  rw [← fold_output_observations prerequisite]
  have total := sum_three_parts tx.outputs (fun o => o.output.lovelace)
    (fun o => if 0 < o.output.stateTokens then o.output.lovelace else 0)
    (fun o => if foldOrdinary o then o.output.lovelace else 0)
    (fun o => if !o.singularTags.isEmpty then o.output.lovelace else 0)
    (fold_output_partition accepted)
  simpa [outputLovelace, foldStateLovelace, foldOrdinaryLovelace, foldCarrierLovelace,
    sum_filter_nat, List.map_map, Function.comp_def] using total

theorem fold_gross_reward {world after : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (reachable : WorldReachable world) (accepted : foldAccepted world u tx = .ok after) :
    foldOrdinaryLovelace tx.outputs + tx.transaction.fee =
      foldOrdinaryLovelace (economicSpent u tx) + (foldObligations (foldMembers world tx)).tips := by
  obtain ⟨prerequisite, result, registry, routing, effect⟩ := foldAccepted_checks accepted
  have accounting := foldRouting_accounting routing
  have partitions := foldRouting_partitions routing
  have carriers := fold_carrier_observed_sum world.registry.config tx.outputs
    (foldMembers world tx) partitions.2.1 partitions.2.2.1
  have balance : outputLovelace (spentOutputs u.ledger tx.transaction) =
      outputLovelace tx.transaction.outputs + tx.transaction.donation + tx.transaction.fee := by
    have balanced := accounting.2.2.1
    simp only [Singular.balanced, Bool.and_eq_true, beq_iff_eq] at balanced
    exact balanced.1.1
  rw [fold_input_lovelace reachable prerequisite, fold_declared_allocation reachable,
    fold_output_lovelace prerequisite routing, carriers, accounting.1, partitions.1] at balance
  omega

end Singular
