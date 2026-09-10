import Singular.Naming

/-! Design-time wire contract for the naming application datum. The datum is
exactly outer `Constr 0 [inner]`, where inner is `Constr 0` with four fields.
Retirement observation is deliberately absent because retirement consumes the
application output; pending/over remains a resolver result. -/
namespace Singular
open Lean

inductive WireData where
  | constr (index : Nat) (fields : List WireData)
  | bytes (value : List Nat)
  | integer (value : Nat)
  | list (values : List WireData)
  deriving Repr, BEq

inductive DatumAttachment where
  | inline (datum : WireData)
  | datumHash (hash : List Nat)
  | absent
  deriving Repr, BEq

def wireDataJson : WireData → Json
  | .constr index fields => Json.mkObj [("constr", Json.mkObj [
      ("index", toJson index), ("fields", Json.arr (fields.map wireDataJson).toArray)])]
  | .bytes value => Json.mkObj [("bytes", toJson value)]
  | .integer value => Json.mkObj [("integer", toJson value)]
  | .list values => Json.mkObj [("list", Json.arr (values.map wireDataJson).toArray)]

instance : ToJson WireData := ⟨wireDataJson⟩

def encodePaymentDestination : Option NamingAddress → WireData
  | none => .constr 0 []
  | some address => .constr 1 [.bytes address.bytes]

def encodeRetirementQuorum (quorum : RetirementQuorum) : WireData :=
  .constr 0 [.integer quorum.threshold, .list (quorum.members.map WireData.bytes)]

def encodeNamingDatum (fixture : NamingFixture) : WireData :=
  .constr 0 [.constr 0 [
    .bytes fixture.controlAddress.bytes,
    encodePaymentDestination fixture.paymentDestination,
    .bytes fixture.nextControlCommitment.digest,
    encodeRetirementQuorum fixture.retirementQuorum]]

def decodePaymentDestination : WireData → Option (Option NamingAddress)
  | .constr 0 [] => some none
  | .constr 1 [.bytes bytes] => (decodeAddress bytes).map some
  | _ => none

def decodeKeyHashes : List WireData → Option (List (List Nat))
  | [] => some []
  | .bytes bytes :: rest => do
      if bytes.length != 28 || !bytesValid bytes then none
      else return bytes :: (← decodeKeyHashes rest)
  | _ => none

def decodeRetirementQuorum : WireData → Option RetirementQuorum
  | .constr 0 [.integer threshold, .list encodedMembers] => do
      let members ← decodeKeyHashes encodedMembers
      let quorum : RetirementQuorum := { members := members, threshold := threshold }
      if wellFormedQuorum quorum then some quorum else none
  | _ => none

def decodeNamingDatum : WireData → Option NamingFixture
  | .constr 0 [.constr 0 [.bytes controlBytes, paymentData,
      .bytes commitmentBytes, quorumData]] => do
      let controlAddress ← decodeAddress controlBytes
      let paymentDestination ← decodePaymentDestination paymentData
      let retirementQuorum ← decodeRetirementQuorum quorumData
      let fixture : NamingFixture :=
        { controlAddress := controlAddress
          paymentDestination := paymentDestination
          nextControlCommitment := { digest := commitmentBytes }
          retirementQuorum := retirementQuorum }
      if wellFormedFixture fixture then some fixture else none
  | _ => none

def extractNamingDatum : DatumAttachment → Option NamingFixture
  | .inline datum => decodeNamingDatum datum
  | .datumHash _ | .absent => none

structure NamingDatumShape where
  outerIndex : Nat
  innerIndex : Nat
  arity : Nat
  deriving Repr, BEq, DecidableEq, ToJson

def namingDatumShape : WireData → Option NamingDatumShape
  | .constr outer [.constr inner fields] =>
      some { outerIndex := outer, innerIndex := inner, arity := fields.length }
  | _ => none

def namingDatumControlBytes : WireData → Option (List Nat)
  | .constr 0 [.constr 0 (.bytes bytes :: _)] => some bytes
  | _ => none

def namingDatumCommitmentBytes : WireData → Option (List Nat)
  | .constr 0 [.constr 0 [_, _, .bytes bytes, _]] => some bytes
  | _ => none

/-! The Insert action token is a separate wire surface from `NamingDatum`.
Its outer constructor is the `Commitment.insert` branch; the inner constructor
is the six-field `Proposal`, including the cancellation refund address. -/
structure InsertRequestShape where
  commitmentIndex : Nat
  commitmentArity : Nat
  proposalIndex : Nat
  proposalArity : Nat
  deriving Repr, BEq, DecidableEq, ToJson

