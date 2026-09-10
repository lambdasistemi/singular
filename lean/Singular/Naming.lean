import Singular.Model

/-! First-release naming profile on top of the generic registry model.
This is an explicit, unaccepted candidate profile: certification proves allowed
request and initial construction only, never person identity, entitlement to a
spelling, or ownership of a payment destination. The demo spelling table is a
frozen finite-model fixture, not a name normalization standard, and the fixture
values are fixtures, not product or economic policy.

The naming transition accepts the generic action shape. Certified Insert
queueing and its fold follow generic registry uniqueness (`occupied-key` is
decided only when a certified Insert folds; approval never occupies a
spelling). The profile defines no delete, release, reuse, or maintenance
transition: every other generic action kind is refused with `naming-no-delete`.
Naming fixtures are first-class fields carried beside the registry; they are
never packed into the generic `Output.datum` payload, which stays the generic
demo payload. -/
namespace Singular
open Lean

/-- Frozen demo spelling table: one entry, one key. -/
def demoSpellings : List (String × Nat) := [("alice", 42)]

/-- The frozen demo key behind the `alice` spelling. -/
def aliceKey : Nat := 42

/-- Resolve a demo spelling to its registry key, or `none` when unknown.
Unknown spellings are refused by the spelling binding, never silently mapped. -/
def spellingKey (spelling : String) : Option Nat := demoSpellings.lookup spelling

/-- Frozen generic demo payload constants reused for the naming proposal's
generic output. They are demo fixtures inherited from the generic profile, not
naming economics. -/
def demoDestination : Nat := 50
def demoDatum : Nat := 100
def demoValue : Nat := 20

structure RetirementQuorum where
  members : List Nat
  threshold : Nat
  deriving Repr, BEq, DecidableEq, ToJson

inductive NamingCredential where
  | paymentKey | script
  deriving Repr, BEq, DecidableEq, ToJson

inductive NamingAddressForm where
  | enterprise | base
  deriving Repr, BEq, DecidableEq, ToJson

/-- A decoded Conway address together with its canonical binary wire bytes.
Only base and enterprise forms are supported by the first naming profile. -/
structure NamingAddress where
  bytes : List Nat
  form : NamingAddressForm
  network : Nat
  paymentCredential : NamingCredential
  paymentHash : List Nat
  stakeCredential : Option NamingCredential := none
  stakeHash : List Nat := []
  deriving Repr, BEq, DecidableEq, ToJson

/-- The wire-level next-controller commitment. The digest is exactly 32 bytes. -/
structure NextCommitment where
  digest : List Nat
  deriving Repr, BEq, DecidableEq, ToJson

def bytesValid (bytes : List Nat) : Bool := bytes.all (· < 256)

def credentialOffset : NamingCredential → Nat
  | .paymentKey => 0
  | .script => 1

/-- Conway header nibble for the supported address forms. -/
def addressKind (address : NamingAddress) : Option Nat :=
  match address.form, address.paymentCredential, address.stakeCredential with
  | .enterprise, payment, none => some (6 + credentialOffset payment)
  | .base, payment, some stake => some (credentialOffset payment + 2 * credentialOffset stake)
  | _, _, _ => none

def encodeAddress (address : NamingAddress) : Option (List Nat) := do
  if address.network >= 16 || address.paymentHash.length != 28 || !bytesValid address.paymentHash then
    none
  let kind ← addressKind address
  match address.form with
  | .enterprise =>
      if !address.stakeHash.isEmpty then none
      else some ((kind * 16 + address.network) :: address.paymentHash)
  | .base =>
      if address.stakeHash.length != 28 || !bytesValid address.stakeHash then none
      else some ((kind * 16 + address.network) :: (address.paymentHash ++ address.stakeHash))

def credentialFromBit (bit : Nat) : NamingCredential :=
  if bit == 0 then .paymentKey else .script

