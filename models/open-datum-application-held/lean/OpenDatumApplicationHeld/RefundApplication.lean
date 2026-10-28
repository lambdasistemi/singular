import OpenDatumApplicationHeld.Application

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld.RefundApplication
open Singular Lean SingularApplicationHeld

def registrationSpend (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (action : ApplicationAction) (input : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  match action with
  | .ownerReclaim _ =>
    registrationShape mutation hash code release input data &&
    approvalBurned mutation observation (registrationAsset hash code release data) &&
    appGuard mutation .reclaimPhase (classifyPhase data observation.interval == .reclaim &&
      observation.signers.contains data.refundAddress)
  | _ => OpenDatumApplicationHeld.registrationSpend mutation hash code release action input data observation

def applicationAction (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (observation : ApplicationObservation)
    (action : ApplicationAction) : Bool := Id.run do
  match action with
  | .ownerReclaim reference =>
    let some input := observation.inputs.find? (fun output => output.reference == reference) | return false
    if !requestInput mutation observation reference input then return false
    let some (.registration data) := decoded decode input | return false
    return registrationSpend mutation hash code release action input data observation
  | _ => return OpenDatumApplicationHeld.applicationAction mutation hash code decode release observation action

def applicationStep (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (observation : ApplicationObservation) : Bool :=
  let references := observation.actions.filterMap ApplicationAction.inputReference
  let appInputs := observation.inputs.filter fun output => output.credential == release.applicationCredential
  let births := observation.actions.filterMap (birth hash code decode release observation)
  appGuard mutation .inputCoverage
    (decide references.Nodup && references.length == appInputs.length &&
      appInputs.all (fun input => references.contains input.reference)) &&
  appGuard mutation .birthCoverage
    (decide (observation.actions.filterMap ApplicationAction.birthIndex).Nodup) &&
  observation.actions.all (applicationAction mutation hash code decode release observation) &&
  observation.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy ||
    SingularApplicationHeld.Assets.mintQty observation.assets entry.1 ≤ 0 || births.contains entry.1) &&
  requestValueSplit mutation decode observation

end OpenDatumApplicationHeld.RefundApplication
