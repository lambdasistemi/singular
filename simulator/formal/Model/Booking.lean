import Singular.Model.Request

/-! Registration requests and the transactions that book them. Existing fold
requests and transaction encodings retain their historical meaning. -/

namespace Singular
open Lean

/-- The trie-ready tag uses the registry's abstract policy and a positive
encoding of its commitment. Zero remains reserved for the state token,
whatever value the commitment takes. Real policy and hash correspondence is
a separate obligation. -/
def Config.trieReadyTag (c : Config) (commitment : Nat) : TokenId :=
  ⟨c.registryId, commitment + 1⟩

/-- Hash a complete canonical preimage, encoding every natural in full.
This executable stand-in assumes neither injectivity nor cryptographic
collision resistance. The domain separates payload and operation names. -/
def bookingCommitment (domain : Nat) (fields : List Nat) : Nat :=
  (fnv1a (toJson (domain :: fields)).compress.toUTF8.data.toList).toNat

/-- Registration payload: edge, key, refund address, destination and nonce.
The historical approval commitment remains unchanged. -/
def applicationTagAssetName (key refundAddress destination nonce : Nat) : Nat :=
  bookingCommitment 0 [(edgeOrdinal .insertActive).toNat, key, refundAddress, destination, nonce]

/-- An operation includes its kind and complete declared payload. Registration
also commits its cost, tip and carrier; termination commits key and destination.
The nonce is supplied once, from the request. -/
inductive BookingOperation where
  | registration (key refundAddress destination registrationCost declaredTip carrierAda : Nat)
  | termination (key destination : Nat)
  deriving Repr, BEq, DecidableEq

def trieReadyTagAssetName (operation : BookingOperation) (nonce : Nat) : Nat :=
  bookingCommitment 1 ((match operation with
    | .registration key refundAddress destination cost tip carrier =>
      [0, key, refundAddress, destination, cost, tip, carrier]
    | .termination key destination => [1, key, destination]) ++ [nonce])

/-- The contents of the request output. Tags are represented in their own
compartments, including their multiplicity, rather than extending the old
fold's asset vocabulary. Other assets cannot be concealed as either tag.
The application tag carries the tuple its policy certified; this model does
not execute the application's authorization rule. -/
structure BookingContents where
  lovelace : Nat
  applicationTags : List Approval
  trieReadyTags : List TokenId
  otherAssets : List (TokenId × Nat) := []
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- A registration's declarations are distinct from the value its output
actually holds. Carrier ada is a declared allocation, not a ledger minimum.
The datum is the application's unrestricted destination datum identity. -/
structure RegistrationRequest where
  reference : OutRef
  registryId : Nat
  key : Key
  refundAddress : Nat
  destination : Nat
  submittedAt : Nat
  registrationCost : Nat
  declaredTip : Nat
  carrierAda : Nat
  contents : BookingContents
  datum : Option Nat := none
  nonce : Nat := 0
  deriving Repr, BEq, DecidableEq

/-- Keep the default-zero nonce absent from the pre-existing written form. -/
instance : ToJson RegistrationRequest where
  toJson r := Json.mkObj (
    [("reference", toJson r.reference), ("registryId", toJson r.registryId),
     ("key", toJson r.key), ("refundAddress", toJson r.refundAddress),
     ("destination", toJson r.destination), ("submittedAt", toJson r.submittedAt),
     ("registrationCost", toJson r.registrationCost), ("declaredTip", toJson r.declaredTip),
     ("carrierAda", toJson r.carrierAda), ("contents", toJson r.contents),
     ("datum", toJson r.datum)] ++ if r.nonce = 0 then [] else [("nonce", toJson r.nonce)])

instance : FromJson RegistrationRequest where
  fromJson? j := do
    let reference ← j.getObjVal? "reference" >>= fromJson?
    let registryId ← j.getObjVal? "registryId" >>= fromJson?
    let key ← j.getObjVal? "key" >>= fromJson?
    let refundAddress ← j.getObjVal? "refundAddress" >>= fromJson?
    let destination ← j.getObjVal? "destination" >>= fromJson?
    let submittedAt ← j.getObjVal? "submittedAt" >>= fromJson?
    let registrationCost ← j.getObjVal? "registrationCost" >>= fromJson?
    let declaredTip ← j.getObjVal? "declaredTip" >>= fromJson?
    let carrierAda ← j.getObjVal? "carrierAda" >>= fromJson?
    let contents ← j.getObjVal? "contents" >>= fromJson?
    let datum ← j.getObjVal? "datum" >>= fromJson?
    let nonce ← match j.getObjVal? "nonce" with
      | .error _ => pure 0
      | .ok value => fromJson? value
    pure { reference, registryId, key, refundAddress, destination, submittedAt, registrationCost, declaredTip, carrierAda, contents, datum, nonce }

def RegistrationRequest.operation (r : RegistrationRequest) : BookingOperation :=
  .registration r.key r.refundAddress r.destination r.registrationCost r.declaredTip r.carrierAda

def RegistrationRequest.trieReadyTag (r : RegistrationRequest) (c : Config) : TokenId :=
  c.trieReadyTag (trieReadyTagAssetName r.operation r.nonce)

/-- One booking transaction's request output, finite interval and tag mints.
This is the booking judgement's observation extent, not a general ledger
transaction or a builder. The two mint fields count exactly the tags minted
with this request; ordinary funding and ledger fee balance are outside this
booking-only model. -/
structure RegistrationBooking where
  request : RegistrationRequest
  interval : Interval
  trieReadyTagsMinted : List TokenId
  applicationTagsMinted : List Approval
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

end Singular