/-- Decode only the two frozen supported Conway forms. Callers compare the
decoded value with the supplied value and re-encode it, excluding alternate
encodings of one address. -/
def decodeAddress (bytes : List Nat) : Option NamingAddress := do
  let header ← bytes.head?
  let payload := bytes.drop 1
  let kind := header / 16
  let network := header % 16
  if kind == 6 || kind == 7 then
    if payload.length != 28 || !bytesValid bytes then none
    else
      let address : NamingAddress :=
        { bytes := bytes
          form := .enterprise
          network := network
          paymentCredential := credentialFromBit (kind - 6)
          paymentHash := payload }
      some address
  else if kind < 4 then
    if payload.length != 56 || !bytesValid bytes then none
    else
      let address : NamingAddress :=
        { bytes := bytes
          form := .base
          network := network
          paymentCredential := credentialFromBit (kind % 2)
          paymentHash := payload.take 28
          stakeCredential := some (credentialFromBit (kind / 2))
          stakeHash := payload.drop 28 }
      some address
  else none

def canonicalAddress (address : NamingAddress) : Bool :=
  decodeAddress address.bytes == some address && encodeAddress address == some address.bytes

def paymentKeyAddress (address : NamingAddress) : Bool :=
  canonicalAddress address && address.paymentCredential == .paymentKey

def wellFormedCommitment (commitment : NextCommitment) : Bool :=
  commitment.digest.length == 32 && bytesValid commitment.digest

