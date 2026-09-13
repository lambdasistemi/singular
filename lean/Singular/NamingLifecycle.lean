import Singular.Naming

/-! Lifecycle and source-bound consumer model for the naming profile.
The only mutable application datum is `NamingRecord.fixture`; every accepted
maintenance or recovery consumes its representative-bearing application UTxO
and installs one successor. This remains finite model evidence, not compiled
script or ledger interoperability evidence. -/
namespace Singular
open Lean

def nextControlDomain : List Nat :=
  "singular/naming/next-control/v1".toUTF8.toList.map UInt8.toNat

/-- The explicit adapter contract at the model/cryptography boundary. Lean fixes
the complete preimage and output shape; the executable consumer supplies and
checks the BLAKE2b-256 implementation for every supported canonical address. -/
structure NextControlHashContract where
  algorithm : String
  domain : List Nat
  separator : Nat
  digestBytes : Nat
  deriving Repr, BEq, DecidableEq, ToJson

def nextControlHashContract : NextControlHashContract :=
  { algorithm := "BLAKE2b-256", domain := nextControlDomain, separator := 0, digestBytes := 32 }

def nextControlHashInput (address : NamingAddress) : List Nat :=
  nextControlHashContract.domain ++ [nextControlHashContract.separator] ++ address.bytes

/-- Trusted executable adapter boundary. The model invokes this function; a
caller cannot supply the digest checked by recovery. Proofs about an arbitrary
adapter are conditional on the adapter implementing `nextControlHashContract`.
The browser gate checks that implementation against an independent oracle. -/
abbrev NextControlHasher := NamingAddress → NextCommitment

def wrongDomainCommitment : NextCommitment :=
  { digest := [102, 167, 149, 152, 220, 195, 145, 245, 46, 220, 238, 211, 46, 4, 208, 40,
    206, 250, 110, 82, 65, 224, 146, 63, 163, 48, 134, 161, 196, 163, 28, 110] }

