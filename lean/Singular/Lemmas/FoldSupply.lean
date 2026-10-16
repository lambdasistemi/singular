import Singular.Lemmas.FoldPending

/-! Supply preservation for the projected registry fold and its pending
custody. The invariants are derived from transitions, never admission guards. -/

namespace Singular

def RegistryActiveSupply (registry : RegistryState) : Prop :=
  ∀ key, kindCount registry .active key =
    if trieGet registry.trie key = .known .active then 1 else 0

theorem step_active_supply {s : RegistryState} {a : Request} {t : Result}
    (supply : RegistryActiveSupply s) (accepted : step s a = .ok t) :
    RegistryActiveSupply t.state := by
  obtain ⟨refusal, effect⟩ := step_eq_ok s a t accepted
  subst t
  obtain ⟨_, _, _, _, cases⟩ := (refusal_none_iff s a).mp refusal
  rcases cases with ⟨edge, leaf⟩ | ⟨edge, leaf, held⟩
  · intro key
    by_cases same : key = a.key
    · subst key
      have zero := supply a.key
      simp only [leaf, reduceCtorEq, if_false] at zero
      have count : kindCount (applyEdge s a).state .active a.key = kindCount s .active a.key + 1 := by
        simp [applyEdge, edge, kindCount]
      rw [count, zero]
      simp [applyEdge, edge, trieGet_set_eq]
    · simpa [applyEdge, edge, kindCount, trieGet_set_of_ne _ _ _ _ same,
        same, Ne.symm same] using supply key
  · intro key
    by_cases same : key = a.key
    · subst key
      simpa [applyEdge, edge, kindCount, trieGet_set_eq] using
        countHeld_filter_active_zero s.held a.key
    · have count := countHeld_filter_active_out s.held a.key .active key same
      have count' : kindCount (applyEdge s a).state .active key = kindCount s .active key := by
        simpa only [kindCount, applyEdge, edge] using count
      rw [count']
      simpa only [applyEdge, edge, trieGet_set_of_ne _ _ _ _ same] using supply key

theorem foldActions_active_supply {s : RegistryState} {batch : List Request} {result : Result}
    (supply : RegistryActiveSupply s) (accepted : foldActions s batch = .ok result) :
    RegistryActiveSupply result.state := by
  induction batch generalizing s result with
  | nil => simp [foldActions] at accepted; subst result; exact supply
  | cons a rest ih =>
    cases first : step s a with
    | error why => simp [foldActions, first, bind, Except.bind] at accepted
    | ok next =>
      cases later : foldActions next.state rest with
      | error why => simp [foldActions, first, later, bind, Except.bind] at accepted
      | ok last =>
        simp [foldActions, first, later, bind, Except.bind, pure, Except.pure] at accepted
        subst result
        exact ih (result := last) (step_active_supply supply first) later

theorem foldActions_preserves_active {s : RegistryState} {batch : List Request} {result : Result}
    (key : Key) (active : trieGet s.trie key = .known .active)
    (unspent : ∀ r ∈ batch, r.edge = .updateTerminal → r.key ≠ key)
    (accepted : foldActions s batch = .ok result) :
    trieGet result.state.trie key = .known .active := by
  induction batch generalizing s result with
  | nil => simp [foldActions] at accepted; subst result; exact active
  | cons a rest ih =>
    cases first : step s a with
    | error why => simp [foldActions, first, bind, Except.bind] at accepted
    | ok next =>
      cases later : foldActions next.state rest with
      | error why => simp [foldActions, first, later, bind, Except.bind] at accepted
      | ok last =>
        simp [foldActions, first, later, bind, Except.bind, pure, Except.pure] at accepted
        subst result
        have nextActive : trieGet next.state.trie key = .known .active := by
          obtain ⟨refusal, effect⟩ := step_eq_ok s a next first
          obtain ⟨_, _, _, _, cases⟩ := (refusal_none_iff s a).mp refusal
          rcases cases with ⟨edge, leaf⟩ | ⟨edge, leaf, held⟩
          · have different : key ≠ a.key := by intro same; simpa [← same, active] using leaf
            simpa [effect, applyEdge, edge, trieGet_set_of_ne _ _ _ _ different] using active
          · have different := (unspent a (by simp) edge).symm
            simpa [effect, applyEdge, edge, trieGet_set_of_ne _ _ _ _ different] using active
        exact ih (result := last) nextActive (fun r member => unspent r (by simp [member])) later

theorem pending_custody_counts (c : Config) (bookings : List TerminationBooking)
    (shape : ∀ b ∈ bookings, b.request.singularTags = [c.singularTag b.request.key] ∧
      b.custodyInputs.length = 1 ∧
      ∀ h ∈ b.custodyInputs, h.key = b.request.key ∧ h.kind = .active) (key : Key) :
    ((bookings.flatMap (·.custodyInputs)).filter
      (fun h => h.key == key && h.kind == .active)).length =
      (bookings.filter (fun b => b.request.key == key)).length ∧
    (bookings.flatMap (fun b => b.request.singularTags)).countP
      (fun tag => decide (tag = c.singularTag key)) =
      (bookings.filter (fun b => b.request.key == key)).length := by
  induction bookings with
  | nil => simp
  | cons b rest ih =>
    obtain ⟨tags, one, shapeB⟩ := shape b (by simp)
    obtain ⟨holding, custody⟩ := List.length_eq_one_iff.mp one
    obtain ⟨heldKey, heldKind⟩ := shapeB holding (by simp [custody])
    obtain ⟨ihHeld, ihTags⟩ := ih (fun b member => shape b (by simp [member]))
    by_cases same : b.request.key = key <;>
      simp [List.flatMap_cons, List.filter_append, custody, heldKey, heldKind, tags,
        Config.singularTag, same, ihHeld]
    all_goals exact ihTags

theorem members_equal_of_length_le_one {α : Type} {xs : List α}
    (bound : xs.length ≤ 1) {a b : α} (ha : a ∈ xs) (hb : b ∈ xs) : a = b := by
  cases xs with
  | nil => simp at ha
  | cons x rest =>
    cases rest with
    | nil => simpa using (List.mem_singleton.mp ha).trans (List.mem_singleton.mp hb).symm
    | cons y tail => simp at bound

theorem fold_remaining_not_selected {world : World} {tx : EconomicTransaction}
    (bound : ∀ key, pendingTerminationCount world key ≤ 1)
    {b : TerminationBooking} (remaining : b ∈ foldRemainingTerminations world tx) :
    ∀ r ∈ (foldMembers world tx).map (foldLegacyRequest world.registry.config),
      r.edge = .updateTerminal → r.key ≠ b.request.key := by
  intro r member edge
  obtain ⟨selected, selectedMem, rfl⟩ := List.mem_map.mp member
  cases selected with
  | registration registration => simp [foldLegacyRequest] at edge
  | termination termination =>
    obtain ⟨pending, spent⟩ := foldMembers_termination selectedMem
    intro same
    change termination.request.key = b.request.key at same
    have equal : termination = b := members_equal_of_length_le_one (bound b.request.key)
      (List.mem_filter.mpr ⟨pending, by simpa using same⟩)
      (List.mem_filter.mpr ⟨(List.mem_filter.mp remaining).1, by simp⟩)
    subst termination
    have notSpent := (List.mem_filter.mp remaining).2
    simp [spent] at notSpent

theorem pending_active_of_supply {world : World} (supply : WorldSupplyConsistent world)
    (counts : ∀ key, carriedSingularCount world key = pendingTerminationCount world key)
    {b : TerminationBooking} (pending : b ∈ world.terminations) :
    trieGet world.registry.trie b.request.key = .known .active := by
  have positive : 0 < pendingTerminationCount world b.request.key :=
    List.length_pos_iff_exists_mem.mpr ⟨b, List.mem_filter.mpr ⟨pending, by simp⟩⟩
  have law := supply b.request.key
  unfold worldSingularSupply at law
  rw [counts] at law
  split at law
  · assumption
  · omega

theorem remaining_active_after_fold {world : World} {tx : EconomicTransaction} {result : Result}
    (supply : WorldSupplyConsistent world)
    (counts : ∀ key, carriedSingularCount world key = pendingTerminationCount world key)
    (bound : ∀ key, pendingTerminationCount world key ≤ 1)
    (registry : foldBatch (foldProjectedRegistry world)
      ((foldMembers world tx).map (foldLegacyRequest world.registry.config)) = .ok result)
    {b : TerminationBooking} (remaining : b ∈ foldRemainingTerminations world tx) :
    trieGet result.state.trie b.request.key = .known .active :=
  foldActions_preserves_active (s := foldProjectedRegistry world) b.request.key
    (pending_active_of_supply supply counts (List.mem_filter.mp remaining).1)
    (fold_remaining_not_selected bound remaining) (foldBatch_inv _ _ _ registry).2

theorem fold_effect_active_count (world : World) (tx : EconomicTransaction)
    (result : Result) (key : Key) :
    kindCount (foldRegistryEffect world tx result) .active key =
      if (foldRemainingTerminations world tx).any (fun b => b.request.key == key) then 0
      else kindCount result.state .active key := by
  unfold kindCount foldRegistryEffect
  by_cases present : (foldRemainingTerminations world tx).any (fun b => b.request.key == key) = true
  · rw [if_pos present]
    have empty := filter_filter_none result.state.held
      (fun h => !(h.kind == .active && (foldRemainingTerminations world tx).any
        (fun b => b.request.key == h.key)))
      (fun h => h.key == key && h.kind == .active) (by
        intro h selected
        have both : h.key = key ∧ h.kind = .active := by simpa using selected
        simp [both.1, both.2, present])
    rw [empty]; rfl
  · rw [if_neg present]
    have keep := filter_filter_congr result.state.held
      (fun h => !(h.kind == .active && (foldRemainingTerminations world tx).any
        (fun b => b.request.key == h.key)))
      (fun h => h.key == key && h.kind == .active) (by
        intro h selected
        have both : h.key = key ∧ h.kind = .active := by simpa using selected
        simp [both.1, both.2, present])
    rw [keep]

theorem fold_preserves_world_supply {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (reachable : WorldReachable world)
    (supply : WorldSupplyConsistent world)
    (counts : ∀ key, carriedSingularCount world key = pendingTerminationCount world key)
    (accepted : foldAccepted world u tx = .ok after) :
    WorldSupplyConsistent after ∧
      ∀ key, carriedSingularCount after key = pendingTerminationCount after key := by
  have shape := reachable_pending_custody_shape world reachable
  have afterShape := reachable_pending_custody_shape after (.fold reachable u tx accepted)
  have countsAfter : ∀ key, carriedSingularCount after key = pendingTerminationCount after key := by
    intro key
    exact (pending_custody_counts after.registry.config after.terminations afterShape key).2
  refine ⟨?_, countsAfter⟩
  have bound : ∀ key, pendingTerminationCount world key ≤ 1 := by
    intro key
    have law := supply key
    unfold worldSingularSupply at law
    rw [counts] at law
    split at law <;> omega
  obtain ⟨_, result, registry, _, effect⟩ := foldAccepted_checks accepted
  have projected : RegistryActiveSupply (foldProjectedRegistry world) := by
    intro key
    have restored := (pending_custody_counts world.registry.config world.terminations shape key).1
    have law := supply key
    unfold worldSingularSupply at law
    rw [counts] at law
    simpa [kindCount, foldProjectedRegistry, List.filter_append, restored,
      pendingTerminationCount] using law
  have finalSupply := foldActions_active_supply projected (foldBatch_inv _ _ _ registry).2
  intro key
  have remainingBound : pendingTerminationCount after key ≤ 1 := by
    have le : pendingTerminationCount after key ≤ pendingTerminationCount world key := by
      unfold pendingTerminationCount
      rw [(foldAccepted_pending accepted).2]
      exact (List.Sublist.filter _ (List.filter_sublist)).length_le
    exact Nat.le_trans le (bound key)
  have afterCount := countsAfter key
  have afterRegistry : after.registry = foldRegistryEffect world tx result := by rw [effect]; rfl
  unfold worldSingularSupply
  rw [afterCount, afterRegistry, fold_effect_active_count]
  change (if (foldRemainingTerminations world tx).any (fun b => b.request.key == key) then 0
      else kindCount result.state .active key) + pendingTerminationCount after key =
    if trieGet result.state.trie key = .known .active then 1 else 0
  by_cases present : (foldRemainingTerminations world tx).any (fun b => b.request.key == key) = true
  · obtain ⟨b, member, same⟩ := List.any_eq_true.mp present
    have sameKey : b.request.key = key := by simpa using same
    have active := remaining_active_after_fold supply counts bound registry member
    rw [sameKey] at active
    have positive : 0 < pendingTerminationCount after key := by
      apply List.length_pos_iff_exists_mem.mpr
      refine ⟨b, List.mem_filter.mpr ⟨?_, same⟩⟩
      rw [(foldAccepted_pending accepted).2]
      exact member
    have one : pendingTerminationCount after key = 1 := by omega
    simp [present, active, one]
  · have empty : pendingTerminationCount after key = 0 := by
      unfold pendingTerminationCount
      rw [(foldAccepted_pending accepted).2]
      apply List.length_eq_zero_iff.mpr
      apply List.filter_eq_nil_iff.mpr
      intro b member
      have absent : b.request.key ≠ key := by
        intro same
        exact present (List.any_eq_true.mpr ⟨b, member, by simp [same]⟩)
      simpa using absent
    simp only [present, if_false, empty, Nat.add_zero]
    exact finalSupply key

end Singular
