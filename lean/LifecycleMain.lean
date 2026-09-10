import Singular.NamingLifecycleAudit
import Singular.NamingWireAudit

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
  before : InitializationState
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
  .recover 3 4 aliceKey freshControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey) recoveredFixture
    { requiredSigners := [freshControllerAddress] }

def missingRecoverySigner : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey) recoveredFixture {}

def replayRecovery : LifecycleAction :=
  .recover 4 5 aliceKey nextControllerAddress recoveredState.registry.config.registry
    (representative recoveredState.registry aliceKey) recoveredFixture
    { requiredSigners := [nextControllerAddress] }

def oldControllerMaintenance : LifecycleAction :=
  .maintain 4 5 aliceKey { recoveredFixture with paymentDestination := none }
    { requiredSigners := [controllerAddress] }

def forgedRecovery : LifecycleAction :=
  .recover 3 4 aliceKey nonFixtureControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey) forgedRecoveryFixture
    { requiredSigners := [nonFixtureControllerAddress] }

def lifecycleStepRows : List LifecycleStepRow := [
  { id := "LC01-cancellation-stored-refund-accepts", before := cancellationPending,
    action := .cancelClaim 1 demoRefundAddress },
  { id := "LC02-cancellation-redirect-refused", before := cancellationPending,
    action := .cancelClaim 1 (demoRefundAddress + 1) },
  { id := "LC03-insert-attestation-cancellation-refused", before := claimedOnce,
    action := .cancelClaim 1 demoRefundAddress },
  { id := "LC04-folded-claim-cancellation-refused", before := activeOnce,
    action := .cancelClaim 1 demoRefundAddress },
  { id := "LC06-cancellation-replay-refused", before := cancelledClaim,
    action := .cancelClaim 1 demoRefundAddress },
  { id := "LM01-maintenance-accepts", before := activeOnce, action := maintainClear },
  { id := "LM02-maintenance-unauthorized-refused", before := activeOnce,
    action := .maintain 3 4 aliceKey clearedFixture {} },
  { id := "LM03-maintenance-field-tamper-refused", before := activeOnce, action := destinationTamper },
  { id := "LM04-maintenance-quorum-alteration-refused", before := activeOnce,
    action := maintainQuorumTamper },
  { id := "LR01-recovery-accepts", before := activeOnce, action := recoverWithNext },
  { id := "LR02-wrong-reveal-refused", before := activeOnce, action := wrongReveal },
  { id := "LR03-missing-recovery-signer-refused", before := activeOnce, action := missingRecoverySigner },
  { id := "LR04-recovery-replay-refused", before := recoveredState, action := replayRecovery },
  { id := "LR05-old-controller-refused", before := recoveredState, action := oldControllerMaintenance },
  { id := "LR06-forged-public-digest-refused", before := activeOnce, action := forgedRecovery },
  { id := "LR07-wrong-payment-key-signer-refused", before := activeOnce,
    action := recoverWrongPaymentKeySigner },
  { id := "LR08-missing-fresh-commitment-refused", before := activeOnce,
    action := recoverMissingFreshCommitment },
  { id := "LR09-representative-tamper-refused", before := activeOnce,
    action := recoverRepresentativeTamper },
  { id := "LR10-registry-tamper-refused", before := activeOnce,
    action := recoverRegistryTamper },
  { id := "LR11-quorum-tamper-refused", before := activeOnce,
    action := recoverQuorumTamper },
  { id := "LT01-controller-retirement-accepts", before := activeOnce, action := retirementByController },
  { id := "LT02-quorum-retirement-accepts", before := activeOnce, action := retirementByQuorum },
  { id := "LT03-insufficient-quorum-refused", before := activeOnce, action := retirementInsufficient },
  { id := "LT04-retirement-completes", before := retirementPending,
    action := .completeRetirement 4 },
  { id := "LT05-quorum-control-takeover-refused", before := activeOnce,
    action := quorumControlTakeover },
  { id := "LT06-quorum-payment-redirection-refused", before := activeOnce,
    action := quorumPaymentRedirection },
  { id := "LT07-retirement-withdrawal-refused", before := retirementPending,
    action := .withdrawRetirement 4 },
  { id := "LT08-wrong-retirement-custody-refused", before := activeOnce,
    action := retirementWrongCustody },
  { id := "LT09-retirement-replay-refused", before := retirementPending,
    action := retirementByController }]

