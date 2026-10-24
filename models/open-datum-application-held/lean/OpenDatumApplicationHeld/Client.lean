import OpenDatumApplicationHeld.Application

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld
open Singular Lean SingularApplicationHeld

def applicationFoldView (observation : FoldObservation) (requests : List PendingRequest) : ApplicationObservation :=
  let (actions, _) := requests.foldl (fun (actions, index) request => match request with
    | .registration output _ => (actions ++ [ApplicationAction.registrationFold output.reference index], index + 1)
    | .termination output registry key => (actions ++ [.terminationFold output.reference registry key], index)) ([], 1)
  ⟨observation.assets, observation.spentOutputs, observation.outputs, [], [], observation.signers,
    observation.interval, observation.fee, observation.donation, actions⟩

end OpenDatumApplicationHeld
