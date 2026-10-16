import Singular.Model.LedgerBoundary
import Singular.Lemmas.Step

/-! Removing one terminal holding preserves the registry's consistency facts. -/

namespace Singular.LedgerBoundary

theorem filter_eraseP_disjoint {α : Type} (xs : List α) (p q : α → Bool)
    (disjoint : ∀ a, p a = true → q a = false) :
    (xs.eraseP p).filter q = xs.filter q := by
  induction xs with
  | nil => rfl
  | cons a rest ih =>
    by_cases removed : p a = true
    · simp [List.eraseP_cons, removed, disjoint a removed]
    · simp [List.eraseP_cons, removed, List.filter_cons, ih]

theorem discard_active_count (state : RegistryState) (key : Key) (output k : Nat) :
    kindCount (discardTerminal state key output) .active k = kindCount state .active k := by
  unfold kindCount discardTerminal
  congr 1
  apply filter_eraseP_disjoint
  intro holding removed
  simp only [Bool.and_eq_true, beq_iff_eq] at removed
  simp [removed.1.2]

theorem discard_consistent (state : RegistryState) (key : Key) (output : Nat)
    (consistent : Consistent state) : Consistent (discardTerminal state key output) := by
  rcases consistent with ⟨root, active, activeBound, absent, absentBound, terminal, custody, unique⟩
  refine ⟨root, ?_, ?_, absent, absentBound, ?_, custody, unique⟩
  · intro k; rw [discard_active_count]; exact active k
  · intro k; rw [discard_active_count]; exact activeBound k
  · intro holding member kind
    exact terminal holding (List.mem_of_mem_eraseP member) kind

end Singular.LedgerBoundary
