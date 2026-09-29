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
* `PlutusData` equality is the total structural `PlutusData.beq`, proved to
  be exactly propositional equality (`PlutusData.beq_iff_eq`); the derived
  equality of a nested type would be an opaque `partial` function;
* the contract's address and policy are one identity, `App.policy`, as one
  script is both;
* the registry model names a request's destination by one number; the
  application encodes its (address, envelope hash) pair into it by
  `destinationOf`, injective while the hash is below `2^64`. -/

namespace OpenDatumApplication

open Singular
open Lean

/-- Arbitrary Plutus data: constructors, maps, lists, integers and bytes. No
business schema is imposed on it. Its equality is `PlutusData.beq` below. -/
inductive PlutusData where
  | constr (tag : Nat) (fields : List PlutusData)
  | map (entries : List (PlutusData × PlutusData))
  | list (items : List PlutusData)
  | int (value : Int)
  | bytes (value : List UInt8)
  deriving Repr, Inhabited

/-! `deriving BEq` on this nested type yields an opaque `partial` function, about
which no proof can say anything, so an update's `List.erase` of the output it
replaces could not be shown to remove it. The equality is therefore written out
structurally: same constructor, then equal fields, lists compared element by
element in order, map entries key and value in order. -/

mutual
/-- Total structural equality of Plutus data. -/
def PlutusData.beq : PlutusData → PlutusData → Bool
  | .constr t fs, .constr t' fs' => t == t' && PlutusData.beqList fs fs'
  | .map es, .map es' => PlutusData.beqEntries es es'
  | .list xs, .list ys => PlutusData.beqList xs ys
  | .int a, .int b => a == b
  | .bytes a, .bytes b => a == b
  | _, _ => false

/-- Element-wise equality of two lists of Plutus data. -/
def PlutusData.beqList : List PlutusData → List PlutusData → Bool
  | [], [] => true
  | x :: xs, y :: ys => PlutusData.beq x y && PlutusData.beqList xs ys
  | _, _ => false

/-- Equality of one map entry: key and value. -/
def PlutusData.beqEntry : PlutusData × PlutusData → PlutusData × PlutusData → Bool
  | (k, v), (k', v') => PlutusData.beq k k' && PlutusData.beq v v'

/-- Entry-wise equality of two maps' entry lists, in order. -/
def PlutusData.beqEntries :
    List (PlutusData × PlutusData) → List (PlutusData × PlutusData) → Bool
  | [], [] => true
  | e :: es, e' :: es' => PlutusData.beqEntry e e' && PlutusData.beqEntries es es'
  | _, _ => false
end

instance : BEq PlutusData := ⟨PlutusData.beq⟩