/-- A supported payment-key address intentionally outside all naming fixtures,
used to exercise forged recovery at the model and adapter boundaries. -/
def nonFixtureControllerAddress : NamingAddress :=
  { bytes := 97 :: List.range' 141 28, form := .enterprise, network := 1,
    paymentCredential := .paymentKey, paymentHash := List.range' 141 28 }

structure LifecycleWitnesses where
  requiredSigners : List NamingAddress := []
  quorumSigners : List (List Nat) := []
  deriving Repr, BEq, DecidableEq, ToJson

/-- The actual boundary witness exercised by one lifecycle example. This is
derived from the action, rather than narrated beside it. -/
structure LifecycleExecutionWitness where
  applicationMint : Bool := false
  applicationSpend : Bool := false
  nativeSpend : Bool := false
  representativeMint : Bool := false
  seedSpend : Bool := false
  authenticatedRead : Bool := false
  requiredSigners : List NamingAddress := []
  quorumSigners : List (List Nat) := []
  deriving Repr, BEq, DecidableEq, ToJson

inductive RetirementRoute where
  | controller | quorum
  deriving Repr, BEq, DecidableEq, ToJson

inductive LifecycleAction where
  | maintain (source successor key : Nat) (candidate : NamingFixture)
      (witnesses : LifecycleWitnesses)
  | recover (source successor key : Nat) (revealed : NamingAddress)
      (candidateRegistry : Nat) (candidateRepresentative : Representative)
      (candidate : NamingFixture) (witnesses : LifecycleWitnesses)
  | retire (source requestId key : Nat) (request : Request)
      (route : RetirementRoute) (witnesses : LifecycleWitnesses)
  | cancelClaim (requestId refundAddress : Nat)
  | completeRetirement (requestId : Nat)
  | withdrawRetirement (requestId : Nat)
  deriving Repr, BEq, DecidableEq, ToJson

def lifecycleExecutingWitness : LifecycleAction → LifecycleExecutionWitness
  | .maintain _ _ _ _ witnesses =>
      { applicationSpend := true, requiredSigners := witnesses.requiredSigners,
        quorumSigners := witnesses.quorumSigners }
  | .recover _ _ _ _ _ _ _ witnesses =>
      { applicationSpend := true, requiredSigners := witnesses.requiredSigners,
        quorumSigners := witnesses.quorumSigners }
  | .retire _ _ _ _ _ witnesses =>
      { applicationSpend := true, requiredSigners := witnesses.requiredSigners,
        quorumSigners := witnesses.quorumSigners }
  | .cancelClaim _ _ => { nativeSpend := true }
  | .completeRetirement _ => { nativeSpend := true, representativeMint := true }
  | .withdrawRetirement _ => {}

def namingRecord (state : NamingState) (key : Nat) : Except String NamingRecord :=
  requireSome (state.records.find? (fun record => record.key == key)) "naming-record-unavailable"

def recordApplication (state : NamingState) (record : NamingRecord) : Except String ApplicationUTxO :=
  requireSome (state.registry.applications.find? (fun output => output.id == record.outputId))
    "application-unavailable"

def controllerAuthorized (fixture : NamingFixture) (witnesses : LifecycleWitnesses) : Bool :=
  paymentKeyAddress fixture.controlAddress && witnesses.requiredSigners.contains fixture.controlAddress

def quorumAuthorized (fixture : NamingFixture) (witnesses : LifecycleWitnesses) : Bool :=
  let signed := fixture.retirementQuorum.members.filter
    (fun member => witnesses.quorumSigners.contains member)
  fixture.retirementQuorum.threshold > 0 &&
    signed.eraseDups.length >= fixture.retirementQuorum.threshold

def replaceLifecycleOutput (state : NamingState) (record : NamingRecord)
    (application : ApplicationUTxO) (successor : Nat) (fixture : NamingFixture) : NamingState :=
  let successorOutput : ApplicationUTxO := { application with id := successor }
  let registry := consume state.registry record.outputId
  { state with
    registry := { registry with
      applications := successorOutput :: registry.applications,
      used := successor :: registry.used },
    records := { record with outputId := successor, fixture := fixture } ::
      state.records.filter (fun other => other.key != record.key) }

def validateLifecycleOutput (state : NamingState) (record : NamingRecord)
    (application : ApplicationUTxO) (source successor : Nat) : Except String Unit := do
  if source != record.outputId || application.id != source || application.key != record.key ||
      application.output.representative != record.representative || application.output.quantity != 1 then
    throw "application-custody"
  if !fresh state.registry successor then throw "utxo-id-reuse"

def maintainDestination (state : NamingState) (source successor key : Nat)
    (candidate : NamingFixture) (witnesses : LifecycleWitnesses) : Except String NamingResult := do
  let record ← namingRecord state key
  let application ← recordApplication state record
  validateLifecycleOutput state record application source successor
  if !controllerAuthorized record.fixture witnesses then throw "controller-signature"
  if candidate.controlAddress != record.fixture.controlAddress ||
      candidate.nextControlCommitment != record.fixture.nextControlCommitment ||
      candidate.retirementQuorum != record.fixture.retirementQuorum then
    throw "destination-field-preservation"
  if !wellFormedFixture candidate then throw "invalid-fixture"
  return { state := replaceLifecycleOutput state record application successor candidate }

def recoverController (hasher : NextControlHasher) (state : NamingState) (source successor key : Nat)
    (revealed : NamingAddress) (candidateRegistry : Nat)
    (candidateRepresentative : Representative) (candidate : NamingFixture)
    (witnesses : LifecycleWitnesses) : Except String NamingResult := do
  let record ← namingRecord state key
  let application ← recordApplication state record
  validateLifecycleOutput state record application source successor
  if candidateRegistry != state.registry.config.registry then throw "recovery-registry"
  if candidateRepresentative != record.representative then throw "recovery-representative"
  if !paymentKeyAddress revealed then throw "recovery-payment-key"
  let computed := hasher revealed
  if !wellFormedCommitment computed then throw "recovery-hash-shape"
  if computed != record.fixture.nextControlCommitment then
    throw "recovery-commitment"
  if !witnesses.requiredSigners.contains revealed then throw "recovery-required-signer"
  if candidate.controlAddress != revealed ||
      candidate.paymentDestination != record.fixture.paymentDestination ||
      candidate.retirementQuorum != record.fixture.retirementQuorum then
    throw "recovery-field-preservation"
  if !wellFormedCommitment candidate.nextControlCommitment ||
      candidate.nextControlCommitment == record.fixture.nextControlCommitment then
    throw "recovery-fresh-commitment"
  if !wellFormedFixture candidate then throw "invalid-fixture"
  return { state := replaceLifecycleOutput state record application successor candidate }

def retirementRequest (state : NamingState) (record : NamingRecord)
    (application : ApplicationUTxO) (requestId : Nat) : Request :=
  let proposal : Proposal :=
    { registry := state.registry.config.registry
      key := record.key
      applicationPolicy := state.registry.config.applicationPolicy
      refundAddress := 0
      initial := application.output
      scope := [(entry state.registry record.key).incarnation] }
  { id := requestId, operation := .update, proposal := proposal, token := none,
    held := some record.representative, destination := state.registry.config.requestAddress,
    authenticatedOrigin := true }

def beginRetirement (state : NamingState) (source requestId key : Nat) (request : Request)
    (route : RetirementRoute) (witnesses : LifecycleWitnesses) : Except String NamingResult := do
  let record ← namingRecord state key
  let application ← recordApplication state record
  validateLifecycleOutput state record application source requestId
  let authorized := match route with
    | .controller => controllerAuthorized record.fixture witnesses
    | .quorum => quorumAuthorized record.fixture witnesses
  if !authorized then throw "retirement-authorization"
  if request != retirementRequest state record application requestId then
    throw "retirement-request"
  let result ← step state.registry (.release source request
    { source := source, request := request, accepted := true }
    { applicationSpend := true })
  let nextState : NamingState := { state with registry := result.state, records := state.records.filter (fun other => other.key != key) }
  return { state := nextState, logical := result.logical }

def finishRetirement (state : NamingState) (requestId : Nat) : Except String NamingResult := do
  let request ← requireSome (state.registry.requests.find? (fun candidate => candidate.id == requestId))
    "request-unavailable"
  if request.operation != .update then throw "retirement-update-only"
  let result ← step state.registry (.fold [{ request := requestId }]
    [{ asset := representative state.registry request.proposal.key, quantity := -1 }]
    [] { nativeSpend := true, representativeMint := true, consumerWithdraw := true })
  return { state := { state with registry := result.state }, logical := result.logical }

def refuseRetirementWithdrawal (state : NamingState) (requestId : Nat) : Except String NamingResult := do
  let request ← requireSome (state.registry.requests.find? (fun candidate => candidate.id == requestId))
    "request-unavailable"
  if request.operation != .update then throw "retirement-update-only"
  throw "retirement-withdrawal-refused"

/-- Cancellation copies the refund address committed by the queued Insert.
The refund value is deliberately fixed to zero in this naming lifecycle model:
economic terms are outside the operator ruling represented by these rows. -/
def cancellationRefund (refundAddress : Nat) : Refund :=
  { destination := refundAddress, value := 0 }

def cancellationAsset (state : NamingState) (requestId refundAddress : Nat) : Asset :=
  { policy := state.registry.config.applicationPolicy,
    name := .withdraw state.registry.config.registry requestId
      (cancellationRefund refundAddress) }

def cancelNamingClaim (state : NamingState) (requestId refundAddress : Nat) :
    Except String NamingResult := do
  let request ← requireSome
    (state.registry.requests.find? (fun candidate => candidate.id == requestId))
    "request-unavailable"
  if request.operation != .insert then throw "cancellation-insert-only"
  if refundAddress != request.proposal.refundAddress then
    throw "withdraw-refund-address"
  let result ← step state.registry (.withdraw requestId
    (cancellationAsset state requestId refundAddress)
    (cancellationRefund refundAddress) { nativeSpend := true })
  let nextState : NamingState :=
    { registry := result.state
      claims := state.claims.filter (fun claim => claim.requestId != requestId)
      records := state.records }
  return { state := nextState, logical := result.logical }

def lifecycleStep (hasher : NextControlHasher) (state : NamingState) : LifecycleAction → Except String NamingResult
  | .maintain source successor key candidate witnesses =>
      maintainDestination state source successor key candidate witnesses
  | .recover source successor key revealed candidateRegistry candidateRepresentative candidate witnesses =>
      recoverController hasher state source successor key revealed candidateRegistry
        candidateRepresentative candidate witnesses
  | .retire source requestId key request route witnesses =>
      beginRetirement state source requestId key request route witnesses
  | .cancelClaim requestId refundAddress =>
      cancelNamingClaim state requestId refundAddress
  | .completeRetirement requestId => finishRetirement state requestId
  | .withdrawRetirement requestId => refuseRetirementWithdrawal state requestId

/-! Design-time source binding for the consumer boundary. -/
def cardanoKeriRevision : String := "14a64a4681d3e429fab5877062b5c476c2a4bfe2"

structure ConsumerBinding where
  sourceRevision : String
  canonicalSeed : Nat
  registry : Nat
  applicationPolicy : Nat
  representativePolicy : Nat
  validatorScript : Nat
  /-- Pinned consumer script (NOTE-013/NOTE-019, sixth `State` field):
  selected at bootstrap, carried by every `Modify`. -/
  consumerPin : Nat
  deriving Repr, BEq, DecidableEq, ToJson

structure InitializationAttempt where
  sourceRevision : String
  seed : Nat
  seedConsumed : Bool
  registry : Nat
  applicationPolicy : Nat
  representativePolicy : Nat
  validatorScript : Nat
  consumerPin : Nat
  deriving Repr, BEq, DecidableEq, ToJson

def initializeConsumer (binding : ConsumerBinding) (attempt : InitializationAttempt) : Except String Unit := do
  if attempt.sourceRevision != binding.sourceRevision then throw "source-revision"
  if attempt.seed != binding.canonicalSeed || !attempt.seedConsumed then throw "canonical-seed"
  if attempt.registry != binding.registry then throw "registry-authenticity"
  if attempt.applicationPolicy != binding.applicationPolicy then throw "application-policy"
  if attempt.representativePolicy != binding.representativePolicy then throw "representative-policy"
  if attempt.validatorScript != binding.validatorScript then throw "validator-script"
  if attempt.consumerPin != binding.consumerPin then throw "consumer-pin"

/-! Executable one-shot state for the initialization input. `seedConsumed` is
retained in `InitializationAttempt` as the source-boundary shape predicate,
while this transition owns consumption and therefore refuses a replay without
trusting that caller-supplied flag to remember prior executions. This is a
design-time UTxO-consumption model, not evidence that a Cardano transaction was
executed. -/
structure InitializationState where
  consumedSeeds : List Nat := []
  deriving Repr, BEq, DecidableEq, ToJson

def initializeConsumerTransition (binding : ConsumerBinding) (state : InitializationState)
    (attempt : InitializationAttempt) : Except String InitializationState := do
  initializeConsumer binding attempt
  if state.consumedSeeds.contains attempt.seed then throw "canonical-seed-consumed"
  return { consumedSeeds := attempt.seed :: state.consumedSeeds }

def initializationExecutingWitness (binding : ConsumerBinding) (state : InitializationState)
    (attempt : InitializationAttempt) : LifecycleExecutionWitness :=
  match initializeConsumerTransition binding state attempt with
  | .ok _ => { seedSpend := true }
  | .error _ => {}

def namingConsumerBinding : ConsumerBinding :=
  { sourceRevision := cardanoKeriRevision, canonicalSeed := 400, registry := 1,
    applicationPolicy := 7, representativePolicy := 8, validatorScript := 12,
    consumerPin := 9 }

def canonicalInitialization : InitializationAttempt :=
  { sourceRevision := cardanoKeriRevision, seed := 400, seedConsumed := true, registry := 1,
    applicationPolicy := 7, representativePolicy := 8, validatorScript := 12,
    consumerPin := 9 }

def alternateSeedInitialization : InitializationAttempt :=
  { canonicalInitialization with seed := 401 }

def rivalRegistryInitialization : InitializationAttempt :=
  { canonicalInitialization with seed := 401, registry := 2 }

def substitutedRegistryInitialization : InitializationAttempt :=
  { canonicalInitialization with registry := 2 }

def substitutedPolicyInitialization : InitializationAttempt :=
  { canonicalInitialization with applicationPolicy := 9 }

def substitutedRepresentativeInitialization : InitializationAttempt :=
  { canonicalInitialization with representativePolicy := 9 }

def substitutedValidatorInitialization : InitializationAttempt :=
  { canonicalInitialization with validatorScript := 13 }

def substitutedConsumerInitialization : InitializationAttempt :=
  { canonicalInitialization with consumerPin := 10 }

def canonicalInitializedState : InitializationState :=
  match initializeConsumerTransition namingConsumerBinding {} canonicalInitialization with
  | .ok state => state
  | .error _ => {}

def clearedFixture : NamingFixture := { aliceFixture with paymentDestination := none }

def recoveredFixture : NamingFixture :=
  { aliceFixture with controlAddress := nextControllerAddress, nextControlCommitment := freshControllerCommitment }

def forgedRecoveryFixture : NamingFixture :=
  { aliceFixture with controlAddress := nonFixtureControllerAddress, nextControlCommitment := freshControllerCommitment }

/-- Reducible fixture adapter used only by the concrete Lean examples. It is
not the browser implementation and makes no cryptographic correctness claim. -/
def fixtureHasher : NextControlHasher := fun address =>
  if address == nextControllerAddress then nextControllerCommitment
  else if address == freshControllerAddress then freshControllerCommitment
  else wrongDomainCommitment

def maintainClear : LifecycleAction :=
  .maintain 3 4 aliceKey clearedFixture { requiredSigners := [controllerAddress] }

def maintainQuorumTamper : LifecycleAction :=
  .maintain 3 4 aliceKey
    { clearedFixture with retirementQuorum := otherFixture.retirementQuorum }
    { requiredSigners := [controllerAddress] }

def quorumControlTakeover : LifecycleAction :=
  .maintain 3 4 aliceKey { aliceFixture with controlAddress := otherControllerAddress }
    { quorumSigners := [quorumKeyHash 1, quorumKeyHash 29] }

def quorumPaymentRedirection : LifecycleAction :=
  .maintain 3 4 aliceKey { aliceFixture with paymentDestination := some otherControllerAddress }
    { quorumSigners := [quorumKeyHash 1, quorumKeyHash 29] }

def recoverWithNext : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey) recoveredFixture
    { requiredSigners := [nextControllerAddress] }

