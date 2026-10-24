import NoPin.ApplicationRequests.Core

/-! Hypotheses under #741, not accepted law. Application rules inspect physical
transaction observations and public application datum decoding. They never take
a logical registry/trie/root input, never call Singular's fold handler, and do
not infer successful folds from the openly burnable approval alone. -/
namespace NoPin.ApplicationRequests
open Singular Lean

/-- Hypothesis under #741, not accepted law; immutable live ownership/deposit. -/
structure ProtectedControl where
  registry : TokenId
  activeAsset : TokenId
  key : Key
  controller : Nat
  deposit : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; publicly decoded pending registration. -/
structure RegistrationData where
  registry : TokenId
  key : Key
  controller : Nat
  refundAddress : Nat
  holdingAddress : Nat
  initialDatum : Nat
  deposit : Nat
  bookedAt : Nat
  processDeadline : Nat
  reclaimEnd : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; live and pending decode categories disjoint. -/
inductive ApplicationDatum where
  | registration (data : RegistrationData)
  | live (control : ProtectedControl) (payload : Nat)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; same-output public decoding, not hash inversion. -/
abbrev DecodeApplication := Nat → Option ApplicationDatum
/-- Hypothesis under #741, not accepted law; decode the observed datum of this output. -/
def decoded (decode : DecodeApplication) (output : ObservedOutput) : Option ApplicationDatum :=
  match output.datum with | .application data => decode data | _ => none
/-- Hypothesis under #741, not accepted law; actual redeemers, not claimed payment purposes. -/
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
/-- Hypothesis under #741, not accepted law; no registry-state argument is present. -/
structure ApplicationObservation where
  assets : NoPin.TxView
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
/-- Hypothesis under #741, not accepted law; atomic application guard sites. -/
inductive AppGuard where
  | configurationShape | configurationGenesis | configurationReference
  | registrationShape | registrationControl | registrationClock | registrationFunding
  | bookingSignature | terminationShape | liveShape | liveControl | liveDeposit
  | requestInput | approvalBurn | freshApproval | processingPhase | reclaimPhase | cleanupPhase
  | registrationDelivery | terminationActiveBurn | terminationInvocation
  | updateControl | updateAssets | updateDeposit | inputCoverage | birthCoverage | moneyOutputs | moneyTreasury
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; one application decision site only. -/
inductive AppMutation where
  | none | flip (site : AppGuard)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; selector isolation. -/
def appGuard (mutation : AppMutation) (site : AppGuard) (condition : Bool) : Bool :=
  if mutation == .flip site then !condition else condition
/-- Hypothesis under #741, not accepted law; an actual nonempty interval. -/
def nonemptyInterval (interval : Interval) : Bool := interval.lower < interval.upper
/-- Hypothesis under #741, not accepted law; three disjoint phases, straddles refuse. -/
inductive RegistrationPhase where
  | processing | reclaim | cleanup | refused
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; no trie/key-exists rejection path. -/
def classifyPhase (data : RegistrationData) (interval : Interval) : RegistrationPhase :=
  if !nonemptyInterval interval then .refused
  else if interval.upper ≤ data.processDeadline then .processing
  else if data.processDeadline ≤ interval.lower && interval.upper ≤ data.reclaimEnd then .reclaim
  else if data.reclaimEnd ≤ interval.lower then .cleanup else .refused
/-- Hypothesis under #741, not accepted law; exact positive asset multiset. -/
def exactAssets (output : ObservedOutput) (expected : List (TokenId × Nat)) : Bool :=
  let support := (output.assets ++ expected).map (·.1)
  support.all (fun asset => quantity output asset ==
    ((expected.filter fun entry => entry.1 == asset).map (·.2)).sum)
/-- Hypothesis under #741, not accepted law; configuration never reads a root. -/
def configurationShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (registry : TokenId) (output : ObservedOutput) : Bool :=
  appGuard mutation .configurationShape
    (output.credential == release.applicationCredential &&
      (match output.datum with | .configuration _ => true | _ => false) &&
      exactAssets output [(configurationAsset hash code release registry, 1)])
