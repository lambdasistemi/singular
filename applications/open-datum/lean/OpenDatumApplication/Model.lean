import Singular.Model

/-! # The open-datum application

An application pinned by a registry as its application policy. One script is
both the approval policy the registry reads and the spending contract that holds
each active token it certifies:

* insertion: the controller authorizes, at booking, one approval binding the
  registry key, itself as owner, and a destination that names this contract and
  the hash of a control envelope with an arbitrary payload; the permissionless
  registry fold then delivers the active token and the insertion deposit to that
  destination, where they stay;
* update: the controller changes the payload; protected control, token and
  deposit floor are preserved at the same contract;
* termination: the controller authorizes, at booking, an `updateTerminal`
  approval for the same key while the token stays locked; the registry fold of
  that request burns the token, commits Terminal, and only in that same
  transaction releases the protected deposit, paid additively with what the
  registry itself owes the controller.

The generic registry law is imported unchanged: every registry effect below is
`Singular.exitStep` or `Singular.foldBatch` of the unchanged model, every
registry payment is `Singular.obligations`, and settlement is the unchanged
`Singular.settle` over the concatenated payments.

Representation choices, stated rather than hidden:

* `PlutusData` is an abstract executable data type with the five Plutus
  constructors; its serialization and `envelopeHash` stand in for CBOR and
  blake2b-256 and claim no byte agreement with either;
* the contract's address and policy are one identity, `App.policy`, as one
  script is both;
* the registry model names a request's destination by one number; the
  application encodes its (address, envelope hash) pair into it by
  `destinationOf`, injective while the hash is below `2^64`. -/

namespace OpenDatumApplication

open Singular
open Lean

/-- Arbitrary Plutus data: constructors, maps, lists, integers and bytes. No
business schema is imposed on it. -/
inductive PlutusData where
  | constr (tag : Nat) (fields : List PlutusData)
  | map (entries : List (PlutusData × PlutusData))
  | list (items : List PlutusData)
  | int (value : Int)
  | bytes (value : List UInt8)
  deriving Repr, BEq, Inhabited

/-- The registry's state asset: the policy and asset name of the one token its
state UTxO carries. It is what identifies a registry, and what the application
is parameterized by. -/
structure StateAsset where
  policy : Nat
  assetName : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The protected control of one application output. Every field is preserved
by an update; only a release consumes it. -/
structure Control where
  version : Nat
  registry : StateAsset
  activePolicy : Nat
  key : Key
  controller : Nat
  deposit : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The versioned control envelope: protected control beside a free payload. -/
structure Envelope where
  control : Control
  payload : PlutusData
  deriving Repr, BEq

/-- The envelope version this model defines. -/
def envelopeVersion : Nat := 1

/-- The application, parameterized by the registry state asset it serves.
`policy` is the script's hash: its approval policy id and its address. -/
structure App where
  registry : StateAsset
  policy : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The contract's own address. -/
def appAddress (app : App) : Nat := app.policy

/-- A serialization of Plutus data into numbers; the stand-in for CBOR. -/
partial def PlutusData.encode : PlutusData → List Nat
  | .constr tag fields => [0, tag, fields.length] ++ fields.flatMap PlutusData.encode
  | .map entries =>
    [1, entries.length] ++ entries.flatMap fun p => p.1.encode ++ p.2.encode
  | .list items => [2, items.length] ++ items.flatMap PlutusData.encode
  | .int value => [3, if value < 0 then 1 else 0, value.natAbs]
  | .bytes value => [4, value.length] ++ value.map (·.toNat)

/-- The control fields in their fixed order. -/
def controlFields (c : Control) : List Nat :=
  [c.version, c.registry.policy, c.registry.assetName, c.activePolicy, c.key,
    c.controller, c.deposit]

/-- The envelope's commitment; the stand-in for blake2b-256 of its inline
datum. Abstract: no equality with a concrete hash is claimed. -/
def envelopeHash (e : Envelope) : Nat :=
  (fnv1a ((controlFields e.control ++ e.payload.encode).flatMap
    fun n => u64bytes (UInt64.ofNat n))).toNat

/-- The destination a request names for an application output: this contract's
address and the envelope hash, in the one number the registry model carries. -/
def destinationOf (app : App) (e : Envelope) : Nat :=
  appAddress app * 2 ^ 64 + envelopeHash e

/-- One live output at the application contract. `ref` is the output reference
identity the model allocates when the output is created. -/
structure AppOutput where
  ref : Nat
  address : Nat
  lovelace : Nat
  assets : List (Asset × Int)
  envelope : Envelope
  deriving Repr, BEq

/-- An output an update proposes, before the model allocates its reference. -/
structure Successor where
  address : Nat
  lovelace : Nat
  assets : List (Asset × Int)
  envelope : Envelope
  deriving Repr, BEq

/-- Whether an output holds exactly the one active token of this key. -/
def carriesKey (assets : List (Asset × Int)) (key : Key) : Bool :=
  assets.any fun a => a.1 == (TokenKind.active, key) && a.2 == 1

