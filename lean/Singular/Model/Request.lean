import Singular.Model.Registry

/-! Request records and their tuple-bound approvals. -/

namespace Singular
open Lean

def edgeOrdinal (e : Edge) : UInt8 :=
  match e with
  | .insertAbsent => 0 | .insertActive => 1 | .updateActive => 2
  | .updateTerminal => 3 | .deleteAbsent => 4 | .deleteActive => 5
  | .witnessTerminal => 6

/-- The model's stand-in for `blake2b_256(edge ‖ key ‖ owner ‖ destination)`: a
canonical commitment over the scoping tuple. The executable consumer supplies
the real hash; the model fixes the complete preimage and binds the name to the
tuple it commits to. -/
def approvalAssetName (e : Edge) (key owner destination : Nat) : Nat :=
  ((fnv1a [edgeOrdinal e, key.toUInt8, owner.toUInt8, destination.toUInt8]) &&& 0xFFFFFFFF).toNat

/-- An approval scoped by the tuple `(edge, key, owner, destination)` (approval-asset-binding,
#157's frozen contract). Its asset name is the canonical commitment over its
tuple; the model stands in for `blake2b_256`. It carries the signatures its
policy certified it on. It is evidence, never a consumable: the fold burns
nothing. -/
structure Approval where
  policy : Nat
  edge : Edge
  key : Key
  owner : Nat
  destination : Nat
  assetName : Nat
  signatures : List (List Nat) := []
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- One request: apply one of the seven edges to one key. `owner` is the
controller (or, for the absent edges, the refund address) the request acts for;
the refund address is named by `insertAbsent`; `deposit` is the value an
absent insertion holds; `output` is where active tokens are routed; `approval` is the admission evidence; `claimed`
is the mint the transaction claims for this request, summed by the fold; `tip`
is what the request holds beyond its deposit (on chain `held − deposit`);
`reference` names the output reference the request sits at, the one a
retraction's return is bound to; `datum` is the datum the request carries for its
delivered output, or none. -/
structure Request where
  make ::
  edge : Edge
  key : Key
  owner : Nat := 0
  refundAddress : Nat := 0
  deposit : Nat := 0
  output : Nat := 0
  approval : Option Approval := none
  claimed : List (TokenKind × Int) := []
  tip : Nat := 0
  reference : Nat := 0
  /-- The datum the request carries for its delivered output, or none. On chain a
  request's destination is an address and the datum itself, and the receiving
  output must carry exactly it: no datum when the request carries none. -/
  datum : Option Nat := none
  /-- The time the request was booked, in milliseconds since the epoch, as its datum carries it. -/
  submittedAt : Nat := 0
  /-- Abstract identity of the registry the request was booked into, allocated by the consumer. -/
  registryId : Nat := 0
  deriving Repr, BEq, DecidableEq

/-- A request that holds nothing beyond its deposit, given field by field in
declaration order. It sits at reference 0. -/
@[reducible] def Request.mk (edge : Edge) (key : Key) (owner refundAddress deposit output : Nat)
    (approval : Option Approval) (claimed : List (TokenKind × Int)) : Request :=
  Request.make edge key owner refundAddress deposit output approval claimed 0 0 none 0 0

/-- A request serialises completely too, so a corpus row carries the exact input
the fold was given. -/
instance : ToJson Request where
  toJson r := Json.mkObj
    [ ("edge", toJson r.edge), ("key", toJson r.key), ("owner", toJson r.owner)
    , ("refundAddress", toJson r.refundAddress), ("deposit", toJson r.deposit)
    , ("tip", toJson r.tip)
    , ("reference", toJson r.reference)
    , ("submittedAt", toJson r.submittedAt)
    , ("registryId", toJson r.registryId)
    , ("output", toJson r.output)
    , ("datum", datumJson r.datum)
    , ("approval", match r.approval with | none => Json.null | some a => toJson a)
    , ("claimed", Json.arr ((r.claimed.map fun d =>
        Json.mkObj [("kind", toJson d.1), ("quantity", toJson d.2)]).toArray)) ]

/-- The datum form a fold gives the output it delivers to: inline when the request
carries a datum, none when it carries none, as the chain requires. -/
def deliveredDatum (r : Request) : DatumForm := datumFormOf r.datum

/-- The destination a request names: the cage sentinel `0` for
`insertAbsent`; otherwise the output the request named. -/
def requestDestination (r : Request) : Nat :=
  if r.edge == .insertAbsent then 0 else r.output

end Singular
