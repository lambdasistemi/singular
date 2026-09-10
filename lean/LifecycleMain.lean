import Singular.NamingLifecycleAudit

/-! Lean-owned executable lifecycle corpus. Rows contain inputs and results
computed by the model itself. Consumers replay these bytes through the public
adapter; they do not maintain a second expected-result list. The concrete
`fixtureHasher` keeps this finite evidence conditional on the trusted hash
boundary and makes no cryptographic-correctness claim. -/
namespace Singular
open Lean

structure LifecycleStepRow where
  id : String
  before : NamingState
  action : LifecycleAction

structure LifecycleResolutionRow where
  id : String
  before : NamingState
  spelling : String
  authenticated : Bool

structure LifecycleInitializationRow where
  id : String
  binding : ConsumerBinding
  attempt : InitializationAttempt

structure LifecycleRegistrationRow where
  id : String
  before : NamingState
  spelling : String
  fixture : NamingFixture
  accepted : Bool

def recoveredState : NamingState := afterLifecycle activeOnce recoverWithNext

def destinationTamper : LifecycleAction :=
  .maintain 3 4 aliceKey
    { clearedFixture with nextControlCommitment := freshControllerCommitment }
    { requiredSigners := [controllerAddress] }

def wrongReveal : LifecycleAction :=
  .recover 3 4 aliceKey freshControllerAddress recoveredFixture
    { requiredSigners := [freshControllerAddress] }

def missingRecoverySigner : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress recoveredFixture {}

def replayRecovery : LifecycleAction :=
  .recover 4 5 aliceKey nextControllerAddress recoveredFixture
    { requiredSigners := [nextControllerAddress] }

def oldControllerMaintenance : LifecycleAction :=
  .maintain 4 5 aliceKey { recoveredFixture with paymentDestination := none }
    { requiredSigners := [controllerAddress] }

def forgedRecovery : LifecycleAction :=
  .recover 3 4 aliceKey nonFixtureControllerAddress forgedRecoveryFixture
    { requiredSigners := [nonFixtureControllerAddress] }

def lifecycleStepRows : List LifecycleStepRow := [
  { id := "LM01-maintenance-accepts", before := activeOnce, action := maintainClear },
  { id := "LM02-maintenance-unauthorized-refused", before := activeOnce,
    action := .maintain 3 4 aliceKey clearedFixture {} },
  { id := "LM03-maintenance-field-tamper-refused", before := activeOnce, action := destinationTamper },
  { id := "LR01-recovery-accepts", before := activeOnce, action := recoverWithNext },
  { id := "LR02-wrong-reveal-refused", before := activeOnce, action := wrongReveal },
  { id := "LR03-missing-recovery-signer-refused", before := activeOnce, action := missingRecoverySigner },
  { id := "LR04-recovery-replay-refused", before := recoveredState, action := replayRecovery },
  { id := "LR05-old-controller-refused", before := recoveredState, action := oldControllerMaintenance },
  { id := "LR06-forged-public-digest-refused", before := activeOnce, action := forgedRecovery },
  { id := "LT01-controller-retirement-accepts", before := activeOnce, action := retirementByController },
  { id := "LT02-quorum-retirement-accepts", before := activeOnce, action := retirementByQuorum },
  { id := "LT03-insufficient-quorum-refused", before := activeOnce, action := retirementInsufficient },
  { id := "LT04-retirement-completes", before := retirementPending,
    action := .completeRetirement 4 }]

def lifecycleResolutionRows : List LifecycleResolutionRow := [
  { id := "LO01-retirement-pending-visible", before := retirementPending,
    spelling := "alice", authenticated := true },
  { id := "LO02-retirement-over-visible", before := retirementOver,
    spelling := "alice", authenticated := true }]

def lifecycleInitializationRows : List LifecycleInitializationRow := [
  { id := "LI01-canonical-initialization-accepts", binding := namingConsumerBinding,
    attempt := canonicalInitialization },
  { id := "LI02-alternate-seed-refused", binding := namingConsumerBinding,
    attempt := alternateSeedInitialization }]