/-- A booked request, and for an insertion the envelope its destination binds. -/
structure Pending where
  request : Request
  envelope : Option Envelope
  deriving BEq

/-- The world the application runs in: the registry, the state asset its state
UTxO carries, the live application outputs and the booked requests. -/
structure World where
  app : App
  registry : RegistryState
  registryAsset : StateAsset
  outputs : List AppOutput
  pending : List Pending
  nextRef : Nat
  deriving BEq

/-- An empty registry under a configuration that pins this application. -/
def genesis (app : App) (c : Config) (asset : StateAsset) : World :=
  { app := app
  , registry := { config := { c with root := rootOf [] }, trie := [], custody := []
                , held := [] }
  , registryAsset := asset, outputs := [], pending := [], nextRef := 0 }

/-- The approval this application mints for a request, certified by the
signatures on the booking. -/
def mintApproval (app : App) (r : Request) (signatures : List Nat) : Approval :=
  { policy := app.policy, edge := r.edge, key := r.key, owner := r.owner
  , destination := requestDestination r
  , assetName := approvalAssetName r.edge r.key r.owner (requestDestination r)
  , signatures := [signatures] }

/-- The booked request: the minted approval attached and the edge's delta
claimed. -/
def booked (app : App) (r : Request) (signatures : List Nat) : Request :=
  { r with approval := some (mintApproval app r signatures), claimed := delta r.edge }

/-- One action on the world. `withdraw` is every spend of an application output
that is neither an update nor a release. -/
inductive AppAction where
  | bookInsert (request : Request) (envelope : Envelope) (signatures : List Nat)
  | foldInsert (key : Key)
  | update (ref : Nat) (successors : List Successor) (signatures : List Nat)
  | bookTerminate (request : Request) (ref : Nat) (signatures : List Nat)
  | foldRelease (keys : List Key) (exit : Exit) (outputs : List TxOutput)
  | withdraw (ref : Nat) (outputs : List TxOutput)

/-- Refuse with a reason unless the condition holds. -/
def ensure (condition : Bool) (why : String) : Except String Unit :=
  if condition then .ok () else .error why

/-- The live output at a reference. -/
def outputAt (w : World) (ref : Nat) : Option AppOutput :=
  w.outputs.find? (·.ref == ref)

/-- The live output holding a key's active token at this contract. -/
def outputOfKey (w : World) (key : Key) : Option AppOutput :=
  w.outputs.find? fun o => o.address == appAddress w.app && carriesKey o.assets key

/-- The booked request of an edge at a key. -/
def pendingOf (w : World) (edge : Edge) (key : Key) : Option Pending :=
  w.pending.find? fun p => p.request.edge == edge && p.request.key == key

/-- Booking an insertion: the application mints its approval only when the
controller signs and the envelope binds this registry, its active policy, the
key, the controller as owner, this contract as destination and the request's
deposit as the protected amount. The registry state is untouched; whether the
key may be inserted is the fold's question, not the application's. -/
def bookInsertStep (w : World) (r : Request) (e : Envelope) (signatures : List Nat) :
    Except String World := do
  ensure (r.edge == .insertActive) "app-insert-edge"
  ensure (w.registry.config.applicationPolicy == w.app.policy) "app-not-pinned"
  ensure (e.control.version == envelopeVersion) "app-envelope-version"
  ensure (e.control.registry == w.app.registry) "app-registry"
  ensure (e.control.activePolicy == w.registry.config.activePolicy) "app-active-policy"
  ensure (e.control.key == r.key) "app-key"
  ensure (e.control.controller == r.owner) "app-owner"
  ensure (signatures.contains e.control.controller) "app-controller-signature"
  ensure (r.output == destinationOf w.app e) "app-destination"
  ensure (e.control.deposit == r.deposit) "app-deposit"
  pure { w with pending := w.pending ++ [{ request := booked w.app r signatures
                                          , envelope := some e }] }

/-- The permissionless fold of a booked insertion: exactly the registry's
`insertActive` fold, and the output it delivers is this contract's, carrying the
token, the insertion deposit and the bound envelope. A refused fold leaves the
request booked. -/
def foldInsertStep (w : World) (key : Key) : Except String World := do
  let some p := pendingOf w .insertActive key | .error "no-pending-request"
  let some e := p.envelope | .error "no-pending-request"
  let t ← exitStep w.registry (.fold .insertActive) p.request
  let out : AppOutput :=
    { ref := w.nextRef, address := appAddress w.app, lovelace := p.request.deposit
    , assets := [((.active, key), 1)], envelope := e }
  pure { w with registry := t.state, outputs := w.outputs ++ [out]
              , pending := w.pending.erase p, nextRef := w.nextRef + 1 }

