import Singular.Lemmas.FoldWitnessTransaction

/-! The constructed termination uses the unchanged registry fold. -/

namespace Singular

theorem terminationWitness_registry (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations) :
    foldBatch (foldProjectedRegistry world)
      [foldLegacyRequest world.registry.config (.termination booking)] =
      .ok (terminationWitnessResult world booking) := by
  have active := (Statements.termination_request_carries_genuine_token world reachable booking pending).2.2.1
  have shape := reachable_pending_custody_shape world reachable booking pending
  obtain ⟨holding, singleton⟩ := List.length_eq_one_iff.mp shape.2.1
  have holdingShape := shape.2.2 holding (by simp [singleton])
  have custody : (foldProjectedRegistry world).held.any
      (fun h => h.key == booking.request.key && h.kind == .active) = true := by
    apply List.any_eq_true.mpr
    refine ⟨holding, ?_, ?_⟩
    · exact List.mem_append_right _ (List.mem_flatMap.mpr ⟨booking, pending, by simp [singleton]⟩)
    · simp [holdingShape.1, holdingShape.2]
  have refused : refusal (foldProjectedRegistry world)
      (foldLegacyRequest world.registry.config (.termination booking)) = none := by
    simpa [refusal, foldLegacyRequest, allowed, admitsFor, requestDestination,
      foldProjectedRegistry, active] using
      (show (if (foldProjectedRegistry world).held.any
        (fun h => h.key == booking.request.key && h.kind == .active) then none else some "token-missing") = none by rw [custody]; rfl)
  have mint : assetSame
      (claimedMint [foldLegacyRequest world.registry.config (.termination booking)])
      (actualMint [foldLegacyRequest world.registry.config (.termination booking)]) = true := by
    simp [claimedMint, actualMint, foldLegacyRequest, requestClaim, assetDelta, assetSame]
  have scan : batchConsumesCreated [foldLegacyRequest world.registry.config (.termination booking)] = none := by
    simp [batchConsumesCreated, batchConsumesCreated.go, foldLegacyRequest]
  simp only [foldBatch, List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte, foldActions,
    step, refused, mint, scan, terminationWitnessResult, bind, Except.bind, pure, Except.pure]

end Singular
