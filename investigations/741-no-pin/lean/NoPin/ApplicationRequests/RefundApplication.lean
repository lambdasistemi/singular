import NoPin.ApplicationRequests.Application

/-! Hypothetical #741 replacement for the controller-signer request law.
The earlier Application and Lifecycle declarations remain historical. Booking
still needs the controller; reclaim needs the refund address, as the accepted
economic retraction does. Other action branches reuse their unchanged owners.
No signature is synthesized and no observed transaction field is rewritten. -/
namespace NoPin.ApplicationRequests.RefundApplication
open Singular Lean

/-- Hypothesis under #741, not accepted law; the refund address controls recovery. -/
def registrationSpend (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (action : ApplicationAction) (input : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  match action with
  | .ownerReclaim _ =>
    registrationShape mutation hash code release input data &&
    approvalBurned mutation observation (registrationAsset hash code release data) &&
    appGuard mutation .reclaimPhase (classifyPhase data observation.interval == .reclaim &&
      observation.signers.contains data.refundAddress)
  | _ => NoPin.ApplicationRequests.registrationSpend mutation hash code release action input data observation
/-- Hypothesis under #741, not accepted law; only the reclaim branch is restated. -/
def applicationAction (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (observation : ApplicationObservation)
    (action : ApplicationAction) : Bool := Id.run do
  match action with
  | .ownerReclaim reference =>
    let some input := observation.inputs.find? (fun output => output.reference == reference) | return false
    if !requestInput mutation observation reference input then return false
    let some (.registration data) := decoded decode input | return false
    return registrationSpend mutation hash code release action input data observation
  | _ => return NoPin.ApplicationRequests.applicationAction mutation hash code decode release observation action
/-- Hypothesis under #741, not accepted law; the same aggregate guards dispatch the corrected action. -/
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
    NoPin.mintQty observation.assets entry.1 ≤ 0 || births.contains entry.1) &&
  requestValueSplit mutation decode observation

end NoPin.ApplicationRequests.RefundApplication
