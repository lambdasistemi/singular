import Singular.Model

/-! First-release naming profile on top of the registry-mode model.
This is an explicit, unaccepted candidate profile: certification proves allowed
request construction only, never person identity, entitlement to a spelling, or
ownership of a payment destination.

The record UTxO holds the active token and the trie carries only `Active`
(NM1); `maintain` and `recover` never touch the trie (NM2); retirement
completion is `updateTerminal` (NM3); the approval policy follows R-NM4 for all
six edges, with `updateTerminal` certified by the committed recovery key
revealed and signing, or by a distinct-member quorum — never by the current
control key alone (operator ruling). Naming fixtures are first-class fields
carried beside the registry; nothing an application stores is in the trie. -/
namespace Singular
open Lean

/-- Frozen demo spelling table: one entry, one key. -/
def demoSpellings : List (String × Nat) := [("alice", 42)]

/-- The frozen demo key behind the `alice` spelling. -/
def aliceKey : Nat := 42

/-- Resolve a demo spelling to its registry key, or `none` when unknown. -/
def spellingKey (spelling : String) : Option Nat := demoSpellings.lookup spelling

structure RetirementQuorum where
  members : List (List Nat)
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

/-- Decode only the two frozen supported Conway forms. -/
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

def quorumKeyHash (start : Nat) : List Nat := List.range' start 28

def wellFormedQuorum (quorum : RetirementQuorum) : Bool :=
  quorum.members.all (fun member => member.length == 28 && bytesValid member) &&
    quorum.threshold > 0 && quorum.threshold <= quorum.members.eraseDups.length

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

/-- A deliberately wrong commitment for addresses outside the fixture world:
the model's stand-in for a hash over the wrong domain. -/
def wrongDomainCommitment : NextCommitment :=
  { digest := [102, 167, 149, 152, 220, 195, 145, 245, 46, 220, 238, 211, 46, 4, 208, 40,
    206, 250, 110, 82, 65, 224, 146, 63, 163, 48, 134, 161, 196, 163, 28, 110] }

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
    wellFormedQuorum fixture.retirementQuorum &&
    match fixture.paymentDestination with
    | none => true
    | some destination => canonicalAddress destination && destination != fixture.controlAddress

def aliceFixture : NamingFixture :=
  { paymentDestination := some destinationAddress, controlAddress := controllerAddress,
    nextControlCommitment := nextControllerCommitment,
    retirementQuorum := { members := [quorumKeyHash 1, quorumKeyHash 29, quorumKeyHash 57], threshold := 2 } }

def otherFixture : NamingFixture :=
  { paymentDestination := none, controlAddress := otherControllerAddress,
    nextControlCommitment := nextControllerCommitment,
    retirementQuorum := { members := [quorumKeyHash 85, quorumKeyHash 113], threshold := 2 } }

def malformedFixture : NamingFixture :=
  { aliceFixture with paymentDestination := some controllerAddress }

/-- An active naming record: the record UTxO holds the active token (NM1) and
carries the certified fixture. `output` is the output the booking request
named. -/
structure NamingRecord where
  key : Key
  output : Nat
  fixture : NamingFixture
  deriving Repr, BEq, DecidableEq, ToJson

structure NamingState where
  registry : RegistryState
  records : List NamingRecord
  deriving BEq, DecidableEq

/-- The commitment-adapter contract at the model/cryptography boundary: the
executable consumer supplies the BLAKE2b-256 implementation; the model fixes
the complete preimage and output shape. -/
abbrev RecoveryHasher := NamingAddress → NextCommitment

/-- The trusted commitment adapter used by the concrete Lean examples: every
fixture address commits to `wrongDomainCommitment` unless it is the committed
recovery key. It is not the browser implementation and makes no cryptographic
correctness claim. -/
def fixtureHasher : RecoveryHasher := fun address =>
  if address == nextControllerAddress then nextControllerCommitment
  else if address == freshControllerAddress then freshControllerCommitment
  else wrongDomainCommitment

/-- The revealed key commits exactly like the record's commitment: the key
whose hash the record commits to, revealed and signing exactly as `Recover`
proves it. -/
def revealsCommittedRecoveryKey (hasher : RecoveryHasher) (fixture : NamingFixture)
    (revealed : Option NamingAddress) : Bool :=
  match revealed with
  | some address => (hasher address).digest == fixture.nextControlCommitment.digest
  | none => false

/-- A distinct-member quorum: signed members deduplicated, threshold met. -/
def quorumMet (quorum : RetirementQuorum) (signatures : List (List Nat)) : Bool :=
  (quorum.members.filter signatures.contains).eraseDups.length >= quorum.threshold

