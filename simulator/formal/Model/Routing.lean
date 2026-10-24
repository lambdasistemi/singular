import Singular.Model.Fold

/-! Transaction pins, commitments, routing and input/output constructors. -/

namespace Singular
open Lean

/-! ### The transaction row

A fold is also a transaction, and the cage reads its inputs, outputs, datums and
mint rather than the logical step. This section names the transaction-level
obligations of an admitted fold so a consumer can check the shape it must build
and so an exported row is computed rather than asserted.

Three of them are modelling constants rather than derivations, and are named as
such: the registry is a single state UTxO carrying one state token (`step`
consumes one state and produces one), and both the state datum and the
destination datum are inline because the cage reads them without a preimage.
Everything else below is read off the model. -/

/-- The state token count of the registry's single state UTxO. -/
def registryStateTokens : Nat := 1

/-- The cage reads the state and the destination datum directly, so both are
inline. -/
def registryDatumForm : DatumForm := .inline

/-- The approvals a request carries. An admitted tree edge carries exactly one;
a request with none is refused `no-approval` before it can spend anything. -/
def approvalsIn (r : Request) : Nat := r.approval.toList.length

/-- Every pin of the configuration except the root is unchanged: the state
output carries the same datum with one field moved. -/
def onlyRootChanged (before after : Config) : Bool :=
  after.registryId == before.registryId && after.processTime == before.processTime &&
  after.retractTime == before.retractTime &&
  after.applicationPolicy == before.applicationPolicy &&
  after.activePolicy == before.activePolicy &&
  after.registrationCost == before.registrationCost &&
  after.minimumTip == before.minimumTip &&
  after.bookingWidth == before.bookingWidth

/-- The datum the destination output carries: the scoping tuple of the request
it settles. -/
structure DestinationDatum where
  edge : Edge
  key : Key
  owner : Nat
  destination : Nat
  deriving Repr, BEq, DecidableEq

def destinationDatum (r : Request) : DestinationDatum :=
  { edge := r.edge, key := r.key, owner := r.owner, destination := requestDestination r }

/-- The canonical commitment of a destination datum, under the same function the
approval's asset name commits with. The output's datum hash and the asset name
admission verified are therefore the same value, or admission is not binding the
output the fold produces. -/
def datumHash (d : DestinationDatum) : Nat :=
  approvalAssetName d.edge d.key d.owner d.destination

/-- The destination output's inline datum hashes to the commitment the request's
approval carries. False when the request carries no approval at all. -/
def destinationDatumBinds (r : Request) : Bool :=
  match r.approval with
  | none => false
  | some ap => datumHash (destinationDatum r) == ap.assetName

/-- The signers a fold requires: none. The open registry's fold is
permissionless — neither `refusal` nor `applyEdge` reads a signature, which is
stated as invariance under the approval's signature set. -/
def requiredSigners (_r : Request) : List Nat := []

/-- The same request with its approval carrying a different signature set. A
request without an approval has no signature set to change and is returned as
it is. -/
def withSignatures (r : Request) (sigs : List (List Nat)) : Request :=
  { r with approval := r.approval.map fun ap => { ap with signatures := sigs } }

/-- The open application's parameters: none. The open registry protects nobody
by design, so there is no registry identity to apply the policy to; one policy
id, one blueprint, no applied hash to derive. -/
def openPolicyParameters : List Nat := []

/-- The approval anyone can mint under the open application for a tuple. Nothing
guards its creation: that is what makes the open policy's admission universal. -/
def openApproval (c : Config) (r : Request) : Approval :=
  { policy := c.applicationPolicy, edge := r.edge, key := r.key, owner := r.owner
  , destination := requestDestination r
  , assetName := approvalAssetName r.edge r.key r.owner (requestDestination r) }

/-- A bounded grid of scoping tuples, used to exhibit universal admission on a
finite extent beside the quantified statement that proves it. -/
def openTupleGrid : List Request :=
  let edges : List Edge :=
    [.insertAbsent, .insertActive, .updateActive, .updateTerminal,
     .deleteAbsent, .deleteActive, .witnessTerminal]
  let nums : List Nat := [0, 1, 42, 255]
  edges.flatMap fun e => nums.flatMap fun k => nums.flatMap fun o => nums.map fun d =>
    ({ edge := e, key := k, owner := o, output := d } : Request)

/-- The open policy admits every tuple in the grid. -/
def openAdmitsEveryTuple (c : Config) : Bool :=
  openTupleGrid.all fun r => admitsFor c r (some (openApproval c r))

/-- Cross-registry separation, observed between two registries. It would hold if
an approval admitted by the first were refused by the second; under the open
policy it never is, which is the named non-goal: replaying an approval into
another registry pinning the same policy grants nothing that registry did not
already grant everyone. -/
def crossRegistrySeparation (c₁ c₂ : Config) (r : Request) : Bool :=
  admitsFor c₁ r (some (openApproval c₁ r)) && !admitsFor c₂ r (some (openApproval c₁ r))

