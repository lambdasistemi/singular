import Singular.Economics
import Singular.Lemmas

/-! Singular-tag supply counts both custody and pending termination outputs.
These are world laws; the existing registry-level laws remain unchanged. -/

namespace Singular.Statements

/-- Every admitted termination booking has exact declared contents, mints
its trie-ready tag with the request, and takes one genuine singular tag from
its key's active custody holding. -/
theorem termination_booking_has_exact_contents (registry : RegistryState) (b : TerminationBooking)
    (accepted : terminationBookingRefusal registry b = none) :
    b.request.registryId = registry.config.registryId ∧
    b.request.singularTags = [registry.config.singularTag b.request.key] ∧
    trieGet registry.trie b.request.key = .known .active ∧
    b.custodyInputs = terminationCustody registry b.request.key ∧
    b.custodyInputs.length = 1 ∧
    kindCount registry .active b.request.key = 1 ∧
    b.trieReadyTagsMinted = [b.request.trieReadyTag registry.config] ∧
    b.request.contents.applicationTags = [] ∧
    terminationExactContents registry.config b.request = true := by
  simp only [terminationBookingRefusal] at accepted
  repeat (split at accepted <;> try contradiction)
  rename_i shape amount singular trieReadyGuard custody inputs
  have singular' : b.request.registryId = registry.config.registryId ∧
      b.request.singularTags = [registry.config.singularTag b.request.key] := by simpa using singular
  have inputs' : b.custodyInputs = terminationCustody registry b.request.key ∧
      b.custodyInputs.length = 1 := by simpa using inputs
  have custody' : trieGet registry.trie b.request.key = .known .active ∧
      (terminationCustody registry b.request.key).isEmpty = false := by simpa using custody
  have shape' : terminationContentsShape registry.config b.request = true ∧
      terminationDeclaredLovelace b.request ≤ b.request.contents.lovelace := by simpa using shape
  have application' : b.request.contents.applicationTags = [] := by
    have h := shape'.1
    simp only [terminationContentsShape, decide_eq_true_eq] at h
    exact h.2.2.2.2
  have trieReady' : b.request.contents.trieReadyTags = [b.request.trieReadyTag registry.config] ∧
      b.trieReadyTagsMinted = [b.request.trieReadyTag registry.config] := by simpa using trieReadyGuard
  have value : b.request.contents.lovelace = terminationDeclaredLovelace b.request := by omega
  have count : kindCount registry .active b.request.key = 1 := by
    change (terminationCustody registry b.request.key).length = 1
    rw [← inputs'.1]
    exact inputs'.2
  exact ⟨singular'.1, singular'.2, custody'.1, inputs'.1, inputs'.2, count, trieReady'.2, application',
    by simp [terminationExactContents, shape'.1, singular'.1, singular'.2,
      value, trieReady'.1]⟩

/-- In every reachable world, the actual singular tags in custody and pending
termination outputs total one exactly for an active key, zero otherwise, and
never more than one. Each pending termination contributes exactly one such tag.
Registry-level consistency is not assumed of the world component. -/
theorem world_supply_sync (world : World) (reachable : WorldReachable world) (key : Key) :
    (worldSingularSupply world key = 1 ↔ trieGet world.registry.trie key = .known .active) ∧
    (worldSingularSupply world key = 0 ↔ trieGet world.registry.trie key ≠ .known .active) ∧
    worldSingularSupply world key ≤ 1 ∧
    carriedSingularCount world key = pendingTerminationCount world key := by
  have remaining_active_count : ∀ (held : List Holding) (removed key : Key),
      ((held.filter (fun h => !(h.key == removed && h.kind == .active))).filter
        (fun h => h.key == key && h.kind == .active)).length =
        if key = removed then 0 else (held.filter (fun h => h.key == key && h.kind == .active)).length := by
    intro held removed key
    induction held with
    | nil => simp
    | cons h tail ih =>
      by_cases hr : h.key = removed <;> by_cases hk : h.key = key <;>
        by_cases ha : h.kind = .active <;> by_cases he : key = removed <;>
        simp_all
  have invariant :
      WorldSupplyConsistent world ∧
      ∀ key, carriedSingularCount world key = pendingTerminationCount world key := by
    induction reachable with
    | initial registry reach =>
      obtain ⟨root, active, bound, rest⟩ := reachable_consistent registry reach
      constructor
      · intro key
        simp only [worldSingularSupply, carriedSingularCount, List.flatMap_nil, List.countP_nil,
          Nat.add_zero]
        by_cases h : trieGet registry.trie key = .known .active
        · simp [h, (active key).mpr h]
        · have hne : kindCount registry .active key ≠ 1 := fun one => h ((active key).mp one)
          have := bound key
          simp only [if_neg h]
          omega
      · intro key; simp [carriedSingularCount, pendingTerminationCount]
    | @booking before after reach transaction accepted ih =>
      unfold book at accepted
      split at accepted
      next reason => exact nomatch accepted
      next admitted =>
        split at accepted
        next duplicate => exact nomatch accepted
        next fresh => cases accepted; exact ih
    | @termination before after reach transaction accepted ih =>
      unfold bookTermination at accepted
      split at accepted
      next reason => exact nomatch accepted
      next admitted =>
        split at accepted
        next duplicate => exact nomatch accepted
        next fresh =>
          cases accepted
          obtain ⟨registry, tags, active, inputs, one, held, trieReadyMint, noApplication, exact⟩ :=
            termination_booking_has_exact_contents before.registry transaction admitted
          constructor
          · intro key
            have law := ih.1 key
            simp only [worldSingularSupply, kindCount]
            rw [remaining_active_count]
            by_cases same : key = transaction.request.key
            · subst key
              unfold worldSingularSupply at law
              rw [held] at law
              simpa [carriedSingularCount, tags, Nat.add_comm] using law
            · simpa [worldSingularSupply, carriedSingularCount, tags, kindCount,
                Config.singularTag, same, Ne.symm same] using law
          · intro key
            have count := ih.2 key
            by_cases same : key = transaction.request.key
            · simpa [carriedSingularCount, pendingTerminationCount, tags, Config.singularTag,
                same] using count
            · simpa [carriedSingularCount, pendingTerminationCount, tags, Config.singularTag,
                same, Ne.symm same] using count
  have law := invariant.1 key
  have count := invariant.2 key
  by_cases active : trieGet world.registry.trie key = .known .active <;> simp_all

/-- At most one pending termination per key, counting occurrences in the pool,
not merely distinct values. This follows from supply shared with custody. -/
theorem at_most_one_pending_termination (world : World) (reachable : WorldReachable world)
    (key : Key) : pendingTerminationCount world key ≤ 1 := by
  have supply := (world_supply_sync world reachable key).2.2.1
  have count := (world_supply_sync world reachable key).2.2.2
  unfold worldSingularSupply at supply
  omega

/-- Every pending termination carries exactly the genuine singular tag of its
own key and registry, whose leaf remains active. Its retained custody inputs
came from an actual accepted booking of a reachable earlier world. -/
theorem termination_request_carries_genuine_token (world : World)
    (reachable : WorldReachable world) (booking : TerminationBooking)
    (pending : booking ∈ world.terminations) :
    booking.request.registryId = world.registry.config.registryId ∧
    booking.request.singularTags = [world.registry.config.singularTag booking.request.key] ∧
    trieGet world.registry.trie booking.request.key = .known .active ∧
    terminationExactContents world.registry.config booking.request = true ∧
    ∃ before after : World, WorldReachable before ∧
      bookTermination before booking = .ok after ∧
      booking.custodyInputs = terminationCustody before.registry booking.request.key ∧
      booking.custodyInputs.length = 1 := by
  induction reachable with
  | initial registry reach => simp at pending
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh => cases accepted; exact ih pending
  | @termination before after reach transaction accepted ih =>
    have booked := accepted
    unfold bookTermination at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh =>
        cases accepted
        simp only [List.mem_cons] at pending
        rcases pending with same | old
        · subst booking
          obtain ⟨registry, tags, active, inputs, one, held, trieReadyMint, noApplication, exact⟩ :=
            termination_booking_has_exact_contents before.registry transaction admitted
          exact ⟨registry, tags, active, exact, before, _, reach, booked, inputs, one⟩
        · exact ih old

/-- A pending termination carries its own operation and nonce commitment,
and no application tag. Genuine singular-tag custody is proved above. -/
theorem booked_termination_tag_commits_to_own_operation (world : World)
    (reachable : WorldReachable world) (booking : TerminationBooking)
    (pending : booking ∈ world.terminations) :
    booking.request.contents.trieReadyTags =
      [world.registry.config.trieReadyTag
        (trieReadyTagAssetName booking.request.operation booking.request.nonce)] ∧
    booking.request.contents.applicationTags = [] := by
  have contents := (termination_request_carries_genuine_token world reachable booking pending).2.2.2.1
  simp only [terminationExactContents, Bool.and_eq_true, decide_eq_true_eq] at contents
  have shape := contents.1
  simp only [terminationContentsShape, decide_eq_true_eq] at shape
  exact ⟨contents.2.2.2.2, shape.2.2.2.2⟩

end Singular.Statements