/-- A Nat rendered as a 28-byte little list; a model stand-in for an address
rendering. -/
def toBytes28 (n : Nat) : List Nat := n :: List.replicate 27 0

/-- A Nat fallback rendering of an address (its first byte); the demo
controller owns the key, so the context binds by fixture, not by rendering. -/
def List.toNatFallback (bs : List Nat) : Nat := bs.headD 0

/-- The naming context a certification reads: the controller who will own the
record, the refund address the `insertAbsent` request named (read from the
cage custody datum), and the record's fixture. -/
structure NamingCtx where
  controllerBytes : List Nat
  refundBytes : List Nat
  fixture : NamingFixture
  deriving Repr, BEq, DecidableEq

/-- Option elimination with an observable reason. -/
def Option.toExcept (o : Option α) (why : String) : Except String α :=
  match o with | some a => .ok a | none => .error why

/-- The naming context for a key: the record's fixture and controller when the
key is booked; the custody datum's refund address when an absence is witnessed;
the requester otherwise. -/
def namingContext (state : NamingState) (key : Key) (owner : List Nat) :
    Option NamingCtx :=
  match state.records.find? (·.key == key) with
  | some record =>
      some { controllerBytes := controllerAddress.bytes, refundBytes := owner
           , fixture := record.fixture }
  | none =>
      match state.registry.custody.find? (·.key == key) with
      | some entry =>
          some { controllerBytes := owner
               , refundBytes := toBytes28 entry.refundAddress
               , fixture := aliceFixture }
      | none =>
          some { controllerBytes := owner, refundBytes := owner
               , fixture := aliceFixture }

/-- R-NM4 (operator ruling, as amended): what naming's approval policy
certifies on, per edge. `insertAbsent` for anyone; `updateActive` on the
signature of the controller who will own the record; `deleteAbsent` on the
signature of the refund address the `insertAbsent` request named; `insertActive`
on the controller's signature; `updateTerminal` on the committed recovery key
revealed and signing, or a distinct-member quorum — never the current control
key alone; `deleteActive` never. Reads need no certification. -/
def namingCertifies (hasher : RecoveryHasher) (edge : Edge)
    (signatures : List (List Nat)) (revealed : Option NamingAddress)
    (context : NamingCtx) : Bool :=
  match edge with
  | .insertAbsent => true
  | .insertActive => signatures.contains context.controllerBytes
  | .updateActive => signatures.contains context.controllerBytes
  | .deleteAbsent => signatures = [context.refundBytes]
  | .updateTerminal =>
      revealsCommittedRecoveryKey hasher context.fixture revealed ||
        quorumMet context.fixture.retirementQuorum signatures
  | .deleteActive => false
  | .witnessTerminal => true

/-- The naming pinned configuration (the eight-field datum of R7). -/
def namingConfig : Config :=
  { root := rootOf []
  , maxFee := 1
  , processTime := 2
  , retractTime := 3
  , applicationPolicy := 7
  , activePolicy := 8
  , absentPolicy := 9
  , terminalPolicy := 10 }

/-- The naming transition: a request is admitted only if the cage admits it
and naming's policy certifies it (R-NM4); every uncertified request is refused
with the naming reason for its own cause, never a single catch-all.
`deleteActive` is never certified, so naming defines no delete. -/
def namingStep (hasher : RecoveryHasher) (state : NamingState) (r : Request)
    (revealed : Option NamingAddress) : Except String Result := do
  let context ←
    Option.toExcept (namingContext state r.key (toBytes28 r.owner)) "naming-context"
  let signatures := match r.approval with
    | some ap => ap.signatures
    | none => []
  if !(namingCertifies hasher r.edge signatures revealed context) then
    -- One reason per cause. Naming defines no delete, so `deleteActive` keeps
    -- the name that says so; a retirement that met neither the recovery-key nor
    -- the quorum route is a different failure and must not wear that name.
    throw (match r.edge with
      | .deleteActive => "naming-no-delete"
      | .updateTerminal => "naming-retirement-uncertified"
      | _ => "naming-uncertified")
  step state.registry r

/-- The registry the naming journeys start from. -/
def namingInitial : NamingState :=
  { registry := { config := namingConfig, trie := [], custody := [], held := [] }
  , records := [] }

/-- A naming approval minted under the pinned application policy, scoped to the
request's tuple and carrying the signatures its policy certified it on. -/
def namingApproval (r : Request) (signatures : List (List Nat)) : Option Approval :=
  some { policy := namingConfig.applicationPolicy
       , edge := r.edge
       , key := r.key
       , owner := r.owner
       , destination := requestDestination r
       , assetName := approvalAssetName r.edge r.key r.owner (requestDestination r)
       , signatures := signatures }