mutual
theorem PlutusData.eq_of_beq' : ∀ a b : PlutusData, PlutusData.beq a b = true → a = b
  | .constr t fs, b, h => by
    cases b with
    | constr t' fs' =>
      simp only [PlutusData.beq, Bool.and_eq_true, beq_iff_eq] at h
      obtain ⟨h1, h2⟩ := h
      rw [h1, PlutusData.eqList_of_beq fs fs' h2]
    | _ => simp [PlutusData.beq] at h
  | .map es, b, h => by
    cases b with
    | map es' =>
      simp only [PlutusData.beq] at h
      rw [PlutusData.eqEntries_of_beq es es' h]
    | _ => simp [PlutusData.beq] at h
  | .list xs, b, h => by
    cases b with
    | list ys =>
      simp only [PlutusData.beq] at h
      rw [PlutusData.eqList_of_beq xs ys h]
    | _ => simp [PlutusData.beq] at h
  | .int x, b, h => by
    cases b with
    | int y =>
      simp only [PlutusData.beq, beq_iff_eq] at h
      rw [h]
    | _ => simp [PlutusData.beq] at h
  | .bytes x, b, h => by
    cases b with
    | bytes y =>
      simp only [PlutusData.beq, beq_iff_eq] at h
      rw [h]
    | _ => simp [PlutusData.beq] at h

theorem PlutusData.eqList_of_beq : ∀ xs ys : List PlutusData,
    PlutusData.beqList xs ys = true → xs = ys
  | [], [], _ => rfl
  | [], _ :: _, h => by simp [PlutusData.beqList] at h
  | _ :: _, [], h => by simp [PlutusData.beqList] at h
  | x :: xs, y :: ys, h => by
    simp only [PlutusData.beqList, Bool.and_eq_true] at h
    rw [PlutusData.eq_of_beq' x y h.1, PlutusData.eqList_of_beq xs ys h.2]

theorem PlutusData.eqEntry_of_beq : ∀ e e' : PlutusData × PlutusData,
    PlutusData.beqEntry e e' = true → e = e'
  | (k, v), (k', v'), h => by
    simp only [PlutusData.beqEntry, Bool.and_eq_true] at h
    rw [PlutusData.eq_of_beq' k k' h.1, PlutusData.eq_of_beq' v v' h.2]

theorem PlutusData.eqEntries_of_beq : ∀ es es' : List (PlutusData × PlutusData),
    PlutusData.beqEntries es es' = true → es = es'
  | [], [], _ => rfl
  | [], _ :: _, h => by simp [PlutusData.beqEntries] at h
  | _ :: _, [], h => by simp [PlutusData.beqEntries] at h
  | e :: es, e' :: es', h => by
    simp only [PlutusData.beqEntries, Bool.and_eq_true] at h
    rw [PlutusData.eqEntry_of_beq e e' h.1, PlutusData.eqEntries_of_beq es es' h.2]
end

mutual
theorem PlutusData.beq_refl : ∀ a : PlutusData, PlutusData.beq a a = true
  | .constr t fs => by
    simp only [PlutusData.beq, Bool.and_eq_true, beq_self_eq_true, true_and]
    exact PlutusData.beqList_refl fs
  | .map es => by
    simp only [PlutusData.beq]
    exact PlutusData.beqEntries_refl es
  | .list xs => by
    simp only [PlutusData.beq]
    exact PlutusData.beqList_refl xs
  | .int x => by simp [PlutusData.beq]
  | .bytes x => by simp [PlutusData.beq]

theorem PlutusData.beqList_refl : ∀ xs : List PlutusData, PlutusData.beqList xs xs = true
  | [] => by simp [PlutusData.beqList]
  | x :: xs => by
    simp only [PlutusData.beqList, Bool.and_eq_true]
    exact ⟨PlutusData.beq_refl x, PlutusData.beqList_refl xs⟩

theorem PlutusData.beqEntry_refl : ∀ e : PlutusData × PlutusData, PlutusData.beqEntry e e = true
  | (k, v) => by
    simp only [PlutusData.beqEntry, Bool.and_eq_true]
    exact ⟨PlutusData.beq_refl k, PlutusData.beq_refl v⟩

theorem PlutusData.beqEntries_refl :
    ∀ es : List (PlutusData × PlutusData), PlutusData.beqEntries es es = true
  | [] => by simp [PlutusData.beqEntries]
  | e :: es => by
    simp only [PlutusData.beqEntries, Bool.and_eq_true]
    exact ⟨PlutusData.beqEntry_refl e, PlutusData.beqEntries_refl es⟩
end

instance : LawfulBEq PlutusData where
  eq_of_beq {a b} h := PlutusData.eq_of_beq' a b h
  rfl {a} := PlutusData.beq_refl a

/-- The payload equality is exactly propositional equality. -/
theorem PlutusData.beq_iff_eq (a b : PlutusData) : (a == b) = true ↔ a = b :=
  ⟨eq_of_beq, fun h => h ▸ beq_self_eq_true a⟩

instance : DecidableEq PlutusData := fun a b => decidable_of_iff _ (PlutusData.beq_iff_eq a b)

/-- The registry's state asset: the policy and asset name of the one token its
state UTxO carries. It is what identifies a registry, and what the application
is parameterized by. -/
structure StateAsset where
  policy : Nat
  assetName : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

instance : LawfulBEq StateAsset where
  eq_of_beq {a b} h := by
    obtain ⟨p, n⟩ := a
    obtain ⟨p', n'⟩ := b
    simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at h
    rw [h.1, h.2]
  rfl {a} := by
    obtain ⟨p, n⟩ := a
    simp [reduceBEq]

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

instance : LawfulBEq Control where
  eq_of_beq {a b} h := by
    obtain ⟨v, r, ap, k, c, d⟩ := a
    obtain ⟨v', r', ap', k', c', d'⟩ := b
    simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
    subst h1 h2 h3 h4 h5 h6
    rfl
  rfl {a} := by
    obtain ⟨v, r, ap, k, c, d⟩ := a
    simp [reduceBEq]

/-- The versioned control envelope: protected control beside a free payload. -/
structure Envelope where
  control : Control
  payload : PlutusData
  deriving Repr, BEq

instance : LawfulBEq Envelope where
  eq_of_beq {a b} h := by
    obtain ⟨c, p⟩ := a
    obtain ⟨c', p'⟩ := b
    simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at h
    rw [h.1, h.2]
  rfl {a} := by
    obtain ⟨c, p⟩ := a
    simp [reduceBEq]

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

instance : LawfulBEq AppOutput where
  eq_of_beq {a b} h := by
    obtain ⟨r, ad, l, as, e⟩ := a
    obtain ⟨r', ad', l', as', e'⟩ := b
    simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨h1, h2, h3, h4, h5⟩ := h
    subst h1 h2 h3 h4 h5
    rfl
  rfl {a} := by
    obtain ⟨r, ad, l, as, e⟩ := a
    simp [reduceBEq]

/-- An output an update proposes, before the model allocates its reference. -/
structure Successor where
  address : Nat
  lovelace : Nat
  assets : List (Asset × Int)
  envelope : Envelope
  deriving Repr, BEq

/-- Whether an output holds the one active token of this key. -/
def carriesKey (assets : List (Asset × Int)) (key : Key) : Bool :=
  assets.any fun a => a.1 == (TokenKind.active, key) && a.2 == 1

/-- A booked request, and for an insertion the envelope its destination binds. -/
structure Pending where
  request : Request
  envelope : Option Envelope
  deriving BEq

/-- The world the application runs in: the application, the registry, the
state asset its state UTxO actually carries, the live application outputs, the
booked requests, the next output reference, and the mint of the last accepted
fold (empty before any). -/
structure World where
  app : App
  registry : RegistryState
  registryAsset : StateAsset
  outputs : List AppOutput
  pending : List Pending
  nextRef : Nat
  lastMint : List (Asset × Int)
  deriving BEq

/-- An empty registry under a configuration and an actual state asset. -/
def genesis (app : App) (c : Config) (asset : StateAsset) : World :=
  { app := app
  , registry := { config := { c with root := rootOf [] }, trie := [], custody := []
                , held := [] }
  , registryAsset := asset, outputs := [], pending := [], nextRef := 0, lastMint := [] }

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

/-- The law's guards that the definition mutants of the driver switch off.
`standard` is the law; every statement is about it. -/
structure Law where
  checkUpdateSigner : Bool := true
  checkRegistryAsset : Bool := true
  additiveSettlement : Bool := true
  deriving Repr

def Law.standard : Law := {}

/-- One action on the world. A `fold` folds a selection of booked requests in
one transaction; `reject` turns one booked request away; `bookOther` is a booking
of an edge this application does not certify; `withdraw` is every spend of an
application output that is neither an update nor a fold. -/
inductive AppAction where
  | bookInsert (request : Request) (envelope : Envelope) (signatures : List Nat)
  | bookTerminate (request : Request) (ref : Nat) (signatures : List Nat)
  | bookOther (request : Request) (signatures : List Nat)
  | update (ref : Nat) (successors : List Successor) (signatures : List Nat)
  | fold (selected : List (Edge × Key)) (outputs : List TxOutput)
  | reject (edge : Edge) (key : Key) (outputs : List TxOutput)
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
application serves the registry whose state asset the world actually carries,
the envelope names that full state asset, the registry's active policy, the key
and the controller as owner, the controller signs, the destination is this
contract with this envelope's hash, the request names that datum — so the
delivered output carries the envelope inline — and the protected deposit is the
request's. Whether the key may be inserted is the fold's question, not the
application's. -/
def bookInsertStep (law : Law) (w : World) (r : Request) (e : Envelope)
    (signatures : List Nat) : Except String World := do
  ensure (r.edge == .insertActive) "app-insert-edge"
  ensure (w.registry.config.applicationPolicy == w.app.policy) "app-not-pinned"
  ensure (!law.checkRegistryAsset || w.app.registry == w.registryAsset) "app-registry-asset"
  ensure (e.control.version == envelopeVersion) "app-envelope-version"
  ensure (!law.checkRegistryAsset || e.control.registry == w.registryAsset) "app-registry"
  ensure (e.control.activePolicy == w.registry.config.activePolicy) "app-active-policy"
  ensure (e.control.key == r.key) "app-key"
  ensure (e.control.controller == r.owner) "app-owner"
  ensure (signatures.contains e.control.controller) "app-controller-signature"
  ensure (r.output == destinationOf w.app e) "app-destination"
  ensure r.namesDatum "app-envelope-datum"
  ensure (e.control.deposit == r.deposit) "app-deposit"
  pure { w with pending := w.pending ++ [{ request := booked w.app r signatures
                                          , envelope := some e }] }

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
  ensure (c.key == r.key && c.registry == w.registryAsset) "app-terminate-binding"
  ensure (r.owner == c.controller) "app-owner"
  ensure (signatures.contains c.controller) "app-controller-signature"
  ensure (r.output == 0) "app-terminate-destination"
  pure { w with pending := w.pending ++ [{ request := booked w.app r signatures
                                          , envelope := none }] }

/-- The application certifies only insertions and terminations. -/
def bookOtherStep (_r : Request) : Except String World :=
  .error "app-edge-not-certified"

/-- An update: the controller signs, exactly one proposed output carries the
token, and it stays at this contract with the same control, the same assets and
at least the protected deposit. The payload is free. -/
def updateStep (law : Law) (w : World) (ref : Nat) (successors : List Successor)
    (signatures : List Nat) : Except String World := do
  let some o := outputAt w ref | .error "no-application-output"
  let c := o.envelope.control
  ensure (!law.checkUpdateSigner || signatures.contains c.controller) "update-controller-signature"
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

/-- One selected request of a fold, and the application output a termination
spends. -/
structure FoldRow where
  pending : Pending
  spent : Option AppOutput
  deriving BEq

/-- Select one booked request for a fold. An insertion's envelope is bound
again to its request, which must name its datum so the fold delivers the envelope
inline, and to the actual registry; a termination spends its key's
live output, whose controller must own the request and whose envelope must name
the actual registry. -/
def selectRow (law : Law) (w : World) (sel : Edge × Key) : Except String FoldRow := do
  let some p := pendingOf w sel.1 sel.2 | .error "no-pending-request"
  match sel.1 with
  | .insertActive =>
    let some e := p.envelope | .error "no-pending-request"
    ensure (p.request.output == destinationOf w.app e && e.control.deposit == p.request.deposit)
      "fold-envelope-binding"
    ensure p.request.namesDatum "fold-envelope-datum"
    ensure (!law.checkRegistryAsset || e.control.registry == w.registryAsset) "fold-registry"
    pure { pending := p, spent := none }
  | .updateTerminal =>
    let some o := outputOfKey w sel.2 | .error "no-application-output"
    ensure (p.request.owner == o.envelope.control.controller) "release-controller"
    ensure (!law.checkRegistryAsset || o.envelope.control.registry == w.registryAsset)
      "release-registry"
    pure { pending := p, spent := some o }
  | _ => .error "fold-edge-not-certified"

/-- The outputs a fold's insertions create at this contract, one per selected
insertion in order, with fresh references from `ref`. -/
def createdOutputs (app : App) : Nat → List FoldRow → List AppOutput
  | _, [] => []
  | ref, row :: rows =>
    match row.pending.request.edge, row.pending.envelope with
    | .insertActive, some e =>
      { ref := ref, address := appAddress app, lovelace := row.pending.request.deposit
      , assets := [((.active, row.pending.request.key), 1)], envelope := e } ::
        createdOutputs app (ref + 1) rows
    | _, _ => createdOutputs app ref rows

/-- A created output as the transaction presents it: the destination output
carrying the delivered token and the insertion deposit. -/
def deliveryOf (app : App) (o : AppOutput) : TxOutput :=
  { role := .destination, datum := .inline, address := some (destinationOf app o.envelope)
  , stateTokens := 0, config := none, commitment := some (envelopeHash o.envelope)
  , assets := o.assets, lovelace := o.lovelace }

/-- What the application releases for one spent output: its protected deposit,
to its controller's key. -/
def releaseOf (o : AppOutput) : Payment :=
  { recipient := .owner o.envelope.control.controller, atLeast := o.envelope.control.deposit }

/-- The registry's own payments for every selected request, each by its edge. -/
def registryPayments (rows : List FoldRow) : List Payment :=
  rows.flatMap fun row => obligations (.fold row.pending.request.edge) row.pending.request

/-- The deposits the fold releases: one per spent application output. -/
def releases (rows : List FoldRow) : List Payment :=
  (rows.filterMap (·.spent)).map releaseOf

/-- The fold's whole payment duty: the registry's and the releases, together,
so one output is never counted for two floors owed to the same recipient. -/
def foldPayments (rows : List FoldRow) : List Payment :=
  registryPayments rows ++ releases rows

/-- Judge a fold's outputs. The law judges the concatenated payments with the
unchanged `Singular.settle`; the non-additive definition mutant judges the two
halves separately. -/
def settleFold (law : Law) (rows : List FoldRow) (outputs : List TxOutput) : Option String :=
  if law.additiveSettlement then settle (foldPayments rows) outputs
  else (settle (registryPayments rows) outputs).orElse fun _ => settle (releases rows) outputs

/-- One fold: the selected booked requests, folded by the registry's own
`foldBatch` in one transaction. Insertions create this contract's outputs;
terminations spend their keys' outputs and release their deposits; the whole
payment duty settles against the transaction's outputs, the created deliveries
included. The world keeps the fold's mint. -/
def foldEffect (law : Law) (w : World) (selected : List (Edge × Key))
    (outputs : List TxOutput) : Except String (World × Result) := do
  let rows ← selected.mapM (selectRow law w)
  let t ← foldBatch w.registry (rows.map (·.pending.request))
  let fresh := createdOutputs w.app w.nextRef rows
  let spent := rows.filterMap (·.spent)
  match settleFold law rows (outputs ++ fresh.map (deliveryOf w.app)) with
  | some why => .error why
  | none =>
    pure ({ w with registry := t.state
                 , outputs := (w.outputs.filter fun o => !spent.contains o) ++ fresh
                 , pending := w.pending.filter fun p => !(rows.map (·.pending)).contains p
                 , nextRef := w.nextRef + fresh.length
                 , lastMint := t.mint }, t)

/-- A reject: the registry turns one booked request away and refunds its
deposit to its owner. No application output is spent or released. -/
def rejectStep (w : World) (edge : Edge) (key : Key) (outputs : List TxOutput) :
    Except String World := do
  let some p := pendingOf w edge key | .error "no-pending-request"
  let t ← exitStep w.registry .reject p.request
  match settle (obligations .reject p.request) outputs with
  | some why => .error why
  | none => pure { w with registry := t.state, pending := w.pending.erase p, lastMint := t.mint }

/-- The contract has exactly two spending paths, update and fold; anything else
is refused. -/
def withdrawStep (w : World) (ref : Nat) (_outputs : List TxOutput) :
    Except String World := do
  let some _ := outputAt w ref | .error "no-application-output"
  .error "no-withdrawal-path"

/-- The application law under a law variant. -/
def appStepWith (law : Law) (w : World) : AppAction → Except String World
  | .bookInsert r e sigs => bookInsertStep law w r e sigs
  | .bookTerminate r ref sigs => bookTerminateStep w r ref sigs
  | .bookOther r _ => bookOtherStep r
  | .update ref succs sigs => updateStep law w ref succs sigs
  | .fold selected outs => (foldEffect law w selected outs).map (·.1)
  | .reject edge key outs => rejectStep w edge key outs
  | .withdraw ref outs => withdrawStep w ref outs

/-- The application law. -/
def appStep : World → AppAction → Except String World := appStepWith Law.standard

/-- Worlds reached from a genesis by accepted actions. -/
inductive Reachable : World → Prop where
  | start (app : App) (c : Config) (asset : StateAsset) :
      Reachable (genesis app c asset)
  | next {w w' : World} {a : AppAction} : Reachable w → appStep w a = .ok w' → Reachable w'

/-- The consistency every reached world is required to keep, stated for review
and to be proved preserved (`OpenDatumApplication.Statements`): the registry is
consistent; every live output sits at this contract holding exactly its key's
active token, under an envelope naming the actual registry, with at least its
protected deposit, while the registry's leaf for that key is Active; the
inventory holds each output occurrence once — its references are pairwise
distinct, so no output, identical copies included, appears twice — and no two
live outputs share a key, every reference being below `nextRef`; every booked
insertion is bound to its envelope and the actual registry, and every booked
termination carries none. -/
def AppConsistent (w : World) : Prop :=
  Singular.Consistent w.registry ∧
  (w.outputs.map (·.ref)).Nodup ∧
  (∀ o ∈ w.outputs, o.address = appAddress w.app ∧
    o.assets = [((.active, o.envelope.control.key), 1)] ∧
    o.envelope.control.registry = w.registryAsset ∧
    o.envelope.control.deposit ≤ o.lovelace ∧
    trieGet w.registry.trie o.envelope.control.key = .known .active ∧
    o.ref < w.nextRef) ∧
  (∀ o₁ ∈ w.outputs, ∀ o₂ ∈ w.outputs,
    o₁.envelope.control.key = o₂.envelope.control.key ∨ o₁.ref = o₂.ref → o₁ = o₂) ∧
  (∀ p ∈ w.pending, (p.request.edge = .insertActive ∧ ∃ e, p.envelope = some e ∧
      p.request.output = destinationOf w.app e ∧ e.control.deposit = p.request.deposit ∧
      e.control.key = p.request.key ∧ e.control.registry = w.registryAsset) ∨
    (p.request.edge = .updateTerminal ∧ p.envelope = none))

/-- Run a list of actions under a law, reporting each outcome and the world
after each accepted action. -/
def runActionsWith (law : Law) (w : World) :
    List AppAction → List (Except String World)
  | [] => []
  | a :: rest =>
    match appStepWith law w a with
    | .ok w' => .ok w' :: runActionsWith law w' rest
    | .error why => .error why :: runActionsWith law w rest

end OpenDatumApplication
