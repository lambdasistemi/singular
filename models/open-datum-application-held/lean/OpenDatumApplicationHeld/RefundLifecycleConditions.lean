import OpenDatumApplicationHeld.Client
import OpenDatumApplicationHeld.RefundApplication

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld.RefundLifecycle
open Singular Lean SingularApplicationHeld

abbrev applicationStep := RefundApplication.applicationStep

abbrev applicationAction := RefundApplication.applicationAction


def requestInputConditions (o : ApplicationObservation) (ref : OutRef) (output : ObservedOutput) : Bool :=
  output.reference == ref && o.assets.spent.count ref == 1 &&
    (o.inputs.filter fun input => input.reference == ref).length == 1


def phaseConditions (r : RegistrationData) (i : Interval) : RegistrationPhase :=
  if !(i.lower < i.upper) then .refused
  else if i.upper ≤ r.processDeadline then .processing
  else if r.processDeadline ≤ i.lower && i.upper ≤ r.reclaimEnd then .reclaim
  else if r.reclaimEnd ≤ i.lower then .cleanup else .refused


def exactAssetsConditions (output : ObservedOutput) (expected : List (TokenId × Nat)) : Bool :=
  let support := (output.assets ++ expected).map (·.1)
  support.all (fun asset => quantity output asset ==
    ((expected.filter fun entry => entry.1 == asset).map (·.2)).sum)

def configurationShapeConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (registry : TokenId) (output : ObservedOutput) : Bool :=
  (output.credential == release.applicationCredential &&
      (match output.datum with | .configuration _ => true | _ => false) &&
      exactAssetsConditions output [(configurationAsset hash code release registry, 1)])

def configurationReadConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (registry : TokenId) (observation : ApplicationObservation)
    (output : ObservedOutput) : Bool :=
  configurationShapeConditions  hash code release registry output &&
  (observation.referenceInputs.contains output.reference &&
      observation.referenceOutputs.contains output)

def registrationAssetConditions (hash : Hash) (code : Codec) (release : PublishedRelease)
    (data : RegistrationData) : TokenId :=
  registrationApproval hash code release data.registry data.key data.holdingAddress data.initialDatum data.deposit

def registrationShapeConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (data : RegistrationData) : Bool :=
  (output.credential == release.applicationCredential &&
    exactAssetsConditions output [(registrationAssetConditions hash code release data, 1)]) &&
  (data.deposit ≤ output.lovelace)

def liveShapeConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (control : ProtectedControl) : Bool :=
  (output.credential == release.applicationCredential && quantity output control.activeAsset == 1) &&
  (control.activeAsset == activeAsset hash code control.registry control.key) &&
  (control.deposit ≤ output.lovelace)

def terminationShapeConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (registry : TokenId) (key : Key) : Bool :=
  (output.credential == release.applicationCredential && output.datum == .empty &&
     exactAssetsConditions output [(activeAsset hash code registry key, 1),
       (terminationApproval hash code release registry key, 1)])

def approvalsConsumedConditions (observation : ApplicationObservation) (asset : TokenId) : Nat :=
  (observation.inputs.map fun output => quantity output asset).sum

def approvalBurnedConditions (observation : ApplicationObservation) (asset : TokenId) : Bool :=
  (SingularApplicationHeld.Assets.mintQty observation.assets asset ≤ -(Int.ofNat (approvalsConsumedConditions observation asset)))

def registrationClockConditions (data : RegistrationData)
    (parameters : ApplicationParameters) (interval : Interval) : Bool :=
  (nonemptyInterval interval && data.bookedAt == interval.upper &&
    interval.upper - interval.lower ≤ parameters.bookingWidth &&
    data.processDeadline == data.bookedAt + parameters.processTime &&
    data.reclaimEnd == data.processDeadline + parameters.retractTime)