def lifecycleResolutionRows : List LifecycleResolutionRow := [
  { id := "LO01-retirement-pending-visible", before := retirementPending,
    spelling := "alice", authenticated := true },
  { id := "LO02-retirement-over-visible", before := retirementOver,
    spelling := "alice", authenticated := true }]

def lifecycleInitializationRows : List LifecycleInitializationRow := [
  { id := "LI01-canonical-initialization-accepts", binding := namingConsumerBinding,
    before := {}, attempt := canonicalInitialization },
  { id := "LI02-alternate-seed-refused", binding := namingConsumerBinding,
    before := {}, attempt := alternateSeedInitialization },
  { id := "LI03-second-seed-rival-registry-refused", binding := namingConsumerBinding,
    before := {}, attempt := rivalRegistryInitialization },
  { id := "LI04-substituted-registry-refused", binding := namingConsumerBinding,
    before := {}, attempt := substitutedRegistryInitialization },
  { id := "LI05-substituted-policy-refused", binding := namingConsumerBinding,
    before := {}, attempt := substitutedPolicyInitialization },
  { id := "LI06-repeated-canonical-seed-refused", binding := namingConsumerBinding,
    before := canonicalInitializedState, attempt := canonicalInitialization },
  { id := "LI07-substituted-representative-policy-refused", binding := namingConsumerBinding,
    before := {}, attempt := substitutedRepresentativeInitialization },
  { id := "LI08-substituted-validator-script-refused", binding := namingConsumerBinding,
    before := {}, attempt := substitutedValidatorInitialization }]

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
  | .recover source successor key revealed candidateRegistry candidateRepresentative candidate witnesses =>
      Json.mkObj [("recover", Json.mkObj [("source", toJson source),
        ("successor", toJson successor), ("key", toJson key),
        ("revealed", toJson revealed), ("candidateRegistry", toJson candidateRegistry),
        ("candidateRepresentative", toJson candidateRepresentative), ("candidate", toJson candidate),
        ("witnesses", witnessesJson witnesses)])]
  | .retire source requestId key request route witnesses =>
      Json.mkObj [("retire", Json.mkObj [("source", toJson source),
        ("requestId", toJson requestId), ("key", toJson key),
        ("request", toJson request), ("route", routeJson route),
        ("witnesses", witnessesJson witnesses)])]
  | .cancelClaim requestId refundAddress =>
      Json.mkObj [("cancelClaim", Json.mkObj [("requestId", toJson requestId),
        ("refundAddress", toJson refundAddress)])]
  | .completeRetirement requestId =>
      Json.mkObj [("completeRetirement", Json.mkObj [("requestId", toJson requestId)])]
  | .withdrawRetirement requestId =>
      Json.mkObj [("withdrawRetirement", Json.mkObj [("requestId", toJson requestId)])]

def lifecycleVerdictJson (result : Except String NamingResult) : Json :=
  match result with
  | .ok value => Json.mkObj [("accepted", toJson true), ("value", toJson value)]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def initializationVerdictJson (result : Except String Unit) : Json :=
  match result with
  | .ok _ => Json.mkObj [("accepted", toJson true)]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def initializationStateVerdictJson (result : Except String InitializationState) : Json :=
  match result with
  | .ok state => Json.mkObj [("accepted", toJson true), ("state", toJson state)]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def queueVerdictJson (result : Except String NamingQueueOutcome) : Json :=
  match result with
  | .ok value => Json.mkObj [("accepted", toJson true), ("requestId", toJson value.requestId),
      ("value", Json.mkObj [("state", toJson value.state)])]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def stepRowJson (row : LifecycleStepRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before),
    ("action", lifecycleActionJson row.action),
    ("executingWitness", toJson (lifecycleExecutingWitness row.action)),
    ("result", lifecycleVerdictJson (lifecycleStep fixtureHasher row.before row.action))]

