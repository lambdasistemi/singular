import Singular.Lemmas.EconomicRejection
import Singular.Statements.Termination

/-! Protection of pending registrations and terminations from atomic rejection.
The termination ground is ruled out by actual carried supply, not just its
aggregate rejection fallback. -/

namespace Singular.Statements

/-- Any reachable pending registration whose transition remains possible is
absent from every accepted rejection before expiry. Either offered ground would
refuse the entire transaction; the shared interval belongs to that transaction. -/
theorem live_request_not_rejected (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (r : Rejection)
    (accepted : rejectionAccepted world u r = .ok after)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (validity : r.transaction.transaction.validity = some interval)
    (live : (transition .insertActive (trieGet world.registry.trie booking.request.key)).isSome = true)
    (beforeExpiry : interval.lower < booking.request.submittedAt + world.registry.config.processTime +
      world.registry.config.retractTime) :
    ∀ ground, (booking.request.reference, ground) ∉ r.members := by
  have checks := rejectionAccepted_checks accepted
  have observations := (rejectionObservation_world checks.2.2.1).1
  have registrations := List.all_eq_true.mp (Bool.and_eq_true_iff.mp observations).1
  obtain ⟨actualInterval, binding, nonempty, members, inputs, grounds, rest⟩ := checks.2.2.2
  have sameInterval : actualInterval = interval := by simpa [validity] using binding.symm
  subst actualInterval
  intro ground member
  have admitted := grounds (booking.request.reference, ground) member
  cases found : world.pending.find? (fun b => b.request.reference == booking.request.reference) with
  | none =>
    have impossible := List.find?_eq_none.mp found booking pending
    simp at impossible
  | some actual =>
    have sameReference : actual.request.reference = booking.request.reference := by
      simpa using List.find?_some found
    have same := observed_registration_unique
      (registrations actual (List.mem_of_find?_eq_some found))
      (registrations booking pending) sameReference
    simp only [rejectionMemberRefusal, found] at admitted
    rw [same] at admitted
    cases ground with
    | mismatch leaf =>
      by_cases current : leaf = trieGet world.registry.trie booking.request.key
      · simp [registrationRejectionGround, current, live] at admitted
      · simp [registrationRejectionGround, current] at admitted
    | expired => simp [registrationRejectionGround, beforeExpiry] at admitted

/-- A genuine pending termination contributes positive carried singular supply.
The reachable-world supply law forces its leaf active, so mismatch is impossible;
there is no expiry rule. Neither ground can occur in an accepted rejection. -/
theorem termination_unrejectable (world : World)
    (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations) :
    trieGet world.registry.trie booking.request.key = .known .active ∧
    ∀ ground, terminationRejectionGround world booking.request ground ≠ none ∧
      ∀ (u : EconomicUtxo) (r : Rejection) (after : World),
        rejectionAccepted world u r = .ok after →
        (booking.request.reference, ground) ∉ r.members := by
  have genuine := (termination_request_carries_genuine_token world reachable booking pending).2.1
  have positive : 0 < carriedSingularCount world booking.request.key := by
    apply List.countP_pos_iff.mpr
    refine ⟨world.registry.config.singularTag booking.request.key, ?_, by simp⟩
    exact List.mem_flatMap.mpr ⟨booking, pending, by simp [genuine]⟩
  have law := world_supply_sync world reachable booking.request.key
  have one : worldSingularSupply world booking.request.key = 1 := by
    have bound := law.2.2.1
    unfold worldSingularSupply at bound ⊢
    omega
  have active := law.1.mp one
  refine ⟨active, ?_⟩
  intro ground
  constructor
  · cases ground with
    | expired => simp [terminationRejectionGround]
    | mismatch leaf =>
      by_cases current : leaf = .known .active
      · simp [terminationRejectionGround, active, current, transition]
      · simp [terminationRejectionGround, active, current]
  · intro u r after accepted member
    have checks := rejectionAccepted_checks accepted
    have observations := (rejectionObservation_world checks.2.2.1).1
    have registrations := List.all_eq_true.mp (Bool.and_eq_true_iff.mp observations).1
    have termination := List.all_eq_true.mp (Bool.and_eq_true_iff.mp observations).2 booking pending
    obtain ⟨interval, binding, nonempty, members, inputs, grounds, rest⟩ := checks.2.2.2
    have admitted := grounds (booking.request.reference, ground) member
    cases found : world.pending.find? (fun b => b.request.reference == booking.request.reference) with
    | some actual =>
      have same : actual.request.reference = booking.request.reference := by
        simpa using List.find?_some found
      exact observed_request_kinds_disjoint
        (registrations actual (List.mem_of_find?_eq_some found)) termination same
    | none =>
      simp only [rejectionMemberRefusal, found] at admitted
      repeat (split at admitted <;> try contradiction)

end Singular.Statements
