import Singular.Model

/-! Evidence-bound rejection and protection before expiry. -/

namespace Singular.Statements

/-- Rejection is admitted exactly for identity-bound evidence and one of its two positive
conditions. The root check uses the model's logical map. -/
theorem rejection_admitted_iff (s : RegistryState) (r : Request) (w : RejectWitness) :
    rejectAdmission s r (some w) = none ↔
      r.registryId = s.config.registryId ∧
      w.evidence.registry = s.config ∧
      s.config.root = rootOf s.trie ∧
      w.evidence.request = r ∧
      w.validFrom < w.validTo ∧
      (match w.evidence.reason with
       | .mismatch leaf => leaf = trieGet s.trie r.key ∧ transition r.edge leaf = none
       | .expired => r.submittedAt + s.config.processTime + s.config.retractTime ≤ w.validFrom) := by
  unfold rejectAdmission
  cases h : w.evidence.reason <;>
    simp only [h] <;>
    (repeat' split <;> simp_all [bne, Bool.or_eq_true, Nat.not_le, Option.isSome_iff_ne_none])
  all_goals grind

/-- A lifecycle-compatible request cannot be rejected before expiry, regardless of the
evidence the processor chooses to supply. -/
theorem live_compatible_request_protected (s : RegistryState) (r : Request) (w : RejectWitness)
    (compatible : transition r.edge (trieGet s.trie r.key) ≠ none)
    (live : w.validFrom < r.submittedAt + s.config.processTime + s.config.retractTime) :
    rejectAdmission s r (some w) ≠ none := by
  intro admitted
  obtain ⟨_, _, _, _, _, condition⟩ := (rejection_admitted_iff s r w).mp admitted
  cases h : w.evidence.reason with
  | mismatch leaf =>
    simp only [h] at condition
    obtain ⟨same, refused⟩ := condition
    rw [same] at refused
    exact compatible refused
  | expired =>
    simp only [h] at condition
    omega

end Singular.Statements
