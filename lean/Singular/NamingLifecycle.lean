import Singular.Naming

/-! Lifecycle for the naming profile over the registry-mode model.
`maintain` and `recover` replace the record's fixture and never touch the
trie — the root is equal before and after (NM2). Retirement is authorized per
R-NM4 (NM3), creates the ordinary-validator pending request and leaves the leaf
active; a separate completion applies `updateTerminal`. The consumer binding
pins the eight-field datum's policies plus the same-registry cage token and
applied request-validator identity; `consumerPin` and `representativePolicy`
are removed, not renamed. -/

namespace Singular
open Lean

/-- The reduced initialization binding the consumer pins at seed time: the
source revision and the pinned datum fields. `consumerPin` is removed;
`representativePolicy` became `activePolicy`. -/
structure ConsumerBinding where
  sourceRevision : String
  canonicalSeed : Nat
  registry : Nat
  cageTokenName : Nat
  requestValidatorHash : Nat
  applicationPolicy : Nat
  activePolicy : Nat
  absentPolicy : Nat
  terminalPolicy : Nat
  validatorScript : Nat
  deriving Repr, BEq, DecidableEq, ToJson

/-- The executable consumer's frozen source revision. -/
def cardanoKeriRevision : String := "14a64a4681d3e429fab5877062b5c476c2a4bfe2"

def namingConsumerBinding : ConsumerBinding :=
  { sourceRevision := cardanoKeriRevision
  , canonicalSeed := canonicalNamingParameters.seedOutputReference
  , registry := canonicalNamingParameters.registryStatePolicy
  , cageTokenName := canonicalNamingParameters.cageTokenName
  , requestValidatorHash := canonicalNamingParameters.requestValidatorHash
  , applicationPolicy := namingConfig.applicationPolicy
  , activePolicy := 8, absentPolicy := 9, terminalPolicy := 10,
    validatorScript := 12 }

structure InitializationAttempt where
  sourceRevision : String
  seed : Nat
  seedConsumed : Bool
  registry : Nat
  cageTokenName : Nat
  requestValidatorHash : Nat
  applicationPolicy : Nat
  activePolicy : Nat
  absentPolicy : Nat
  terminalPolicy : Nat
  validatorScript : Nat
  deriving Repr, BEq, DecidableEq, ToJson

def canonicalInitialization : InitializationAttempt :=
  { sourceRevision := cardanoKeriRevision
  , seed := canonicalNamingParameters.seedOutputReference
  , seedConsumed := true
  , registry := canonicalNamingParameters.registryStatePolicy
  , cageTokenName := canonicalNamingParameters.cageTokenName
  , requestValidatorHash := canonicalNamingParameters.requestValidatorHash
  , applicationPolicy := namingConfig.applicationPolicy
  , activePolicy := 8, absentPolicy := 9, terminalPolicy := 10,
    validatorScript := 12 }

def initializeConsumer (binding : ConsumerBinding) (attempt : InitializationAttempt) :
    Except String Unit := do
  if attempt.sourceRevision != binding.sourceRevision then throw "source-revision"
  if attempt.seed != binding.canonicalSeed || !attempt.seedConsumed then throw "canonical-seed"
  if attempt.registry != binding.registry then throw "registry-authenticity"
  if attempt.cageTokenName != binding.cageTokenName then throw "cage-token"
  if attempt.cageTokenName != cageTokenNameFromSeed attempt.seed then throw "cage-token-derivation"
  if attempt.requestValidatorHash != binding.requestValidatorHash then throw "request-validator"
  if attempt.requestValidatorHash !=
      appliedRequestValidatorHashFor attempt.registry attempt.cageTokenName then
    throw "request-validator-derivation"
  if attempt.applicationPolicy != binding.applicationPolicy then throw "application-policy"
  if attempt.applicationPolicy != namingApplicationPolicyFor attempt.requestValidatorHash then
    throw "application-policy-derivation"
  if attempt.activePolicy != binding.activePolicy then throw "active-policy"
  if attempt.absentPolicy != binding.absentPolicy then throw "absent-policy"
  if attempt.terminalPolicy != binding.terminalPolicy then throw "terminal-policy"
  if attempt.validatorScript != binding.validatorScript then throw "validator-script"

def clearedFixture : NamingFixture := { aliceFixture with paymentDestination := none }

def recoveredFixture : NamingFixture :=
  ({ aliceFixture with controlAddress := nextControllerAddress, nextControlCommitment := freshControllerCommitment } : NamingFixture)

/-- Maintenance: the certified fixture fields other than the payment
destination are preserved; the trie is untouched (NM2). -/
def maintainDestination (state : NamingState) (key : Nat) (candidate : NamingFixture)
    (signers : List NamingAddress) : Except String NamingState := do
  let record ←
    Option.toExcept (state.records.find? (·.key == key)) "naming-record-unavailable"
  if !signers.contains record.fixture.controlAddress then throw "controller-signature"
  if candidate.controlAddress != record.fixture.controlAddress ||
      candidate.nextControlCommitment != record.fixture.nextControlCommitment ||
      candidate.retirementQuorum != record.fixture.retirementQuorum then
    throw "destination-field-preservation"
  if !wellFormedFixture candidate then throw "invalid-fixture"
  pure { state with records :=
    { record with fixture := candidate } :: state.records.filter (·.key != key) }

/-- Recovery: the revealed key commits to the record's commitment and signs;
the fresh commitment differs. The trie is untouched (NM2). -/
def recoverController (hasher : RecoveryHasher) (state : NamingState) (key : Nat)
    (revealed : NamingAddress) (candidate : NamingFixture)
    (signers : List NamingAddress) : Except String NamingState := do
  let record ←
    Option.toExcept (state.records.find? (·.key == key)) "naming-record-unavailable"
  if !paymentKeyAddress revealed then throw "recovery-payment-key"
  let computed := hasher revealed
  if !wellFormedCommitment computed then throw "recovery-hash-shape"
  if computed != record.fixture.nextControlCommitment then throw "recovery-commitment"
  if !signers.contains revealed then throw "recovery-required-signer"
  if candidate.controlAddress != revealed ||
      candidate.paymentDestination != record.fixture.paymentDestination ||
      candidate.retirementQuorum != record.fixture.retirementQuorum then
    throw "recovery-field-preservation"
  if !wellFormedCommitment candidate.nextControlCommitment ||
      candidate.nextControlCommitment == record.fixture.nextControlCommitment then
    throw "recovery-fresh-commitment"
  if !wellFormedFixture candidate then throw "invalid-fixture"
  pure { state with records :=
    { record with fixture := candidate } :: state.records.filter (·.key != key) }

/-- Retirement phase one under R-NM4 — recovery key or quorum, never the
control key alone. It creates the pending request; completion is separate. -/
def namingRetireLifecycle (state : NamingState) (key : Nat) (signatures : List (List Nat))
    (revealed : Option NamingAddress) : Except String NamingState :=
  namingRetire state key signatures revealed

end Singular
