import SingularApplicationHeld

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld
open Singular Lean SingularApplicationHeld

def configurationAsset (hash : Hash) (code : Codec) (release : PublishedRelease)
    (registry : TokenId) : TokenId :=
  ⟨release.applicationPolicy, hash (code (.applicationConfiguration registry))⟩

inductive ApplicationAction where
  | configurationCreate (registry : TokenId) (seed : OutRef) (outputIndex : Nat)
  | bookRegistration (outputIndex : Nat)
  | bookTermination (inputReference : OutRef) (outputIndex : Nat)
  | registrationFold (inputReference : OutRef) (holdingIndex : Nat)
  | ownerReclaim (inputReference : OutRef)
  | expiredCleanup (inputReference : OutRef)
  | terminationFold (inputReference : OutRef) (registry : TokenId) (key : Key)
  | liveUpdate (inputReference : OutRef) (successorIndex : Nat)
  | approvalBurn
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure ApplicationObservation where
  assets : SingularApplicationHeld.Assets.TxView
  inputs : List ObservedOutput
  outputs : List ObservedOutput
  referenceInputs : List OutRef
  referenceOutputs : List ObservedOutput
  signers : List Nat
  interval : Interval
  fee : Nat
  donation : Nat
  actions : List ApplicationAction
  deriving BEq, DecidableEq

def configurationShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (registry : TokenId) (output : ObservedOutput) : Bool :=
  appGuard mutation .configurationShape
    (output.credential == release.applicationCredential &&
      (match output.datum with | .configuration _ => true | _ => false) &&
      exactAssets output [(configurationAsset hash code release registry, 1)])