def recoverWrongPaymentKeySigner : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey) recoveredFixture
    { requiredSigners := [controllerAddress] }

def recoverMissingFreshCommitment : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey)
    { recoveredFixture with nextControlCommitment := nextControllerCommitment }
    { requiredSigners := [nextControllerAddress] }

def recoverRepresentativeTamper : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
    { representative activeOnce.registry aliceKey with policy :=
        (representative activeOnce.registry aliceKey).policy + 1 }
    recoveredFixture { requiredSigners := [nextControllerAddress] }

def recoverRegistryTamper : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress (namingConsumerBinding.registry + 1)
    (representative activeOnce.registry aliceKey) recoveredFixture
    { requiredSigners := [nextControllerAddress] }

def recoverQuorumTamper : LifecycleAction :=
  .recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
    (representative activeOnce.registry aliceKey)
    { recoveredFixture with retirementQuorum := otherFixture.retirementQuorum }
    { requiredSigners := [nextControllerAddress] }

def retirementByController : LifecycleAction :=
  match activeOnce.records.head? with
  | none => .completeRetirement 0
  | some record =>
      match activeOnce.registry.applications.find? (fun output => output.id == record.outputId) with
      | none => .completeRetirement 0
      | some application =>
          .retire record.outputId 4 aliceKey (retirementRequest activeOnce record application 4)
            .controller { requiredSigners := [controllerAddress] }

