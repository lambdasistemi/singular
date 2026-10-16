import Singular.Model.Booking

/-! Termination requests and the observed custody inputs of their booking.
The registry's fold request and its written form are unchanged. -/

namespace Singular
open Lean

/-- A singular tag identifies its registry as well as the active policy and
key's abstract asset name. This is an identity model, not a Cardano byte
encoding. Existing holdings belong to the registry that contains them. -/
structure SingularTag where
  registryId : Nat
  token : TokenId
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The active policy and key name are already the registry's singular asset;
the registry identity prevents a foreign registry's tag being substituted. -/
def Config.singularTag (c : Config) (key : Key) : SingularTag :=
  ⟨c.registryId, ⟨c.activePolicy, key⟩⟩

/-- A termination declares its tip and carrier separately from held value.
Optional refund and clock fields let the judgement reject malformed submitted
requests; both must be absent in every admitted request. -/
structure TerminationRequest where
  reference : OutRef
  registryId : Nat
  key : Key
  destination : Nat
  declaredTip : Nat
  carrierAda : Nat
  singularTags : List SingularTag
  contents : BookingContents
  refundAddress : Option Nat := none
  submittedAt : Option Nat := none
  nonce : Nat := 0
  deriving Repr, BEq, DecidableEq

instance : ToJson TerminationRequest where
  toJson r := Json.mkObj (
    [("reference", toJson r.reference), ("registryId", toJson r.registryId),
     ("key", toJson r.key), ("destination", toJson r.destination),
     ("declaredTip", toJson r.declaredTip), ("carrierAda", toJson r.carrierAda),
     ("singularTags", toJson r.singularTags), ("contents", toJson r.contents),
     ("refundAddress", toJson r.refundAddress), ("submittedAt", toJson r.submittedAt)] ++
    if r.nonce = 0 then [] else [("nonce", toJson r.nonce)])

instance : FromJson TerminationRequest where
  fromJson? j := do
    let reference ← j.getObjVal? "reference" >>= fromJson?
    let registryId ← j.getObjVal? "registryId" >>= fromJson?
    let key ← j.getObjVal? "key" >>= fromJson?
    let destination ← j.getObjVal? "destination" >>= fromJson?
    let declaredTip ← j.getObjVal? "declaredTip" >>= fromJson?
    let carrierAda ← j.getObjVal? "carrierAda" >>= fromJson?
    let singularTags ← j.getObjVal? "singularTags" >>= fromJson?
    let contents ← j.getObjVal? "contents" >>= fromJson?
    let refundAddress ← j.getObjVal? "refundAddress" >>= fromJson?
    let submittedAt ← j.getObjVal? "submittedAt" >>= fromJson?
    let nonce ← match j.getObjVal? "nonce" with
      | .error _ => pure 0
      | .ok value => fromJson? value
    pure { reference, registryId, key, destination, declaredTip, carrierAda, singularTags, contents, refundAddress, submittedAt, nonce }

def TerminationRequest.operation (r : TerminationRequest) : BookingOperation :=
  .termination r.key r.destination

def TerminationRequest.trieReadyTag (r : TerminationRequest) (c : Config) : TokenId :=
  c.trieReadyTag (trieReadyTagAssetName r.operation r.nonce)

/-- The booking observes the request output, the trie-ready tag mint and the holdings
spent from application custody. The input list is checked against the world's
actual holdings, never trusted as its own source. Funding and fee balance, and
execution of the application's release rule, are outside this observation. -/
structure TerminationBooking where
  request : TerminationRequest
  custodyInputs : List Holding
  trieReadyTagsMinted : List TokenId
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

end Singular
