import SingularApplicationHeld.Core

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/

namespace SingularApplicationHeld
open Singular Lean

/-- immutable live ownership/deposit. -/
structure ProtectedControl where
  registry : TokenId
  activeAsset : TokenId
  key : Key
  controller : Nat
  deposit : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- publicly decoded pending registration. -/
structure RegistrationData where
  registry : TokenId
  key : Key
  controller : Nat
  refundAddress : Nat
  holdingAddress : Address
  initialDatum : Nat
  deposit : Nat
  bookedAt : Nat
  processDeadline : Nat
  reclaimEnd : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- live and pending decode categories disjoint. -/
inductive ApplicationDatum where
  | registration (data : RegistrationData)
  | live (control : ProtectedControl) (payload : Nat)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- same-output public decoding, not hash inversion. -/
abbrev DecodeApplication := Nat → Option ApplicationDatum

/-- decode the observed datum of this output. -/
def decoded (decode : DecodeApplication) (output : ObservedOutput) : Option ApplicationDatum :=
  match output.datum with | .application data => decode data | _ => none

/-- atomic application guard sites. -/
inductive AppGuard where
  | configurationShape | configurationGenesis | configurationReference
  | registrationShape | registrationControl | registrationClock | registrationFunding
  | bookingSignature | terminationShape | liveShape | liveControl | liveDeposit
  | requestInput | approvalBurn | freshApproval | processingPhase | reclaimPhase | cleanupPhase
  | registrationDelivery | terminationActiveBurn | terminationInvocation
  | updateControl | updateAssets | updateDeposit | inputCoverage | birthCoverage | moneyOutputs | moneyTreasury
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- one application decision site only. -/
inductive AppMutation where
  | none | flip (site : AppGuard)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- selector isolation. -/
def appGuard (mutation : AppMutation) (site : AppGuard) (condition : Bool) : Bool :=
  if mutation == .flip site then !condition else condition

/-- an actual nonempty interval. -/
def nonemptyInterval (interval : Interval) : Bool := interval.lower < interval.upper

/-- three disjoint phases, straddles refuse. -/
inductive RegistrationPhase where
  | processing | reclaim | cleanup | refused
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- no trie/key-exists rejection path. -/
def classifyPhase (data : RegistrationData) (interval : Interval) : RegistrationPhase :=
  if !nonemptyInterval interval then .refused
  else if interval.upper ≤ data.processDeadline then .processing
  else if data.processDeadline ≤ interval.lower && interval.upper ≤ data.reclaimEnd then .reclaim
  else if data.reclaimEnd ≤ interval.lower then .cleanup else .refused

/-- exact positive asset multiset. -/
def exactAssets (output : ObservedOutput) (expected : List (TokenId × Nat)) : Bool :=
  let support := (output.assets ++ expected).map (·.1)
  support.all (fun asset => quantity output asset ==
    ((expected.filter fun entry => entry.1 == asset).map (·.2)).sum)

/-- expected approval derived from public datum. -/
def registrationAsset (hash : Hash) (code : Codec) (release : PublishedRelease)
    (data : RegistrationData) : TokenId :=
  registrationApproval hash code release data.registry data.key data.holdingAddress data.initialDatum data.deposit

/-- one exact same-output registration approval. -/
def registrationShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (data : RegistrationData) : Bool :=
  appGuard mutation .registrationShape (output.credential == release.applicationCredential &&
    exactAssets output [(registrationAsset hash code release data, 1)]) &&
  appGuard mutation .registrationFunding (data.deposit ≤ output.lovelace)

/-- pending termination has empty datum and two tokens. -/
def terminationShape (mutation : AppMutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (output : ObservedOutput) (registry : TokenId) (key : Key) : Bool :=
  appGuard mutation .terminationShape
    (output.credential == release.applicationCredential && output.datum == .empty &&
     exactAssets output [(activeAsset hash code registry key, 1),
       (terminationApproval hash code release registry key, 1)])

end SingularApplicationHeld