/-- Witness the absence of a key: `insertAbsent`, anyone, depositing at the
refund address the witness names (Carol). -/
def namingWitness (state : NamingState) (key : Nat) (witness : Nat) (deposit : Nat) :
    Except String NamingState := do
  let r : Request :=
    ({ edge := .insertAbsent, key := key, owner := witness, refundAddress := witness
      , deposit := deposit } : Request)
  let ap := namingApproval r []
  (namingStep fixtureHasher state { r with approval := ap } none).map
    fun result => { state with registry := result.state }

/-- Register a fresh name: `insertActive`, the controller's signature; the
record UTxO holds the active token and the trie carries only `Active` (NM1). -/
def namingRegister (state : NamingState) (key : Nat) (out : Nat)
    (fixture : NamingFixture) : Except String NamingState := do
  let r : Request :=
    ({ edge := .insertActive, key := key
     , owner := List.toNatFallback controllerAddress.bytes, output := out } : Request)
  let ap := namingApproval r [toBytes28 r.owner]
  (namingStep fixtureHasher state { r with approval := ap } none).map
    fun result =>
      { state with
        registry := result.state
        records := { key := key, output := out, fixture := fixture } :: state.records }

/-- Retract a witnessed absence: `deleteAbsent`, the refund address the
`insertAbsent` request named — the inserter only, never anyone else (R-ADA,
R-NM4). The deposit returns to the inserter whichever way the absence ends. -/
def namingRetract (state : NamingState) (key : Nat) : Except String NamingState := do
  let entry ←
    Option.toExcept (state.registry.custody.find? (·.key == key)) "custody-missing"
  let r : Request := ({ edge := .deleteAbsent, key := key, owner := entry.refundAddress } : Request)
  let ap := namingApproval r [toBytes28 entry.refundAddress]
  (namingStep fixtureHasher state { r with approval := ap } none).map
    fun result => { state with registry := result.state }

/-- Book a witnessed name: `updateActive`, the controller's signature; the fold
consumes the absent token without the witness's signature and pays the deposit
to the refund address its custody datum records. -/
def namingBook (state : NamingState) (key : Nat) (out : Nat)
    (fixture : NamingFixture) : Except String NamingState := do
  let r : Request :=
    ({ edge := .updateActive, key := key
     , owner := List.toNatFallback controllerAddress.bytes, output := out } : Request)
  let ap := namingApproval r [toBytes28 r.owner]
  (namingStep fixtureHasher state { r with approval := ap } none).map
    fun result =>
      { state with
        registry := result.state
        records := { key := key, output := out, fixture := fixture } :: state.records }

/-- Retire a record: `updateTerminal`, certified by the committed recovery key
revealed and signing, or by a distinct-member quorum — never the current
control key alone (NM3, R-NM4 as amended). -/
def namingRetire (state : NamingState) (key : Nat) (signatures : List (List Nat))
    (revealed : Option NamingAddress) : Except String NamingState := do
  let record ←
    Option.toExcept (state.records.find? (·.key == key)) "naming-record-unavailable"
  let r : Request :=
    ({ edge := .updateTerminal, key := key, owner := record.output
     , output := record.output } : Request)
  let ap := namingApproval r signatures
  (namingStep fixtureHasher state { r with approval := ap } revealed).map
    fun result =>
      { state with registry := result.state, records := state.records.filter (·.key != key) }

/-- Attest a retired name: `witnessTerminal`, anyone; the Over witness is
minted by a folded read and freely burnable. -/
def namingAttest (state : NamingState) (key : Nat) (out : Nat) :
    Except String NamingState := do
  let r : Request := ({ edge := .witnessTerminal, key := key, output := out } : Request)
  (namingStep fixtureHasher state r none).map
    fun result => { state with registry := result.state }

/-- `WellFormed` over the naming state: the registry is consistent and every
record's key is exactly the booked active token at the record's output. -/
def namingWellFormed (state : NamingState) : Prop :=
  Consistent state.registry ∧
  ∀ record ∈ state.records,
    kindCount state.registry .active record.key = 1 ∧
    ∃ h ∈ state.registry.held, h.key = record.key ∧ h.kind = .active ∧
      h.output = record.output

end Singular

namespace Singular.Naming

/-- `WellFormed` over the naming state: the registry is consistent and every
record's key is exactly the booked active token at the record's output. -/
def WellFormed (state : NamingState) : Prop :=
  Consistent state.registry ∧
  ∀ record ∈ state.records,
    kindCount state.registry .active record.key = 1 ∧
    ∃ h ∈ state.registry.held, h.key = record.key ∧ h.kind = .active ∧
      h.output = record.output

end Singular.Naming