def aliceInsertProposal : Proposal :=
  let registry : State := {}
  let output : Output :=
    { representative := representative registry aliceKey, quantity := 1,
      destination := demoDestination, datum := demoDatum, value := demoValue }
  { registry := registry.config.registry, key := aliceKey,
    applicationPolicy := registry.config.applicationPolicy,
    refundAddress := demoRefundAddress, initial := output,
    scope := [(entry registry aliceKey).incarnation] }

def aliceInsertRequest : Request :=
  { id := 1, operation := .insert, proposal := aliceInsertProposal,
    token := some (insertAsset aliceInsertProposal), held := none,
    destination := ({} : State).config.requestAddress, authenticatedOrigin := true }

def encodeRepresentative (value : Representative) : WireData :=
  .constr 0 [.integer value.registry, .integer value.key,
    .integer value.policy, .integer value.assetScope]

def decodeRepresentative : WireData → Option Representative
  | .constr 0 [.integer registry, .integer key, .integer policy, .integer assetScope] =>
      some { registry, key, policy, assetScope }
  | _ => none

def encodeOutput (value : Output) : WireData :=
  .constr 0 [encodeRepresentative value.representative, .integer value.quantity,
    .integer value.destination, .integer value.datum, .integer value.value]

def decodeOutput : WireData → Option Output
  | .constr 0 [representativeData, .integer quantity, .integer destination,
      .integer datum, .integer value] => do
      let representative ← decodeRepresentative representativeData
      some { representative, quantity, destination, datum, value }
  | _ => none

def encodeProposal (proposal : Proposal) : WireData :=
  .constr 0 [.integer proposal.registry, .integer proposal.key,
    .integer proposal.applicationPolicy, .integer proposal.refundAddress,
    encodeOutput proposal.initial, .list (proposal.scope.map WireData.integer)]

def decodeProposal : WireData → Option Proposal
  | .constr 0 [.integer registry, .integer key, .integer applicationPolicy,
      .integer refundAddress, outputData, .list scopeData] => do
      let initial ← decodeOutput outputData
      let scope ← scopeData.mapM fun
        | .integer value => some value
        | _ => none
      some { registry, key, applicationPolicy, refundAddress, initial, scope }
  | _ => none

def encodeInsertRequest (request : Request) : Option WireData :=
  if request.operation == .insert &&
      request.token == some (insertAsset request.proposal) then
    some (.constr 0 [encodeProposal request.proposal])
  else none

def decodeInsertCommitment : WireData → Option Proposal
  | .constr 0 [proposalData] => decodeProposal proposalData
  | _ => none

def decodeInsertRequestCommitment (request : Request) (data : WireData) : Option Proposal := do
  let expected ← (encodeInsertRequest request).bind decodeInsertCommitment
  let proposal ← decodeInsertCommitment data
  if proposal != expected then none else some proposal

def insertRequestShape : WireData → Option InsertRequestShape
  | .constr commitmentIndex [.constr proposalIndex fields] =>
      some (InsertRequestShape.mk commitmentIndex 1 proposalIndex fields.length)
  | _ => none

def twoDestinationDatum : WireData :=
  .constr 0 [.constr 0 [
    .bytes controllerAddress.bytes,
    .constr 1 [.bytes destinationAddress.bytes, .bytes otherControllerAddress.bytes],
    .bytes nextControllerCommitment.digest,
    encodeRetirementQuorum aliceFixture.retirementQuorum]]

/-! Canonical Plutus Data CBOR for the supported naming datum extent. This
follows `serialiseData`: constructor 0 is tag 121 (`d8 79`), constructor and
list fields are indefinite arrays, and byte strings up to the supported
32-byte maximum use canonical definite lengths. -/
def cborHead (major value : Nat) : List Nat :=
  if value < 24 then [major * 32 + value]
  else if value < 256 then [major * 32 + 24, value]
  else if value < 65536 then [major * 32 + 25, value / 256, value % 256]
  else []

def serialiseWireData : WireData → List Nat
  | .constr index fields =>
      if index < 7 then [216, 121 + index, 159] ++ fields.flatMap serialiseWireData ++ [255]
      else []
  | .bytes value =>
      if value.length <= 64 && bytesValid value then cborHead 2 value.length ++ value else []
  | .integer value => cborHead 0 value
  | .list values => [159] ++ values.flatMap serialiseWireData ++ [255]

def takeWireBytes (count : Nat) (bytes : List Nat) : Option (List Nat × List Nat) :=
  if bytes.length < count then none else some (bytes.take count, bytes.drop count)