/-! ### The transaction itself

Everything above names one obligation at a time, and three of those names are
nullary constants: a statement that `registryStateTokens = 1` is `rfl` and
settles nothing about a transaction. This section builds the transaction, from
the executed step, so a statement can quantify over a constructed value — every
input, every output, the datums they present, the assets they carry, the exact
mint, the destination the tokens are routed to, and the signatures required. -/

/-- The minted assets this request routes to one destination, read off the
executed result's mint through the model's own routing rule. -/
def mintRoutedTo (t : Result) (r : Request) (d : Destination) : List (Asset × Int) :=
  t.mint.filter fun p => route p.1.1 r == d

/-- What an output routed here actually holds. A routed delta is a payment only
when it is positive: a burn pays nobody, and an output holding a negative
quantity is not an output. The tokens a burn destroys enter through
`txBurnInputs` instead. -/
def routedPayment (t : Result) (r : Request) (d : Destination) : List (Asset × Int) :=
  (mintRoutedTo t r d).filter fun p => 0 < p.2

/-- Where a token of a kind already lives, and therefore which UTxO a fold
spends to destroy one: a requester holds the active witness at the output
the fold that minted it named. Read off `route`, so the token is consumed from the place the same rule
sent it to. -/
def burnSourceRole (d : Destination) : TxRole :=
  match d with
  | .requestOutput => .witness

/-- The datum form of the output holding a token of this kind at this key: the
form of the datum the fold that delivered it wrote. A fold burning a witness is
refused `token-missing` unless the state holds one, so the fallback is never read
for an admitted fold. -/
def heldDatum (s : RegistryState) (key : Key) (kind : TokenKind) : DatumForm :=
  match s.held.find? (fun h => h.key == key && h.kind == kind) with
  | some h => datumFormOf h.datum
  | none => registryDatumForm

/-- The datum value the output holding a token of this kind at this key carries:
the datum the fold that delivered it wrote, the request's own. -/
def heldValue (s : RegistryState) (key : Key) (kind : TokenKind) : Option Nat :=
  (s.held.find? (fun h => h.key == key && h.kind == kind)).bind (·.datum)

/-- The datum form of the UTxO a burned token is spent from: a witness carries whatever its
delivering fold gave the output it sits at (#304). -/
def burnSourceDatum (s : RegistryState) (d : Destination) (asset : Asset) : DatumForm :=
  match d with
  | .requestOutput => heldDatum s asset.2 asset.1

/-- The datum value of the UTxO a burned token is spent from: a witness carries the
datum its delivery wrote. -/
def burnSourceValue (s : RegistryState) (d : Destination) (asset : Asset) : Option Nat :=
  match d with
  | .requestOutput => heldValue s asset.2 asset.1

/-- The inputs that supply the tokens this fold destroys: one UTxO per burned
asset, carrying exactly that asset in the quantity the mint takes away, at the
place the model says that kind of token lives, presenting the datum the state
before the fold says it carries. A fold that burns nothing spends none of them,
which is why `insertActive` still has two inputs. -/
def txBurnInputs (s : RegistryState) (t : Result) (r : Request) : List TxInput :=
  t.mint.filterMap fun p =>
    if p.2 < 0 then
      some { role := burnSourceRole (route p.1.1 r)
           , datum := burnSourceDatum s (route p.1.1 r) p.1
           , stateTokens := 0, approvals := 0, lovelace := 0
           , assets := [(p.1, -p.2)]
           , datumValue := burnSourceValue s (route p.1.1 r) p.1 }
    else none

/-- The state output: the registry's single state UTxO, moved, carrying the
configuration the step produced under an inline datum. -/
def txStateOutput (t : Result) : TxOutput :=
  { role := .state, datum := registryDatumForm, address := none
  , stateTokens := registryStateTokens, config := some t.state.config
  , commitment := none, assets := [], stateToken := some t.state.config.stateToken }

/-- The destination output, present only when this edge routes a token to the
requester: routed to the address the request named, carrying exactly the datum
the request carries — inline with that value, or none when it carries none, as
the chain requires — with the scoping tuple's commitment, and holding exactly the
tokens the edge routed there. A fold that delivers nothing has no such output, so
the model describes only outputs that exist. -/
def txDestinationOutputs (t : Result) (r : Request) : List TxOutput :=
  let assets := routedPayment t r .requestOutput
  if assets.isEmpty then []
  else [{ role := .destination
        , datum := deliveredDatum r
        , address := some (requestDestination r), stateTokens := 0, config := none
        , commitment := some (datumHash (destinationDatum r))
        , assets := assets, datumValue := r.datum }]


end Singular