def controllerAddress : NamingAddress :=
  { bytes := 97 :: List.range' 1 28, form := .enterprise, network := 1,
    paymentCredential := .paymentKey, paymentHash := List.range' 1 28 }

def nextControllerAddress : NamingAddress :=
  { bytes := 97 :: List.range' 29 28, form := .enterprise, network := 1,
    paymentCredential := .paymentKey, paymentHash := List.range' 29 28 }

def freshControllerAddress : NamingAddress :=
  { bytes := 97 :: List.range' 57 28, form := .enterprise, network := 1,
    paymentCredential := .paymentKey, paymentHash := List.range' 57 28 }

def destinationAddress : NamingAddress :=
  { bytes := 97 :: List.range' 85 28, form := .enterprise, network := 1,
    paymentCredential := .paymentKey, paymentHash := List.range' 85 28 }

def otherControllerAddress : NamingAddress :=
  { bytes := 97 :: List.range' 113 28, form := .enterprise, network := 1,
    paymentCredential := .paymentKey, paymentHash := List.range' 113 28 }

def nextControllerCommitment : NextCommitment :=
  { digest := [194, 219, 76, 247, 78, 175, 65, 208, 95, 243, 240, 210, 186, 25, 12, 72,
    45, 189, 40, 94, 86, 21, 171, 104, 133, 192, 82, 134, 196, 194, 60, 190] }

def freshControllerCommitment : NextCommitment :=
  { digest := [21, 97, 193, 91, 73, 128, 133, 127, 176, 110, 74, 179, 92, 201, 188, 236,
    175, 9, 11, 10, 168, 189, 239, 25, 246, 51, 21, 101, 163, 51, 32, 79] }

structure NamingFixture where
  paymentDestination : Option NamingAddress
  controlAddress : NamingAddress
  nextControlCommitment : NextCommitment
  retirementQuorum : RetirementQuorum
  deriving Repr, BEq, DecidableEq, ToJson

/-- The four fixture slots are present by construction; the payment destination
must be absent or distinct from the control address. -/
def wellFormedFixture (fixture : NamingFixture) : Bool :=
  paymentKeyAddress fixture.controlAddress && wellFormedCommitment fixture.nextControlCommitment &&
  match fixture.paymentDestination with
  | none => true
  | some destination => canonicalAddress destination && destination != fixture.controlAddress

/-- The frozen first-release demo fixture for `alice`. Values are finite-model
fixtures, not product or economic policy. -/
def aliceFixture : NamingFixture :=
  { paymentDestination := some destinationAddress, controlAddress := controllerAddress,
    nextControlCommitment := nextControllerCommitment,
    retirementQuorum := { members := [50, 51, 52], threshold := 2 } }

/-- A competing well-formed demo fixture for a second `alice` claim. -/
def otherFixture : NamingFixture :=
  { paymentDestination := none, controlAddress := otherControllerAddress,
    nextControlCommitment := nextControllerCommitment,
    retirementQuorum := { members := [60, 61], threshold := 2 } }

/-- A malformed demo fixture: the payment destination equals the control
address, so certification must refuse it. -/
def malformedFixture : NamingFixture :=
  { aliceFixture with paymentDestination := some controllerAddress }

/-- A queued certified Insert for a fixture spelling. Two claims may share a
spelling; uniqueness is decided only at fold. -/
structure NamingClaim where
  requestId : Nat
  spelling : String
  key : Nat
  fixture : NamingFixture
  deriving Repr, BEq, DecidableEq, ToJson

/-- An active naming record: the folded key, its minted representative, and the
certified fixture carried unchanged from the claim. -/
structure NamingRecord where
  outputId : Nat
  key : Nat
  representative : Representative
  fixture : NamingFixture
  deriving Repr, BEq, DecidableEq, ToJson

structure NamingState where
  registry : State := {}
  claims : List NamingClaim := []
  records : List NamingRecord := []
  deriving Repr, BEq, DecidableEq, ToJson

structure NamingResult where
  state : NamingState
  logical : List Delta := []
  deriving Repr, BEq, DecidableEq, ToJson

/-- Authenticated naming observation. `active` carries the four certified
fixture fields. A pending claim reserves nothing: it observes as `pending`. -/
inductive NamingObservation where
  | unauthenticated | absent | pending | retired
  | active (fixture : NamingFixture)
  deriving Repr, BEq, DecidableEq

instance : ToJson NamingObservation where
  toJson
    | .unauthenticated => Json.str "unauthenticated"
    | .absent => Json.str "absent"
    | .pending => Json.str "pending"
    | .retired => Json.str "retired"
    | .active f => Json.mkObj [("status", Json.str "active"), ("fixture", toJson f)]

/-- The first fresh identifier after every identifier used so far. -/
def freshId (s : State) : Nat := s.used.foldl max 0 + 1

/-- Fold bookkeeping: move each folded claim into an active naming record,
carrying its certified fixture fields unchanged. -/
def migrateClaims (state : NamingState) (items : List FoldItem) (registry : State) : NamingState :=
  { state with registry := registry, claims := state.claims.filter (fun c => !items.any (fun i => i.request == c.requestId)), records := state.records ++ items.filterMap (fun i => match state.claims.find? (fun c => c.requestId == i.request) with | some c => some { outputId := i.outputId, key := c.key, representative := representative registry c.key, fixture := c.fixture } | none => none) }

/-- The naming transition. Only certified Insert queueing (`createInsert`) and
the certified Insert fold follow the generic registry; every other generic
action kind — release, withdrawal, evolution, withdrawal-approval minting,
outsider requests, token movement, custody escape, and a fold of a terminal
request — is refused with `naming-no-delete`. -/
def namingStep (state : NamingState) (action : Action) : Except String NamingResult := do
  match action with
  | .createInsert r cert w =>
    let result ← step state.registry (Action.createInsert r cert w)
    pure { state := { state with registry := result.state }, logical := result.logical }
  | .fold items mint net w =>
    let terminal := items.any fun i =>
      match state.registry.requests.find? (fun q => q.id == i.request) with
      | some r => r.operation != Operation.insert
      | none => false
    if terminal then throw "naming-no-delete"
    let result ← step state.registry (Action.fold items mint net w)
    pure { state := migrateClaims state items result.state, logical := result.logical }
  | _ => throw "naming-no-delete"

/-- The certified Insert action a naming queue would submit: a native proposal
for the spelling's key carrying the frozen generic demo payload, approved and
witnessed for the application mint. -/
def namingQueueAction (state : NamingState) (key : Nat) : Action :=
  let output : Output :=
    { representative := representative state.registry key, quantity := 1, destination := demoDestination, datum := demoDatum, value := demoValue }
  let proposal : Proposal :=
    { registry := state.registry.config.registry, key := key, applicationPolicy := state.registry.config.applicationPolicy, initial := output, scope := [(entry state.registry key).incarnation] }
  let asset := insertAsset proposal
  Action.createInsert { id := freshId state.registry, operation := Operation.insert, proposal := proposal, token := some asset, held := Option.none, destination := state.registry.config.requestAddress, authenticatedOrigin := true } { asset := asset, accepted := true } { applicationMint := true }

structure NamingQueueOutcome where
  requestId : Nat
  state : NamingState
  deriving Repr, BEq, DecidableEq, ToJson

/-- Validate the three naming-specific queue guards before entering the generic
registry transition. Keeping this boundary explicit makes each refusal branch
independently invertible. -/
def namingQueueValidate (spelling : String) (fixture : NamingFixture)
    (accepted : Bool) : Except String Nat :=
  match spellingKey spelling with
  | none => .error "unknown-spelling"
  | some key =>
    if !wellFormedFixture fixture then .error "invalid-fixture"
    else if !accepted then .error "application-approval"
    else .ok key

/-- Queue a naming claim for a spelling. Refuses an unknown spelling, a
malformed fixture, or a rejected application approval. Two queues for the same
spelling both accept: approval reserves nothing. -/
def namingQueue (state : NamingState) (spelling : String) (fixture : NamingFixture)
    (accepted : Bool) : Except String NamingQueueOutcome := do
  let key ← namingQueueValidate spelling fixture accepted
  let id := freshId state.registry
  let result ← namingStep state (namingQueueAction state key)
  pure { requestId := id, state := { result.state with claims := result.state.claims ++ [{ requestId := id, spelling := spelling, key := key, fixture := fixture }] } }

/-- The certified fold action for a queued Insert request. -/
def namingFoldAction (state : NamingState) (requestId : Nat) : Except String Action :=
  match state.registry.requests.find? (fun q => q.id == requestId) with
  | some r => Except.ok (Action.fold [{ request := requestId, outputId := freshId state.registry, output := some r.proposal.initial }] [{ asset := representative state.registry r.proposal.key, quantity := 1 }] [] { nativeSpend := true, representativeMint := true })
  | none => Except.error "request-unavailable"

/-- Fold one queued naming claim. The first valid absent-key fold accepts; a
later certified Insert for that key is refused with `occupied-key`. -/
def namingFoldRequest (state : NamingState) (requestId : Nat) : Except String NamingResult := do
  let _ ← requireSome (state.claims.find? (fun c => c.requestId == requestId)) "request-unavailable"
  let action ← namingFoldAction state requestId
  namingStep state action

/-- Authenticated naming observation of a registry key. An Over entry is
caller-visible as retired and is never collapsed into the transient pending
state. -/
def namingResolve (state : NamingState) (key : Nat) (authenticated : Bool) :
    Except String NamingObservation :=
  if !authenticated then .ok .unauthenticated
  else match state.records.find? (fun r => r.key == key) with
    | some r => .ok (.active r.fixture)
    | none =>
      match (entry state.registry key).value with
      | some .over => .ok .retired
      | some .active => .ok .pending
      | none =>
        if state.claims.any (fun c => c.key == key) then .ok .pending
        else .ok .absent

structure NamingReplay where
  state : NamingState
  records : List (Action × Except String NamingResult)
  deriving Repr

/-- Replay generic actions through the naming transition, keeping the state and
one verdict record per action. -/
def namingReplay (state : NamingState) (actions : List Action) : NamingReplay :=
  match actions with
  | [] => { state := state, records := [] }
  | action :: rest =>
    let verdict := namingStep state action
    let next := match verdict with | .ok r => r.state | .error _ => state
    let tail := namingReplay next rest
    { state := tail.state, records := (action, verdict) :: tail.records }

/-- Queue a claim for the demo spelling table, keeping the pre-state on
refusal. Demo journey driver for the frozen trace. -/
def namingQueueState (state : NamingState) (spelling : String) (fixture : NamingFixture) :
    NamingState :=
  match namingQueue state spelling fixture true with
  | .ok outcome => outcome.state
  | .error _ => state

/-- Fold one queued claim, keeping the pre-state on refusal. Demo journey
driver for the frozen trace. -/
def namingFoldState (state : NamingState) (requestId : Nat) : NamingState :=
  match namingFoldRequest state requestId with
  | .ok result => result.state
  | .error _ => state

/-- The frozen naming journey, step one: the first `alice` claim queues. -/
def claimedOnce : NamingState := namingQueueState {} "alice" aliceFixture

/-- The frozen naming journey, step two: a competing `alice` claim also queues;
approval still reserves nothing. -/
def claimedTwice : NamingState := namingQueueState claimedOnce "alice" otherFixture

/-- The frozen naming journey, step three: the first claim folds and `alice`
becomes active carrying the certified fixture. -/
def activeOnce : NamingState := namingFoldState claimedTwice 1

end Singular
