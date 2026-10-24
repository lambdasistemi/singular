import NoPin.ApplicationRequests.MoneyHoldingClaims
import NoPin.ApplicationRequests.MoneyEvidence
import NoPin.ApplicationRequests.MoneyRefutation

/-! Hypothetical finite correction evidence; the general statement awaits its
independent statement review before proof work. -/
namespace NoPin.ApplicationRequests.Money
open Singular Lean NoPin.ApplicationRequests.Fixtures
set_option maxRecDepth 8192
set_option maxHeartbeats 4000000

namespace Evidence

/-- Hypothesis under #741, not accepted law; the complete original antecedent still holds. -/
theorem registration_fold_journey_holding_separated_antecedent :
    NewPremise hash code commit Refutation.decode release .registrationFold Refutation.input :=
  Refutation.antecedent

/-- Hypothesis under #741, not accepted law; the former counterexample now satisfies every claim conjunct. -/
theorem registration_fold_journey_holding_separated_positive :
    HoldingSeparatedClaim .none hash code commit Refutation.decode release Refutation.input := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, by trivial, by trivial⟩
  · intro party; cases party <;> decide
  · decide

/-- Hypothesis under #741, not accepted law; removing only the active-asset exclusion fails on coincident addresses. -/
theorem registration_fold_journey_holding_separated_mutant :
    ¬ (NewPremise hash code commit Refutation.decode release .registrationFold Refutation.input →
      HoldingSeparatedClaim .includeHolding hash code commit Refutation.decode release Refutation.input) := by
  intro result
  have bad := (result registration_fold_journey_holding_separated_antecedent).2.2.2.2.2.2.2.2.1
  exact (by decide : ¬ HoldingSeparatedFoldOutcome .includeHolding hash code commit Refutation.input) bad

/-- Hypothesis under #741, not accepted law; regression at the exact retained counterexample input. -/
theorem registration_fold_counterexample_corrected :
    HoldingSeparatedClaim .none hash code commit Refutation.decode release Refutation.input :=
  registration_fold_journey_holding_separated_positive

end Evidence

namespace Statements

/-- Hypothesis under #741, not accepted law. Status: STATED.
Registration fold: the folder's residual payment excludes the new holding even when their addresses coincide. -/
theorem registration_fold_journey_holding_separated (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationFold q) :
    HoldingSeparatedClaim .none h c t decode release q := by sorry

end Statements
end NoPin.ApplicationRequests.Money