/-- An update: the controller signs, exactly one proposed output carries the
token, and it stays at this contract with the same control, the same assets and
at least the protected deposit. The payload is free. -/
def updateStep (w : World) (ref : Nat) (successors : List Successor)
    (signatures : List Nat) : Except String World := do
  let some o := outputAt w ref | .error "no-application-output"
  let c := o.envelope.control
  ensure (signatures.contains c.controller) "update-controller-signature"
  let carrying := successors.filter fun s => carriesKey s.assets c.key
  let some s := (match carrying with | [s] => some s | _ => none) | .error "update-token"
  ensure (s.address == appAddress w.app) "update-escape"
  ensure (s.envelope.control == c) "update-control"
  ensure (s.assets == o.assets) "update-assets"
  ensure (c.deposit ≤ s.lovelace) "update-deposit"
  let next : AppOutput :=
    { ref := w.nextRef, address := s.address, lovelace := s.lovelace, assets := s.assets
    , envelope := s.envelope }
  pure { w with outputs := (w.outputs.erase o) ++ [next], nextRef := w.nextRef + 1 }

/-- Booking a termination: the controller signs an `updateTerminal` approval
for the key its live output holds, naming no destination. The output, its token
and its deposit stay locked. -/
def bookTerminateStep (w : World) (r : Request) (ref : Nat) (signatures : List Nat) :
    Except String World := do
  ensure (r.edge == .updateTerminal) "app-terminate-edge"
  ensure (w.registry.config.applicationPolicy == w.app.policy) "app-not-pinned"
  let some o := outputAt w ref | .error "no-application-output"
  let c := o.envelope.control
  ensure (o.address == appAddress w.app && carriesKey o.assets r.key) "app-terminate-token"
  ensure (c.key == r.key && c.registry == w.app.registry) "app-terminate-binding"
  ensure (r.owner == c.controller) "app-owner"
  ensure (signatures.contains c.controller) "app-controller-signature"
  ensure (r.output == 0) "app-terminate-destination"
  pure { w with pending := w.pending ++ [{ request := booked w.app r signatures
                                          , envelope := none }] }

/-- What the application releases for one output: its protected deposit, to its
controller's key. -/
def releaseOf (o : AppOutput) : Payment :=
  { recipient := .owner o.envelope.control.controller, atLeast := o.envelope.control.deposit }

/-- The registry's own payments for the folded requests. -/
def registryPayments (exit : Exit) (requests : List Request) : List Payment :=
  requests.flatMap (obligations exit)

/-- Release: one transaction folding the booked `updateTerminal` requests of
these keys, spending each key's application output, burning each active token
through the registry's own fold, and paying every controller the SUM of what the
registry owes it and the deposits released to it. Every other exit, an unrelated
registry, a missing booking or output, and a short sum release nothing. -/
def foldReleaseStep (w : World) (keys : List Key) (exit : Exit)
    (outputs : List TxOutput) : Except String World := do
  ensure (!keys.isEmpty) "release-no-fold"
  ensure (exit == .fold .updateTerminal) "release-needs-terminal-fold"
  ensure (w.registryAsset == w.app.registry) "release-registry"
  let rows ← keys.mapM fun key => do
    let some p := pendingOf w .updateTerminal key | .error "no-pending-request"
    let some o := outputOfKey w key | .error "no-application-output"
    ensure (p.request.owner == o.envelope.control.controller) "release-controller"
    pure (p, o)
  let requests := rows.map (·.1.request)
  let spent := rows.map (·.2)
  let t ← foldBatch w.registry requests
  match settle (registryPayments exit requests ++ spent.map releaseOf) outputs with
  | some why => .error why
  | none =>
    pure { w with registry := t.state
                , outputs := w.outputs.filter fun o => !spent.contains o
                , pending := w.pending.filter fun p => !(rows.map (·.1)).contains p }

/-- The contract has exactly two spending paths; anything else is refused. -/
def withdrawStep (w : World) (ref : Nat) (_outputs : List TxOutput) :
    Except String World := do
  let some _ := outputAt w ref | .error "no-application-output"
  .error "no-withdrawal-path"

/-- The application law. -/
def appStep (w : World) : AppAction → Except String World
  | .bookInsert r e sigs => bookInsertStep w r e sigs
  | .foldInsert key => foldInsertStep w key
  | .update ref succs sigs => updateStep w ref succs sigs
  | .bookTerminate r ref sigs => bookTerminateStep w r ref sigs
  | .foldRelease keys exit outs => foldReleaseStep w keys exit outs
  | .withdraw ref outs => withdrawStep w ref outs

/-- Worlds reached from a genesis by accepted actions. -/
inductive Reachable : World → Prop where
  | start (app : App) (c : Config) (asset : StateAsset) :
      Reachable (genesis app c asset)
  | next {w w' : World} {a : AppAction} : Reachable w → appStep w a = .ok w' → Reachable w'

/-- Run a list of actions, reporting each outcome and the world reached. -/
def runActions (w : World) : List AppAction → List (Except String Unit) × World
  | [] => ([], w)
  | a :: rest =>
    match appStep w a with
    | .ok w' => let (outs, final) := runActions w' rest; (.ok () :: outs, final)
    | .error why => let (outs, final) := runActions w rest; (.error why :: outs, final)

end OpenDatumApplication
