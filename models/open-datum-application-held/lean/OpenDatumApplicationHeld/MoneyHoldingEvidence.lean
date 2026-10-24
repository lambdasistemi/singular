import OpenDatumApplicationHeld.MoneyHoldingClaims
import OpenDatumApplicationHeld.MoneyEvidence
import OpenDatumApplicationHeld.MoneyCoincidentFixture


namespace OpenDatumApplicationHeld.Money
open Singular Lean SingularApplicationHeld OpenDatumApplicationHeld.Fixtures
set_option maxRecDepth 8192
set_option maxHeartbeats 4000000

namespace Evidence


theorem registration_fold_journey_holding_separated_antecedent :
    NewPremise hash code commit Refutation.decode release .registrationFold Refutation.input :=
  Refutation.antecedent


theorem registration_fold_journey_holding_separated_positive :
    HoldingSeparatedClaim .none hash code commit Refutation.decode release Refutation.input := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, by trivial, by trivial⟩
  · intro party; cases party <;> decide
  · decide


theorem registration_fold_journey_holding_separated_mutant :
    ¬ (NewPremise hash code commit Refutation.decode release .registrationFold Refutation.input →
      HoldingSeparatedClaim .includeHolding hash code commit Refutation.decode release Refutation.input) := by
  intro result
  have bad := (result registration_fold_journey_holding_separated_antecedent).2.2.2.2.2.2.2.2.1
  exact (by decide : ¬ HoldingSeparatedFoldOutcome .includeHolding hash code commit Refutation.input) bad


theorem registration_fold_counterexample_corrected :
    HoldingSeparatedClaim .none hash code commit Refutation.decode release Refutation.input :=
  registration_fold_journey_holding_separated_positive

end Evidence


end OpenDatumApplicationHeld.Money
