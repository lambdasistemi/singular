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
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The booking observes the request output, both tag mints and the holdings
spent from application custody. The input list is checked against the world's
actual holdings, never trusted as its own source. Funding and fee balance, and
execution of the application's release rule, are outside this observation. -/
structure TerminationBooking where
  request : TerminationRequest
  custodyInputs : List Holding
  syntaxTagsMinted : List TokenId
  applicationTagsMinted : List Approval
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

end Singular