/-- Hypothesis under #741, not accepted law; authenticate full role and actual reference. -/
def configurationRead (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (registry : TokenId) (observation : ApplicationObservation)
    (output : ObservedOutput) : Bool :=
  configurationShape mutation hash code release registry output &&
  appGuard mutation .configurationReference
    (observation.referenceInputs.contains output.reference &&
      observation.referenceOutputs.contains output)
/-- Hypothesis under #741, not accepted law; expected approval derived from public datum. -/
def registrationAsset (hash : Hash) (code : Codec) (release : PublishedRelease)
    (data : RegistrationData) : TokenId :=
  registrationApproval hash code release data.registry data.key data.holdingAddress data.initialDatum data.deposit
/-- Hypothesis under #741, not accepted law; one exact same-output registration approval. -/
def registrationShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (data : RegistrationData) : Bool :=
  appGuard mutation .registrationShape (output.credential == release.applicationCredential &&
    exactAssets output [(registrationAsset hash code release data, 1)]) &&
  appGuard mutation .registrationFunding (data.deposit ≤ output.lovelace)
/-- Hypothesis under #741, not accepted law; live shape comes from this output's decode. -/
def liveShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (control : ProtectedControl) : Bool :=
  appGuard mutation .liveShape
    (output.credential == release.applicationCredential && quantity output control.activeAsset == 1) &&
  appGuard mutation .liveControl
    (control.activeAsset == activeAsset hash code control.registry control.key) &&
  appGuard mutation .liveDeposit (control.deposit ≤ output.lovelace)
/-- Hypothesis under #741, not accepted law; pending termination has empty datum and two tokens. -/
def terminationShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (registry : TokenId) (key : Key) : Bool :=
  appGuard mutation .terminationShape
    (output.credential == release.applicationCredential && output.datum == .empty &&
     exactAssets output [(activeAsset hash code registry key, 1),
       (terminationApproval hash code release registry key, 1)])
/-- Hypothesis under #741, not accepted law; actual source for a consuming redeemer. -/
def ApplicationAction.inputReference : ApplicationAction → Option OutRef
  | .bookTermination ref _ | .registrationFold ref _ | .ownerReclaim ref |
    .expiredCleanup ref | .terminationFold ref _ _ | .liveUpdate ref _ => some ref
  | _ => none
/-- Hypothesis under #741, not accepted law; a birth output cannot be credited twice. -/
def ApplicationAction.birthIndex : ApplicationAction → Option Nat
  | .configurationCreate _ _ index | .bookRegistration index | .bookTermination _ index => some index
  | _ => none
/-- Hypothesis under #741, not accepted law; source identity/quantity bind actual inputs. -/
def requestInput (mutation : AppMutation) (observation : ApplicationObservation)
    (reference : OutRef) (output : ObservedOutput) : Bool :=
  appGuard mutation .requestInput (output.reference == reference &&
    observation.assets.spent.count reference == 1 &&
    (observation.inputs.filter fun input => input.reference == reference).length == 1)
/-- Hypothesis under #741, not accepted law; sum all consumed approvals sharing a name. -/
def approvalsConsumed (observation : ApplicationObservation) (asset : TokenId) : Nat :=
  (observation.inputs.map fun output => quantity output asset).sum
/-- Hypothesis under #741, not accepted law; open burns grant no holding delivery. -/
def approvalBurned (mutation : AppMutation) (observation : ApplicationObservation) (asset : TokenId) : Bool :=
  appGuard mutation .approvalBurn
    (NoPin.mintQty observation.assets asset ≤ -(Int.ofNat (approvalsConsumed observation asset)))
/-- Hypothesis under #741, not accepted law; only the three clock parameters are read. -/
def registrationClock (mutation : AppMutation) (data : RegistrationData)
    (parameters : ApplicationParameters) (interval : Interval) : Bool :=
  appGuard mutation .registrationClock (nonemptyInterval interval && data.bookedAt == interval.upper &&
    interval.upper - interval.lower ≤ parameters.bookingWidth &&
    data.processDeadline == data.bookedAt + parameters.processTime &&
    data.reclaimEnd == data.processDeadline + parameters.retractTime)
/-- Hypothesis under #741, not accepted law; decoded initial control matches the request. -/
def initialControl (hash : Hash) (code : Codec) (decode : DecodeApplication) (data : RegistrationData) : Bool :=
  match decode data.initialDatum with
  | some (.live control _) => control.registry == data.registry && control.key == data.key &&
      control.controller == data.controller && control.deposit == data.deposit &&
      control.activeAsset == activeAsset hash code data.registry data.key
  | _ => false
/-- Hypothesis under #741, not accepted law; births derived from actual action/output data. -/
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
/-- Hypothesis under #741, not accepted law; net fresh mint equals total certified births. -/
def freshAsset (mutation : AppMutation) (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (observation : ApplicationObservation) (asset : TokenId) : Bool :=
  let births := observation.actions.filterMap (birth hash code decode release observation)
  appGuard mutation .freshApproval (NoPin.mintQty observation.assets asset == Int.ofNat (births.count asset) &&
    births.count asset > 0)
/-- Hypothesis under #741, not accepted law; same-tx genesis invocation, never S hardcoded into A. -/
def configurationCreate (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (registry : TokenId) (seed : OutRef)
    (output : ObservedOutput) (observation : ApplicationObservation) : Bool :=
  configurationShape mutation hash code release registry output &&
  appGuard mutation .configurationGenesis
    (registry.name == hash (code (.state seed)) && observation.assets.spent.count seed == 1 &&
      observation.assets.invoked.contains registry.policy && NoPin.mintQty observation.assets registry == 1) &&
  freshAsset mutation hash code decode release observation (configurationAsset hash code release registry)
/-- Hypothesis under #741, not accepted law; booking reads immutable public metadata and signature. -/
def registrationBook (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (output : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  registrationShape mutation hash code release output data &&
  appGuard mutation .registrationControl
    (data.holdingAddress == release.applicationCredential && initialControl hash code decode data) &&
  appGuard mutation .bookingSignature (observation.signers.contains data.controller) &&
  observation.referenceOutputs.any (fun configuration =>
    configurationRead mutation hash code release data.registry observation configuration &&
    match configuration.datum with
    | .configuration parameters => registrationClock mutation data parameters observation.interval
    | _ => false) &&
  freshAsset mutation hash code decode release observation (registrationAsset hash code release data)
/-- Hypothesis under #741, not accepted law; controller settles deposit at booking, not at fold. -/
def terminationBook (mutation : AppMutation) (hash : Hash) (code : Codec)
    (decode : DecodeApplication) (release : PublishedRelease) (input output : ObservedOutput)
    (control : ProtectedControl) (observation : ApplicationObservation) : Bool :=
  liveShape mutation hash code release input control &&
  appGuard mutation .bookingSignature (observation.signers.contains control.controller) &&
  terminationShape mutation hash code release output control.registry control.key &&
  freshAsset mutation hash code decode release observation
    (terminationApproval hash code release control.registry control.key)
/-- Hypothesis under #741, not accepted law; processing independently checks token and exact deposit. -/
def registrationSpend (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (action : ApplicationAction) (input : ObservedOutput)
    (data : RegistrationData) (observation : ApplicationObservation) : Bool :=
  registrationShape mutation hash code release input data &&
  approvalBurned mutation observation (registrationAsset hash code release data) &&
  match action with
  | .registrationFold _ index =>
    appGuard mutation .processingPhase (classifyPhase data observation.interval == .processing) &&
    appGuard mutation .registrationDelivery (match observation.outputs[index]? with
      | some holding => holding.credential == data.holdingAddress &&
          holding.datum == .application data.initialDatum && holding.lovelace == data.deposit &&
          quantity holding (activeAsset hash code data.registry data.key) == 1 &&
          NoPin.mintQty observation.assets (activeAsset hash code data.registry data.key) == 1
      | none => false)
  | .ownerReclaim _ =>
    appGuard mutation .reclaimPhase (classifyPhase data observation.interval == .reclaim &&
      observation.signers.contains data.controller)
  | .expiredCleanup _ =>
    appGuard mutation .cleanupPhase (classifyPhase data observation.interval == .cleanup)
  | _ => false
/-- Hypothesis under #741, not accepted law; no signature/time/value split on termination fold. -/
def terminationSpend (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (input : ObservedOutput) (registry : TokenId) (key : Key)
    (observation : ApplicationObservation) : Bool :=
  terminationShape mutation hash code release input registry key &&
  approvalBurned mutation observation (terminationApproval hash code release registry key) &&
  appGuard mutation .terminationActiveBurn
    (NoPin.mintQty observation.assets (activeAsset hash code registry key) == -1) &&
  appGuard mutation .terminationInvocation (observation.assets.invoked.contains registry.policy)
/-- Hypothesis under #741, not accepted law; pending cannot decode as a live update source. -/
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
/-- Hypothesis under #741, not accepted law; each successful leaf checks actual inputs/outputs. -/
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
/-- Hypothesis under #741, not accepted law; obligations generated from actual spending redeemers. -/
def requiredPayments (decode : DecodeApplication) (observation : ApplicationObservation) : List (Nat × Nat) :=
  observation.actions.filterMap fun action => do
    let reference ← action.inputReference
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .registration data ← decoded decode input | none
    match action with
    | .registrationFold .. => return (data.holdingAddress, data.deposit)
    | .ownerReclaim .. => return (data.refundAddress, input.lovelace)
    | .expiredCleanup .. => return (data.refundAddress, data.deposit)
    | _ => none
/-- Hypothesis under #741, not accepted law; one donation cannot settle two protected deposits. -/
def requiredTreasury (decode : DecodeApplication) (observation : ApplicationObservation) : Nat :=
  (observation.actions.filterMap fun action => do
    let .bookTermination reference _ := action | none
    let input ← observation.inputs.find? (fun output => output.reference == reference)
    let .live control _ ← decoded decode input | none
    return control.deposit).sum
/-- Hypothesis under #741, not accepted law; each indexed output is credited once per address. -/
def paidTo (outputs : List ObservedOutput) (address : Nat) : Nat :=
  ((outputs.filter fun output => output.credential == address).map (·.lovelace)).sum
/-- Hypothesis under #741, not accepted law; aggregate exact treasury and address-grouped floors. -/
def requestValueSplit (mutation : AppMutation) (decode : DecodeApplication)
    (observation : ApplicationObservation) : Bool :=
  let requirements := requiredPayments decode observation
  appGuard mutation .moneyOutputs (requirements.all fun entry =>
    ((requirements.filter fun other => other.1 == entry.1).map (·.2)).sum ≤
      paidTo observation.outputs entry.1) &&
  appGuard mutation .moneyTreasury (observation.donation == requiredTreasury decode observation)
/-- Hypothesis under #741, not accepted law; immutable configuration has no consuming handler. -/
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

end NoPin.ApplicationRequests