def retirementByQuorum : LifecycleAction :=
  match activeOnce.records.head? with
  | none => .completeRetirement 0
  | some record =>
      match activeOnce.registry.applications.find? (fun output => output.id == record.outputId) with
      | none => .completeRetirement 0
      | some application =>
          .retire record.outputId 4 aliceKey (retirementRequest activeOnce record application 4)
            .quorum { quorumSigners := [quorumKeyHash 1, quorumKeyHash 29] }

def retirementInsufficient : LifecycleAction :=
  match activeOnce.records.head? with
  | none => .completeRetirement 0
  | some record =>
      match activeOnce.registry.applications.find? (fun output => output.id == record.outputId) with
      | none => .completeRetirement 0
      | some application =>
          .retire record.outputId 4 aliceKey (retirementRequest activeOnce record application 4)
            .quorum { quorumSigners := [quorumKeyHash 1] }

def retirementWrongCustody : LifecycleAction :=
  match activeOnce.records.head? with
  | none => .completeRetirement 0
  | some record =>
      match activeOnce.registry.applications.find? (fun output => output.id == record.outputId) with
      | none => .completeRetirement 0
      | some application =>
          let request := retirementRequest activeOnce record application 4
          let wrongRepresentative := { record.representative with policy := record.representative.policy + 1 }
          .retire record.outputId 4 aliceKey { request with held := some wrongRepresentative }
            .controller { requiredSigners := [controllerAddress] }

def withCancellationApproval (state : NamingState) (requestId refundAddress : Nat) : NamingState :=
  let asset := cancellationAsset state requestId refundAddress
  match step state.registry (.mintWithdraw { asset := asset, accepted := true }
      { applicationMint := true }) with
  | .ok result => { state with registry := result.state }
  | .error _ => state

/-- Pending `alice` with the distinct withdrawal attestation needed for the
positive cancellation row. The Insert attestation remains separately present. -/
def cancellationPending : NamingState :=
  withCancellationApproval claimedOnce 1 demoRefundAddress

def afterLifecycle (state : NamingState) (action : LifecycleAction) : NamingState :=
  match lifecycleStep fixtureHasher state action with
  | .ok result => result.state
  | .error _ => state

def retirementPending : NamingState := afterLifecycle activeOnce retirementByController
def retirementOver : NamingState := afterLifecycle retirementPending (.completeRetirement 4)
def cancelledClaim : NamingState :=
  afterLifecycle cancellationPending (.cancelClaim 1 demoRefundAddress)

def retiredReRegistration : Except String NamingResult := do
  let queued ← namingQueue retirementOver "alice" aliceFixture true
  namingFoldRequest queued.state queued.requestId

end Singular
