import Singular.Model

/-! Retraction edge and interval predicates. -/

namespace Singular

/-! ### Retraction admission: the checks, read as propositions -/

/-- The retractable edges are the two inserts and the read. -/
theorem retractableEdge_iff (e : Edge) :
    retractableEdge e = true ↔
      (e = .insertAbsent ∨ e = .insertActive ∨ e = .witnessTerminal) := by
  cases e <;> simp [retractableEdge]

/-- The phase-2 check is its two bounds: the lower one included, the upper one
reached and not passed. -/
theorem inPhase2_iff (c : Config) (r : Request) (w : RetractWitness) :
    inPhase2 c r w = true ↔
      (r.submittedAt + c.processTime ≤ w.validFrom ∧
        w.validTo ≤ r.submittedAt + c.processTime + c.retractTime) := by
  simp [inPhase2]

end Singular
