import OpenDatumApplicationHeld.MoneyEvidence
namespace OpenDatumApplicationHeld.Money
open Singular Lean SingularApplicationHeld
namespace Fixtures

def oldUpdatedWorld : OpenDatumApplication.World :=
  (oldUpdate .none oldApplicationWorld 0 [oldSuccessor] [42]).toOption.getD oldApplicationWorld
end Fixtures

namespace Evidence
open OpenDatumApplicationHeld.Fixtures

theorem update_both_models_antecedent : UpdatePremise hash code commit decode release (Fixtures.input .update)
    Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42] := by
  exact ⟨update_journey_antecedent, by rfl, Fixtures.oldLive, by rfl, by rfl⟩

theorem update_both_models_positive : UpdateClaim .none hash code commit decode release (Fixtures.input .update)
    Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42] := by
  refine ⟨update_journey_positive, Fixtures.oldUpdatedWorld, by rfl, Fixtures.oldLive,
    { Fixtures.oldLive with ref := 1, envelope := Fixtures.oldSuccessor.envelope },
    by rfl, ?_, by rfl, by rfl, by rfl, by decide⟩
  change _ ∈ (Fixtures.oldApplicationWorld.outputs.erase Fixtures.oldLive) ++ [_]
  exact List.mem_append_right _ List.mem_cons_self

theorem update_both_models_mutant : ¬ (UpdatePremise hash code commit decode release (Fixtures.input .update)
    Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42] →
    UpdateClaim (.application .updateControl) hash code commit decode release (Fixtures.input .update)
      Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42]) := by
  intro result
  have bad := (result update_both_models_antecedent).1.1
  have refused : RefundApplication.applicationStep (.flip .updateControl) hash code decode release
      (Fixtures.input .update).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible
end Evidence
end OpenDatumApplicationHeld.Money
