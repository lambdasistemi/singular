import Singular.Model.Request

/-! Registration requests and the transactions that book them. Existing fold
requests and transaction encodings retain their historical meaning. -/

namespace Singular
open Lean

/-- The syntax tag uses the registry identity as an abstract policy and name
one, distinct from the state token's name zero. Relating these abstract pairs
to real policies and names is a later correspondence obligation. -/
def Config.syntaxTag (c : Config) : TokenId := ⟨c.registryId, 1⟩

/-- The contents of the request output. Tags are represented in their own
compartments, including their multiplicity, rather than extending the old
fold's asset vocabulary. Other assets cannot be concealed as either tag.
The application tag carries the tuple its policy certified; this model does
not execute the application's authorization rule. -/
structure BookingContents where
  lovelace : Nat
  applicationTags : List Approval
  syntaxTags : List TokenId
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
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- One booking transaction's request output, finite interval and tag mints.
This is the booking judgement's observation extent, not a general ledger
transaction or a builder. The two mint fields count exactly the tags minted
with this request; ordinary funding and ledger fee balance are outside this
booking-only model. -/
structure RegistrationBooking where
  request : RegistrationRequest
  interval : Interval
  syntaxTagsMinted : List TokenId
  applicationTagsMinted : List Approval
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

end Singular
