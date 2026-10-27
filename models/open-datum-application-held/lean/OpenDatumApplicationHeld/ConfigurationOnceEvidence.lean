import OpenDatumApplicationHeld.RefundLifecycleStatements
import OpenDatumApplicationHeld.MoneyFixtures

/-! The application-held open-datum model beside the current one.
Certificates that the statement of one configuration record is not vacuous: the
creation of the model's fixtures is accepted and holds its antecedent, and the
same creation with a second record is refused. -/

set_option maxRecDepth 8192
set_option maxHeartbeats 4000000
namespace OpenDatumApplicationHeld.RefundLifecycle.Evidence
open Singular Lean SingularApplicationHeld OpenDatumApplicationHeld OpenDatumApplicationHeld.Fixtures
open OpenDatumApplicationHeld.Money.Fixtures

def twoRecords : ApplicationObservation :=
  let outputs := match createObservation.outputs with
    | [state, record] => [state, record, record]
    | other => other
  { createObservation with
    outputs := outputs
    actions := [.configurationCreate registryId seed 1, .configurationCreate registryId seed 2]
    assets := { createObservation.assets with
      outputs := outputs.map (fun output => ⟨output.assets⟩)
      mint := [(registryId, 1), (configurationAsset hash code release registryId, 2)] } }

theorem configuration_created_once_antecedent :
    RefundApplication.applicationStep .none hash code decode release createObservation = true ∧
      ApplicationAction.configurationCreate registryId seed 1 ∈ createObservation.actions :=
  ⟨by decide, List.Mem.head _⟩

theorem configuration_created_once_positive :
    configurationCreations registryId createObservation.actions = 1 ∧
      SingularApplicationHeld.Assets.mintQty createObservation.assets
        (configurationAsset hash code release registryId) = 1 := by
  decide

theorem configuration_created_once_mutant :
    RefundApplication.applicationStep .none hash code decode release twoRecords = false := by
  decide

end OpenDatumApplicationHeld.RefundLifecycle.Evidence