def lifecycleRegistrationRows : List LifecycleRegistrationRow := [
  { id := "LX01-re-registration-after-over-refused", before := retirementOver,
    spelling := "alice", fixture := aliceFixture, accepted := true }]

def witnessesJson (witnesses : LifecycleWitnesses) : Json :=
  Json.mkObj [("requiredSigners", toJson witnesses.requiredSigners),
    ("quorumSigners", toJson witnesses.quorumSigners)]

def routeJson : RetirementRoute → Json
  | .controller => toJson "controller"
  | .quorum => toJson "quorum"

def lifecycleActionJson : LifecycleAction → Json
  | .maintain source successor key candidate witnesses =>
      Json.mkObj [("maintain", Json.mkObj [("source", toJson source),
        ("successor", toJson successor), ("key", toJson key),
        ("candidate", toJson candidate), ("witnesses", witnessesJson witnesses)])]
  | .recover source successor key revealed candidate witnesses =>
      Json.mkObj [("recover", Json.mkObj [("source", toJson source),
        ("successor", toJson successor), ("key", toJson key),
        ("revealed", toJson revealed), ("candidate", toJson candidate),
        ("witnesses", witnessesJson witnesses)])]
  | .retire source requestId key request route witnesses =>
      Json.mkObj [("retire", Json.mkObj [("source", toJson source),
        ("requestId", toJson requestId), ("key", toJson key),
        ("request", toJson request), ("route", routeJson route),
        ("witnesses", witnessesJson witnesses)])]
  | .completeRetirement requestId =>
      Json.mkObj [("completeRetirement", Json.mkObj [("requestId", toJson requestId)])]

def lifecycleVerdictJson (result : Except String NamingResult) : Json :=
  match result with
  | .ok value => Json.mkObj [("accepted", toJson true), ("value", toJson value)]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def initializationVerdictJson (result : Except String Unit) : Json :=
  match result with
  | .ok _ => Json.mkObj [("accepted", toJson true)]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def queueVerdictJson (result : Except String NamingQueueOutcome) : Json :=
  match result with
  | .ok value => Json.mkObj [("accepted", toJson true), ("requestId", toJson value.requestId),
      ("value", Json.mkObj [("state", toJson value.state)])]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def stepRowJson (row : LifecycleStepRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before),
    ("action", lifecycleActionJson row.action),
    ("result", lifecycleVerdictJson (lifecycleStep fixtureHasher row.before row.action))]

def resolutionRowJson (row : LifecycleResolutionRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before),
    ("spelling", toJson row.spelling), ("authenticated", toJson row.authenticated),
    ("expected", match spellingKey row.spelling with
      | none => Json.mkObj [("error", toJson "unknown-spelling")]
      | some key => match namingResolve row.before key row.authenticated with
      | .ok value => toJson value
      | .error reason => Json.mkObj [("error", toJson reason)])]

def initializationRowJson (row : LifecycleInitializationRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("binding", toJson row.binding),
    ("attempt", toJson row.attempt),
    ("result", initializationVerdictJson (initializeConsumer row.binding row.attempt))]

def registrationRowJson (row : LifecycleRegistrationRow) : Json :=
  let queue := namingQueue row.before row.spelling row.fixture row.accepted
  let fold := queue.bind fun value => namingFoldRequest value.state value.requestId
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before),
    ("spelling", toJson row.spelling), ("fixture", toJson row.fixture),
    ("accepted", toJson row.accepted), ("queueResult", queueVerdictJson queue),
    ("foldResult", lifecycleVerdictJson fold)]

end Singular

open Lean Singular

def main : IO Unit := do
  let json := Json.mkObj [("schema", toJson "singular-naming-lifecycle-corpus-v1"),
    ("steps", toJson (lifecycleStepRows.map stepRowJson)),
    ("resolutions", toJson (lifecycleResolutionRows.map resolutionRowJson)),
    ("initializations", toJson (lifecycleInitializationRows.map initializationRowJson)),
    ("registrations", toJson (lifecycleRegistrationRows.map registrationRowJson))]
  (← IO.getStdout).putStrLn json.compress
