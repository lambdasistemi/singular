import NoPin.ApplicationRequests.HistoryFixtures
import NoPin.ApplicationRequests.HistoryOrigins

namespace NoPin.ApplicationRequests.HistoryEvidence
open Singular Fixtures
set_option maxRecDepth 32768
set_option maxHeartbeats 8000000
local instance (priority := 10000) {α : Type} [DecidableEq α] (a : α) (xs : List α) :
    Decidable (a ∈ xs) := memberDecidable a xs

theorem same_seed_two_policies : first.seed = other.seed ∧ first.identity.name = other.identity.name ∧
    first.identity.policy ≠ other.identity.policy ∧
    registeredBoth.unspent = otherRegisteredBoth.unspent ∧
    liveActiveCount hash code first.identity 7 registeredBoth.unspent = 1 ∧
    liveActiveCount hash code other.identity 7 registeredBoth.unspent = 1 := by decide
theorem pending_token_counted : SupplyAt hash code booked registerFirst.after 7 := by unfold SupplyAt; decide
theorem terminal_token_absent : SupplyAt hash code terminated terminate.after 7 := by unfold SupplyAt; decide
theorem remint_refused : fold .none hash code commit release remint = false := by decide
theorem remint_single_guard : fold (.flip .changeLeaf) hash code commit release remint = true := by decide
theorem duplicate_refused : fold .none hash code commit release duplicate = false := by decide
theorem duplicate_single_guard : fold (.flip .foldWholePolicy) hash code commit release duplicate = true := by decide
theorem foreign_burn_refused : fold .none hash code commit release foreignBurn = false := by decide
theorem foreign_burn_single_guard : fold (.flip .foldWholePolicy) hash code commit release foreignBurn = true := by decide

abbrev supply_premise := HistoryPremises hash code commit release booked registerFirst.after 8
abbrev supply_claim := SupplyAt hash code booked registerFirst.after 8
theorem supply_antecedent : supply_premise := active_history_premise
theorem supply_candidate : supply_claim := by unfold supply_claim SupplyAt; decide
abbrev one_live_premise := supply_premise
abbrev one_live_claim := liveActiveCount hash code first.identity 8 booked.unspent ≤ 1
theorem one_live_antecedent : one_live_premise := active_history_premise
theorem one_live_candidate : one_live_claim := by decide

abbrev burn_premise :=
  HistoryTransaction hash code commit release booked terminated terminate.assets (some terminate) ∧
  HistoryPremises hash code commit release booked registerFirst.after 7 ∧
  FiniteEncoding code (terminated.domain ++ [.active registerFirst.after.identity 7]) ∧
  FiniteCollisionFree hash code (terminated.domain ++ [.active registerFirst.after.identity 7]) ∧
  NoPin.mintQty terminate.assets (activeAsset hash code registerFirst.after.identity 7) < 0
abbrev burn_claim := ∃ o, some terminate = some o ∧ registerFirst.after.identity = o.before.identity ∧
  (∃ reference, Change.terminate reference 7 ∈ o.changes) ∧ trieGet o.after.trie 7 = .known .terminal
theorem burn_antecedent : burn_premise := by
  refine ⟨⟨booked_reachable, rfl, termination_history_premise⟩,
    ⟨booked_reachable, by decide, ?_, ?_⟩, ?_, ?_, by decide⟩
  all_goals first | (unfold FiniteEncoding; decide) | (unfold FiniteCollisionFree; decide)
theorem burn_candidate : burn_claim := ⟨terminate, rfl, rfl, ⟨pending.reference, by decide⟩, by decide⟩

abbrev permanence_premise :=
  HistoryFoldPremises hash code commit release terminated laterWorld later ∧
  HistoryPremises hash code commit release terminated terminate.after 7 ∧
  FiniteEncoding code (laterWorld.domain ++ [.active terminate.after.identity 7]) ∧
  FiniteCollisionFree hash code (laterWorld.domain ++ [.active terminate.after.identity 7]) ∧
  trieGet terminate.after.trie 7 = .known .terminal
abbrev permanence_claim := NoPin.mintQty later.assets (activeAsset hash code terminate.after.identity 7) ≤ 0 ∧
  ∀ successor ∈ laterWorld.registries, successor.identity = terminate.after.identity →
    trieGet successor.trie 7 = .known .terminal
theorem permanence_antecedent : permanence_premise := by
  refine ⟨later_history_premise, terminal_history_premise, ?_, ?_, by decide⟩
  · unfold FiniteEncoding; decide
  · unfold FiniteCollisionFree; decide
theorem permanence_candidate : permanence_claim := by
  constructor
  · decide
  · decide

end NoPin.ApplicationRequests.HistoryEvidence