def initialControlConditions (hash : Hash) (code : Codec) (decode : DecodeApplication) (data : RegistrationData) : Bool :=
  match decode data.initialDatum with
  | some (.live control _) => control.registry == data.registry && control.key == data.key &&
      control.controller == data.controller && control.deposit == data.deposit &&
      control.activeAsset == activeAsset hash code data.registry data.key
  | _ => false

def birthConditions (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (observation : ApplicationObservation)
    (action : ApplicationAction) : Option TokenId := do
  match action with
  | .configurationCreate registry _ _ => return configurationAsset hash code release registry
  | .bookRegistration index =>
    let output ← observation.outputs[index]?
    let .registration data ← decoded decode output | none
    return registrationAssetConditions hash code release data
  | .bookTermination reference _ =>
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .live control _ ← decoded decode input | none
    return terminationApproval hash code release control.registry control.key
  | _ => none

def freshAssetConditions (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (observation : ApplicationObservation) (asset : TokenId) : Bool :=
  let births := observation.actions.filterMap (birthConditions hash code decode release observation)
  (SingularApplicationHeld.Assets.mintQty observation.assets asset == Int.ofNat (births.count asset) &&
    births.count asset > 0)

def configurationCreateConditions (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (registry : TokenId) (seed : OutRef)
    (output : ObservedOutput) (observation : ApplicationObservation) : Bool :=
  configurationShapeConditions  hash code release registry output &&
  (registry.name == hash (code (.state seed)) && observation.assets.spent.count seed == 1 &&
      observation.assets.invoked.contains registry.policy && SingularApplicationHeld.Assets.mintQty observation.assets registry == 1) &&
  freshAssetConditions  hash code decode release observation (configurationAsset hash code release registry)

def registrationBookConditions (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (output : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  registrationShapeConditions  hash code release output data &&
  (data.holdingAddress == release.applicationCredential && initialControlConditions hash code decode data) &&
  (observation.signers.contains data.controller) &&
  observation.referenceOutputs.any (fun configuration =>
    configurationReadConditions  hash code release data.registry observation configuration &&
    match configuration.datum with
    | .configuration parameters => registrationClockConditions  data parameters observation.interval
    | _ => false) &&
  freshAssetConditions  hash code decode release observation (registrationAssetConditions hash code release data)

def terminationBookConditions (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (input output : ObservedOutput)
    (control : ProtectedControl) (observation : ApplicationObservation) : Bool :=
  liveShapeConditions  hash code release input control &&
  (observation.signers.contains control.controller) &&
  terminationShapeConditions  hash code release output control.registry control.key &&
  freshAssetConditions  hash code decode release observation
    (terminationApproval hash code release control.registry control.key)

def registrationSpendConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (action : ApplicationAction) (input : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  registrationShapeConditions  hash code release input data &&
  approvalBurnedConditions  observation (registrationAssetConditions hash code release data) &&
  match action with
  | .registrationFold _ index =>
    (phaseConditions data observation.interval == .processing) &&
    (match observation.outputs[index]? with
      | some holding => holding.credential == data.holdingAddress &&
          holding.datum == .application data.initialDatum && holding.lovelace == data.deposit &&
          quantity holding (activeAsset hash code data.registry data.key) == 1 &&
          SingularApplicationHeld.Assets.mintQty observation.assets (activeAsset hash code data.registry data.key) == 1
      | none => false)
  | .ownerReclaim _ =>
    (phaseConditions data observation.interval == .reclaim &&
      observation.signers.contains data.refundAddress)
  | .expiredCleanup _ =>
    (phaseConditions data observation.interval == .cleanup)
  | _ => false

def terminationSpendConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (input : ObservedOutput) (registry : TokenId) (key : Key)
    (observation : ApplicationObservation) : Bool :=
  terminationShapeConditions  hash code release input registry key &&
  approvalBurnedConditions  observation (terminationApproval hash code release registry key) &&
  (SingularApplicationHeld.Assets.mintQty observation.assets (activeAsset hash code registry key) == -1) &&
  (observation.assets.invoked.contains registry.policy)

def liveUpdateConditions (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (input successor : ObservedOutput) (control : ProtectedControl)
    (observation : ApplicationObservation) : Bool :=
  liveShapeConditions  hash code release input control &&
  (observation.signers.contains control.controller) &&
  (successor.credential == release.applicationCredential && match decoded decode successor with
      | some (.live next _) => next == control | _ => false) &&
  (exactAssetsConditions successor input.assets) &&
  (control.deposit ≤ successor.lovelace)

def applicationActionConditions (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (observation : ApplicationObservation)
    (action : ApplicationAction) : Bool := Id.run do
  match action with
  | .configurationCreate registry seed index =>
    return match observation.outputs[index]? with
      | some output => configurationCreateConditions  hash code decode release registry seed output observation
      | none => false
  | .bookRegistration index =>
    return match observation.outputs[index]? with
      | some output => match decoded decode output with
        | some (.registration data) => registrationBookConditions  hash code decode release output data observation
        | _ => false
      | none => false
  | .approvalBurn => return true
  | _ =>
    let some reference := action.inputReference | return false
    let some input := observation.inputs.find? (fun output => output.reference == reference) | return false
    if !requestInputConditions  observation reference input then return false
    match action with
    | .terminationFold _ registry key => return terminationSpendConditions  hash code release input registry key observation
    | .bookTermination _ index =>
      let some output := observation.outputs[index]? | return false
      let some (.live control _) := decoded decode input | return false
      return terminationBookConditions  hash code decode release input output control observation
    | .liveUpdate _ index =>
      let some successor := observation.outputs[index]? | return false
      let some (.live control _) := decoded decode input | return false
      return liveUpdateConditions  hash code decode release input successor control observation
    | _ =>
      let some (.registration data) := decoded decode input | return false
      return registrationSpendConditions  hash code release action input data observation

def requiredPaymentsConditions (decode : DecodeApplication) (observation : ApplicationObservation) : List (Nat × Nat) :=
  observation.actions.filterMap fun action => do
    let reference ← action.inputReference
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .registration data ← decoded decode input | none
    match action with
    | .registrationFold .. => return (data.holdingAddress, data.deposit)
    | .ownerReclaim .. => return (data.refundAddress, input.lovelace)
    | .expiredCleanup .. => return (data.refundAddress, data.deposit)
    | _ => none

def requiredTreasuryConditions (decode : DecodeApplication) (observation : ApplicationObservation) : Nat :=
  (observation.actions.filterMap fun action => do
    let .bookTermination reference _ := action | none
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .live control _ ← decoded decode input | none
    return control.deposit).sum

def paidToConditions (outputs : List ObservedOutput) (address : Nat) : Nat :=
  ((outputs.filter fun output => output.credential == address).map (·.lovelace)).sum

def requestValueSplitConditions (decode : DecodeApplication)
    (observation : ApplicationObservation) : Bool :=
  let requirements := requiredPaymentsConditions decode observation
  (requirements.all fun entry =>
    ((requirements.filter fun other => other.1 == entry.1).map (·.2)).sum ≤
      paidToConditions observation.outputs entry.1) &&
  (observation.donation == requiredTreasuryConditions decode observation)

def applicationStepConditions (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (observation : ApplicationObservation) : Bool :=
  let references := observation.actions.filterMap ApplicationAction.inputReference
  let appInputs := observation.inputs.filter fun output => output.credential == release.applicationCredential
  let births := observation.actions.filterMap (birthConditions hash code decode release observation)
  (decide references.Nodup && references.length == appInputs.length &&
      appInputs.all (fun input => references.contains input.reference)) &&
  (decide (observation.actions.filterMap ApplicationAction.birthIndex).Nodup) &&
  observation.actions.all (applicationActionConditions  hash code decode release observation) &&
  observation.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy ||
    SingularApplicationHeld.Assets.mintQty observation.assets entry.1 ≤ 0 || births.contains entry.1) &&
  requestValueSplitConditions  decode observation

end OpenDatumApplicationHeld.RefundLifecycle