mutual
  def parseWireDataFuel : Nat → List Nat → Option (WireData × List Nat)
    | 0, _ => none
    | fuel + 1, bytes =>
      match bytes with
      | 216 :: tag :: 159 :: rest => do
          if tag < 121 || tag >= 128 then none
          else
            let (fields, tail) ← parseWireItemsFuel fuel rest
            some (.constr (tag - 121) fields, tail)
      | 159 :: rest => do
          let (values, tail) ← parseWireItemsFuel fuel rest
          some (.list values, tail)
      | header :: rest =>
          if header >= 64 && header < 88 then do
            let (value, tail) ← takeWireBytes (header - 64) rest
            some (.bytes value, tail)
          else if header == 88 then do
            let length ← rest.head?
            if length < 24 || length > 64 then none
            else
              let (value, tail) ← takeWireBytes length (rest.drop 1)
              some (.bytes value, tail)
          else if header < 24 then some (.integer header, rest)
          else if header == 24 then do
            let value ← rest.head?
            if value < 24 then none else some (.integer value, rest.drop 1)
          else if header == 25 then do
            let high ← rest.head?
            let low ← (rest.drop 1).head?
            let value := high * 256 + low
            if value < 256 then none else some (.integer value, rest.drop 2)
          else none
      | [] => none

  def parseWireItemsFuel : Nat → List Nat → Option (List WireData × List Nat)
    | 0, _ => none
    | fuel + 1, bytes =>
      match bytes with
      | 255 :: rest => some ([], rest)
      | [] => none
      | _ => do
          let (value, rest) ← parseWireDataFuel fuel bytes
          let (values, tail) ← parseWireItemsFuel fuel rest
          some (value :: values, tail)
end

def deserialiseWireData (bytes : List Nat) : Option WireData := do
  let (datum, rest) ← parseWireDataFuel (bytes.length + 1) bytes
  if rest.isEmpty then some datum else none

def serialiseNamingDatum (fixture : NamingFixture) : List Nat :=
  serialiseWireData (encodeNamingDatum fixture)

def deserialiseNamingDatum (bytes : List Nat) : Option NamingFixture :=
  (deserialiseWireData bytes).bind decodeNamingDatum

/-! Frozen source-convention bytes for `aliceFixture`. Keeping this as an
explicit vector makes the byte contract independent of `serialiseWireData` and
therefore able to catch a serializer that is internally round-trip consistent
but wire-incompatible. -/
def expectedNamingDatumBytes : List Nat :=
  [216, 121, 159, 216, 121, 159,
   88, 29, 97, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
   20, 21, 22, 23, 24, 25, 26, 27, 28,
   216, 122, 159,
   88, 29, 97, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99,
   100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 255,
   88, 32, 194, 219, 76, 247, 78, 175, 65, 208, 95, 243, 240, 210, 186, 25, 12,
   72, 45, 189, 40, 94, 86, 21, 171, 104, 133, 192, 82, 134, 196, 194, 60, 190,
   216, 121, 159, 2, 159,
   88, 28, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
   20, 21, 22, 23, 24, 25, 26, 27, 28,
   88, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45,
   46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
   88, 28, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73,
   74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 255, 255, 255, 255]

def malformedNamingDatumBytes : List Nat := expectedNamingDatumBytes.dropLast

def serialiseInsertRequest (request : Request) : Option (List Nat) :=
  (encodeInsertRequest request).map serialiseWireData

def deserialiseInsertCommitment (bytes : List Nat) : Option Proposal :=
  (deserialiseWireData bytes).bind decodeInsertCommitment

def deserialiseInsertRequest (request : Request) (bytes : List Nat) : Option Proposal :=
  (deserialiseWireData bytes).bind (decodeInsertRequestCommitment request)

/-! Frozen Insert-token-name bytes for `aliceInsertRequest`. This vector is
independent of the serializer and fixes both constructor layers and proposal
field order. -/
def expectedAliceInsertRequestBytes : List Nat :=
  [216, 121, 159, 216, 121, 159,
   1, 24, 42, 7, 24, 60,
   216, 121, 159,
   216, 121, 159, 1, 24, 42, 8, 0, 255,
   1, 24, 50, 24, 100, 20, 255,
   159, 0, 255, 255, 255]

def malformedAliceInsertRequestBytes : List Nat := expectedAliceInsertRequestBytes.dropLast

def redirectedAliceInsertRequestBytes : List Nat :=
  [216, 121, 159, 216, 121, 159,
   1, 24, 42, 7, 24, 61,
   216, 121, 159,
   216, 121, 159, 1, 24, 42, 8, 0, 255,
   1, 24, 50, 24, 100, 20, 255,
   159, 0, 255, 255, 255]

def redirectedAliceInsertProposal : Proposal :=
  { aliceInsertProposal with refundAddress := demoRefundAddress + 1 }

end Singular