def resolutionRowJson (row : LifecycleResolutionRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before),
    ("spelling", toJson row.spelling), ("authenticated", toJson row.authenticated),
    ("executingWitness", toJson ({ authenticatedRead := row.authenticated } : LifecycleExecutionWitness)),
    ("expected", match spellingKey row.spelling with
      | none => Json.mkObj [("error", toJson "unknown-spelling")]
      | some key => match namingResolve row.before key row.authenticated with
      | .ok value => toJson value
      | .error reason => Json.mkObj [("error", toJson reason)])]

def initializationRowJson (row : LifecycleInitializationRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("binding", toJson row.binding),
    ("before", toJson row.before), ("attempt", toJson row.attempt),
    ("executingWitness", toJson (initializationExecutingWitness row.binding row.before row.attempt)),
    ("shapeResult", initializationVerdictJson (initializeConsumer row.binding row.attempt)),
    ("result", initializationStateVerdictJson
      (initializeConsumerTransition row.binding row.before row.attempt))]

def registrationRowJson (row : LifecycleRegistrationRow) : Json :=
  let queue := namingQueue row.before row.spelling row.fixture row.accepted
  let fold := queue.bind fun value => namingFoldRequest value.state value.requestId
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before),
    ("spelling", toJson row.spelling), ("fixture", toJson row.fixture),
    ("accepted", toJson row.accepted), ("queueResult", queueVerdictJson queue),
    ("executingWitness", toJson ({ applicationMint := true, nativeSpend := true, representativeMint := true } : LifecycleExecutionWitness)),
    ("foldResult", lifecycleVerdictJson fold)]

def namingWireRows : List Json :=
  let encoded := encodeNamingDatum aliceFixture
  let decoded := decodeNamingDatum encoded
  let encodedBytes := serialiseNamingDatum aliceFixture
  let decodedBytes := deserialiseNamingDatum expectedNamingDatumBytes
  [Json.mkObj [("id", toJson "WD01-four-field-roundtrip"),
      ("fixture", toJson aliceFixture), ("encoded", toJson encoded),
      ("decoded", toJson decoded), ("reencoded", toJson (decoded.map encodeNamingDatum)),
      ("encodedBytes", toJson encodedBytes), ("expectedBytes", toJson expectedNamingDatumBytes),
      ("decodedBytes", toJson decodedBytes),
      ("reencodedBytes", toJson (decodedBytes.map serialiseNamingDatum)),
      ("malformedBytes", toJson malformedNamingDatumBytes),
      ("malformedResult", toJson (deserialiseNamingDatum malformedNamingDatumBytes)),
      ("shape", toJson (namingDatumShape encoded))],
    Json.mkObj [("id", toJson "WD02-datum-hash-refused"),
      ("attachment", Json.mkObj [("datumHash", toJson ([1, 2, 3] : List Nat))]),
      ("result", toJson (extractNamingDatum (.datumHash [1, 2, 3])))],
    Json.mkObj [("id", toJson "WD03-two-destinations-refused"),
      ("encoded", toJson twoDestinationDatum),
      ("result", toJson (decodeNamingDatum twoDestinationDatum))]]

end Singular

open Lean Singular

def main : IO Unit := do
  let json := Json.mkObj [("schema", toJson "singular-naming-lifecycle-corpus-v1"),
    ("steps", toJson (lifecycleStepRows.map stepRowJson)),
    ("resolutions", toJson (lifecycleResolutionRows.map resolutionRowJson)),
    ("initializations", toJson (lifecycleInitializationRows.map initializationRowJson)),
    ("registrations", toJson (lifecycleRegistrationRows.map registrationRowJson)),
    ("wire", toJson namingWireRows)]
  (← IO.getStdout).putStrLn json.compress