def configurationRead (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (registry : TokenId) (observation : ApplicationObservation)
    (output : ObservedOutput) : Bool :=
  configurationShape mutation hash code release registry output &&
  appGuard mutation .configurationReference
    (observation.referenceInputs.contains output.reference &&
      observation.referenceOutputs.contains output)

def liveShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (control : ProtectedControl) : Bool :=
  appGuard mutation .liveShape
    (output.credential == release.applicationCredential && quantity output control.activeAsset == 1) &&
  appGuard mutation .liveControl
    (control.activeAsset == activeAsset hash code control.registry control.key) &&
  appGuard mutation .liveDeposit (control.deposit ≤ output.lovelace)

def ApplicationAction.inputReference : ApplicationAction → Option OutRef
  | .bookTermination ref _ | .registrationFold ref _ | .ownerReclaim ref |
    .expiredCleanup ref | .terminationFold ref _ _ | .liveUpdate ref _ => some ref
  | _ => none

def ApplicationAction.birthIndex : ApplicationAction → Option Nat
  | .configurationCreate _ _ index | .bookRegistration index | .bookTermination _ index => some index
  | _ => none

def requestInput (mutation : AppMutation) (observation : ApplicationObservation)
    (reference : OutRef) (output : ObservedOutput) : Bool :=
  appGuard mutation .requestInput (output.reference == reference &&
    observation.assets.spent.count reference == 1 &&
    (observation.inputs.filter fun input => input.reference == reference).length == 1)

def approvalsConsumed (observation : ApplicationObservation) (asset : TokenId) : Nat :=
  (observation.inputs.map fun output => quantity output asset).sum

def approvalBurned (mutation : AppMutation) (observation : ApplicationObservation) (asset : TokenId) : Bool :=
  appGuard mutation .approvalBurn
    (SingularApplicationHeld.Assets.mintQty observation.assets asset ≤ -(Int.ofNat (approvalsConsumed observation asset)))

def registrationClock (mutation : AppMutation) (data : RegistrationData)
    (parameters : ApplicationParameters) (interval : Interval) : Bool :=
  appGuard mutation .registrationClock (nonemptyInterval interval && data.bookedAt == interval.upper &&
    interval.upper - interval.lower ≤ parameters.bookingWidth &&
    data.processDeadline == data.bookedAt + parameters.processTime &&
    data.reclaimEnd == data.processDeadline + parameters.retractTime)

def initialControl (hash : Hash) (code : Codec) (decode : DecodeApplication) (data : RegistrationData) : Bool :=
  match decode data.initialDatum with
  | some (.live control _) => control.registry == data.registry && control.key == data.key &&
      control.controller == data.controller && control.deposit == data.deposit &&
      control.activeAsset == activeAsset hash code data.registry data.key
  | _ => false

def birth (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (observation : ApplicationObservation)
    (action : ApplicationAction) : Option TokenId := do
  match action with
  | .configurationCreate registry _ _ => return configurationAsset hash code release registry
  | .bookRegistration index =>
    let output ← observation.outputs[index]?
    let .registration data ← decoded decode output | none
    return registrationAsset hash code release data
  | .bookTermination reference _ =>
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .live control _ ← decoded decode input | none
    return terminationApproval hash code release control.registry control.key
  | _ => none

def freshAsset (mutation : AppMutation) (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (observation : ApplicationObservation) (asset : TokenId) : Bool :=
  let births := observation.actions.filterMap (birth hash code decode release observation)
  appGuard mutation .freshApproval (SingularApplicationHeld.Assets.mintQty observation.assets asset == Int.ofNat (births.count asset) &&
    births.count asset > 0)

def configurationCreate (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (registry : TokenId) (seed : OutRef)
    (output : ObservedOutput) (observation : ApplicationObservation) : Bool :=
  configurationShape mutation hash code release registry output &&
  appGuard mutation .configurationGenesis
    (registry.name == hash (code (.state seed)) && observation.assets.spent.count seed == 1 &&
      observation.assets.invoked.contains registry.policy && SingularApplicationHeld.Assets.mintQty observation.assets registry == 1 &&
      SingularApplicationHeld.Assets.mintQty observation.assets (configurationAsset hash code release registry) == 1) &&
  freshAsset mutation hash code decode release observation (configurationAsset hash code release registry)

def registrationBook (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (output : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  registrationShape mutation hash code release output data &&
  appGuard mutation .registrationControl
    (data.holdingAddress.paymentCredential == release.applicationCredential && initialControl hash code decode data) &&
  appGuard mutation .bookingSignature (observation.signers.contains data.controller) &&
  observation.referenceOutputs.any (fun configuration =>
    configurationRead mutation hash code release data.registry observation configuration &&
    match configuration.datum with
    | .configuration parameters => registrationClock mutation data parameters observation.interval
    | _ => false) &&
  freshAsset mutation hash code decode release observation (registrationAsset hash code release data)

def terminationBook (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (input output : ObservedOutput)
    (control : ProtectedControl) (observation : ApplicationObservation) : Bool :=
  liveShape mutation hash code release input control &&
  appGuard mutation .bookingSignature (observation.signers.contains control.controller) &&
  terminationShape mutation hash code release output control.registry control.key &&
  freshAsset mutation hash code decode release observation
    (terminationApproval hash code release control.registry control.key)

def registrationSpend (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (action : ApplicationAction) (input : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  registrationShape mutation hash code release input data &&
  approvalBurned mutation observation (registrationAsset hash code release data) &&
  match action with
  | .registrationFold _ index =>
    appGuard mutation .processingPhase (classifyPhase data observation.interval == .processing) &&
    appGuard mutation .registrationDelivery (match observation.outputs[index]? with
      | some holding => holding.address == data.holdingAddress &&
          holding.datum == .application data.initialDatum && holding.lovelace == data.deposit &&
          quantity holding (activeAsset hash code data.registry data.key) == 1 &&
          SingularApplicationHeld.Assets.mintQty observation.assets (activeAsset hash code data.registry data.key) == 1
      | none => false)
  | .ownerReclaim _ =>
    appGuard mutation .reclaimPhase (classifyPhase data observation.interval == .reclaim &&
      observation.signers.contains data.controller)
  | .expiredCleanup _ =>
    appGuard mutation .cleanupPhase (classifyPhase data observation.interval == .cleanup)
  | _ => false

def terminationSpend (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (input : ObservedOutput) (registry : TokenId) (key : Key)
    (observation : ApplicationObservation) : Bool :=
  terminationShape mutation hash code release input registry key &&
  approvalBurned mutation observation (terminationApproval hash code release registry key) &&
  appGuard mutation .terminationActiveBurn
    (SingularApplicationHeld.Assets.mintQty observation.assets (activeAsset hash code registry key) == -1) &&
  appGuard mutation .terminationInvocation (observation.assets.invoked.contains registry.policy)

def liveUpdate (mutation : AppMutation) (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (input successor : ObservedOutput) (control : ProtectedControl)
    (observation : ApplicationObservation) : Bool :=
  liveShape mutation hash code release input control &&
  appGuard mutation .bookingSignature (observation.signers.contains control.controller) &&
  appGuard mutation .updateControl
    (successor.credential == release.applicationCredential && match decoded decode successor with
      | some (.live next _) => next == control | _ => false) &&
  appGuard mutation .updateAssets (exactAssets successor input.assets) &&
  appGuard mutation .updateDeposit (control.deposit ≤ successor.lovelace)

def applicationAction (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (observation : ApplicationObservation)
    (action : ApplicationAction) : Bool := Id.run do
  match action with
  | .configurationCreate registry seed index =>
    return match observation.outputs[index]? with
      | some output => configurationCreate mutation hash code decode release registry seed output observation
      | none => false
  | .bookRegistration index =>
    return match observation.outputs[index]? with
      | some output => match decoded decode output with
        | some (.registration data) => registrationBook mutation hash code decode release output data observation
        | _ => false
      | none => false
  | .approvalBurn => return true
  | _ =>
    let some reference := action.inputReference | return false
    let some input := observation.inputs.find? (fun output => output.reference == reference) | return false
    if !requestInput mutation observation reference input then return false
    match action with
    | .terminationFold _ registry key => return terminationSpend mutation hash code release input registry key observation
    | .bookTermination _ index =>
      let some output := observation.outputs[index]? | return false
      let some (.live control _) := decoded decode input | return false
      return terminationBook mutation hash code decode release input output control observation
    | .liveUpdate _ index =>
      let some successor := observation.outputs[index]? | return false
      let some (.live control _) := decoded decode input | return false
      return liveUpdate mutation hash code decode release input successor control observation
    | _ =>
      let some (.registration data) := decoded decode input | return false
      return registrationSpend mutation hash code release action input data observation

def requiredPayments (decode : DecodeApplication) (observation : ApplicationObservation) : List (Nat × Nat) :=
  observation.actions.filterMap fun action => do
    let reference ← action.inputReference
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .registration data ← decoded decode input | none
    match action with
    | .registrationFold .. => return (data.holdingAddress.paymentCredential, data.deposit)
    | .ownerReclaim .. => return (data.refundAddress, input.lovelace)
    | .expiredCleanup .. => return (data.refundAddress, data.deposit)
    | _ => none

def requiredTreasury (decode : DecodeApplication) (observation : ApplicationObservation) : Nat :=
  (observation.actions.filterMap fun action => do
    let .bookTermination reference _ := action | none
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .live control _ ← decoded decode input | none
    return control.deposit).sum

def paidTo (outputs : List ObservedOutput) (address : Nat) : Nat :=
  ((outputs.filter fun output => output.credential == address).map (·.lovelace)).sum

def requestValueSplit (mutation : AppMutation) (decode : DecodeApplication)
    (observation : ApplicationObservation) : Bool :=
  let requirements := requiredPayments decode observation
  appGuard mutation .moneyOutputs (requirements.all fun entry =>
    ((requirements.filter fun other => other.1 == entry.1).map (·.2)).sum ≤
      paidTo observation.outputs entry.1) &&
  appGuard mutation .moneyTreasury (observation.donation == requiredTreasury decode observation)

end OpenDatumApplicationHeld
