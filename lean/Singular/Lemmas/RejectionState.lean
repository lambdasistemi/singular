import Singular.Lemmas.EconomicRejection

namespace Singular

theorem rejectionState_facts {world : World} {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionStateRefusal world u r = none) :
    inputsContainReference r.transaction.transaction.referenceInputs r.stateReference = true ∧
    ∃ output, economicLookup u r.stateReference = some output ∧
      output.output.stateTokens = 1 ∧ output.output.role = .state ∧
      output.output.stateToken = some world.registry.config.stateToken ∧
      output.output.datum = .inline ∧
      output.output.config = some world.registry.config ∧
      world.registry.config.root = rootOf world.registry.trie := by
  have identity (a b : TokenId) (policy : a.policy = b.policy) (name : a.name = b.name) : a = b := by
    cases a; cases b; simp_all
  unfold rejectionStateRefusal at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all [Config.stateToken]
  all_goals apply identity <;> assumption

theorem economicLookup_mem {u : EconomicUtxo} {ref : OutRef} {output : EconomicOutput}
    (lookup : economicLookup u ref = some output) : (ref, output) ∈ u := by
  unfold economicLookup at lookup
  cases found : u.find? (fun entry => entry.1 == ref) with
  | none => simp [found] at lookup
  | some entry =>
    have predicate := List.find?_some found
    have present := List.mem_of_find?_eq_some found
    simp only [found, Option.map_some, Option.some.injEq] at lookup
    rcases entry with ⟨other, value⟩
    have same : other = ref := by simpa using predicate
    subst other
    have valueEq : value = output := lookup
    subst value
    exact present

theorem rejection_state_not_spent {world after : World} {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionAccepted world u r = .ok after) :
    inputsContainReference r.transaction.transaction.inputs r.stateReference = false := by
  have checks := rejectionAccepted_checks accepted
  have referenced := (rejectionState_facts checks.2.1).1
  have noOverlap := (rejectionInputs_facts checks.1).1
  exact Bool.eq_false_iff.mpr fun spent => noOverlap ⟨spent, referenced⟩

end Singular
