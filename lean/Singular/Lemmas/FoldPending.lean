import Singular.Economics.World
import Singular.Lemmas.EconomicFold

/-! The custody data retained by pending terminations remains the admitted
single active holding. This provenance does not depend on a current clock. -/

namespace Singular

def PendingCustodyShape (world : World) : Prop :=
  ∀ b ∈ world.terminations,
    b.request.singularTags = [world.registry.config.singularTag b.request.key] ∧
    b.custodyInputs.length = 1 ∧
    ∀ h ∈ b.custodyInputs, h.key = b.request.key ∧ h.kind = .active

theorem terminationBooking_custody_shape {registry : RegistryState} {b : TerminationBooking}
    (accepted : terminationBookingRefusal registry b = none) :
    b.request.singularTags = [registry.config.singularTag b.request.key] ∧
    b.custodyInputs.length = 1 ∧
    ∀ h ∈ b.custodyInputs, h.key = b.request.key ∧ h.kind = .active := by
  simp only [terminationBookingRefusal] at accepted
  repeat (split at accepted <;> try contradiction)
  rename_i shape amount singular trieReady custody inputs
  have tags : b.request.registryId = registry.config.registryId ∧
      b.request.singularTags = [registry.config.singularTag b.request.key] := by simpa using singular
  have held : b.custodyInputs = terminationCustody registry b.request.key ∧
      b.custodyInputs.length = 1 := by simpa using inputs
  refine ⟨tags.2, held.2, ?_⟩
  intro h member
  rw [held.1] at member
  simpa only [Bool.and_eq_true, beq_iff_eq] using (List.mem_filter.mp member).2

theorem reachable_pending_custody_shape (world : World) (reachable : WorldReachable world) :
    PendingCustodyShape world := by
  induction reachable with
  | initial registry h => simp [PendingCustodyShape]
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    split at accepted
    · contradiction
    · split at accepted
      · contradiction
      · cases accepted; exact ih
  | @termination before after reach transaction accepted ih =>
    unfold bookTermination at accepted
    split at accepted
    · contradiction
    next admitted =>
      split at accepted
      · contradiction
      · cases accepted
        intro b member
        rcases List.mem_cons.mp member with same | old
        · subst b; exact terminationBooking_custody_shape (registry := before.registry) admitted
        · exact ih b old
  | @rejection before after reach unspent transaction accepted ih =>
    rw [rejectionAccepted_effect accepted]
    exact ih
  | @retraction before after reach unspent transaction accepted ih =>
    rw [retractionAccepted_effect accepted]
    exact ih
  | @fold before after reach unspent transaction accepted ih =>
    intro b member
    rw [(foldAccepted_pending accepted).2] at member
    have old := ih b (List.mem_filter.mp member).1
    rw [foldAccepted_config accepted]
    simpa [Config.singularTag] using old

end Singular
