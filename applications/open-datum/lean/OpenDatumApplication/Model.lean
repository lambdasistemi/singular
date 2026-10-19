import Singular.Economics.World

/-! Open-datum custody composed with the frozen root economic world.
The root holding is a registration snapshot, not the current application UTxO.
Signed payload updates retain that snapshot while changing the actual output.
Termination booking consumes the actual output; the root booking moves its
abstract holding into pending custody. No second economic admission is used. -/

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
  /-- Registration snapshot linking the current output to the root abstract holding.
  Updates change the current payload and reference, not this snapshot. -/
  registered : Envelope
  deriving Repr, BEq

instance : LawfulBEq AppOutput where
  eq_of_beq {a b} h := by
    obtain ⟨r, ad, l, as, e, origin⟩ := a
    obtain ⟨r', ad', l', as', e', origin'⟩ := b
    simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
    subst h1 h2 h3 h4 h5 h6
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

/-- Metadata only: the economic request lives solely in the root world. -/
structure Pending where
  reference : OutRef
  envelope : Envelope
  deriving BEq

structure World where
  app : App
  economic : Singular.World
  registryAsset : StateAsset
  outputs : List AppOutput
  pending : List Pending
  nextRef : Nat
  deriving BEq

def World.registry (w : World) : RegistryState := w.economic.registry

def genesis (app : App) (c : Config) (asset : StateAsset) : World :=
  { app, economic := { registry := { config := { c with root := rootOf [] }, trie := [], custody := [], held := [] } }, registryAsset := asset, outputs := [], pending := [], nextRef := 0 }

/-- Each switch removes one application guard, for finite fault controls only. -/
structure Law where
  checkUpdateSigner : Bool := true
  checkRegistryAsset : Bool := true
  checkTransferredValue : Bool := true
  checkBookingSigner : Bool := true
  checkUpdateControl : Bool := true
  checkUpdateAddress : Bool := true
  checkUpdateFloor : Bool := true
  preserveSnapshot : Bool := true
  removeBookedCustody : Bool := true
  deriving Repr

def Law.standard : Law := {}

/-- Booking observations are supplied, including the actual held contents and
mint. Optional ordinary additions are a value contribution, not evidence of
funding availability or a ledger fee/minimum check. Folds and rejections supply
complete root economic observations. There is no application retraction action. -/
inductive AppAction where
  | bookInsert (booking : RegistrationBooking) (envelope : Envelope) (signatures : List Nat)
  | bookTerminate (booking : TerminationBooking) (ref ordinaryAdded : Nat) (signatures : List Nat)
  | bookOther (request : Request) (signatures : List Nat)
  | update (ref : Nat) (successors : List Successor) (signatures : List Nat)
  | fold (unspent : EconomicUtxo) (transaction : EconomicTransaction)
  | reject (unspent : EconomicUtxo) (transaction : Rejection)
  | withdraw (ref : Nat) (outputs : List TxOutput)

def ensure (condition : Bool) (why : String) : Except String Unit :=
  if condition then .ok () else .error why

def outputAt (w : World) (ref : Nat) : Option AppOutput := w.outputs.find? (·.ref == ref)
def outputOfKey (w : World) (key : Key) : Option AppOutput :=
  w.outputs.find? fun o => o.address == appAddress w.app && carriesKey o.assets key

def pendingOf (w : World) (reference : OutRef) : Option Pending :=
  w.pending.find? (·.reference == reference)

/-- The immutable registry projection of an actual application output. -/
def rootHolding (w : World) (o : AppOutput) : Holding :=
  { key := o.registered.control.key, kind := .active,     output := destinationOf w.app o.registered, datum := some (envelopeHash o.registered) }

/-- The full state asset observed by the application is the root economic
registry's state token, including its reserved name. -/
def registryAssetMatches (w : World) : Bool :=
  w.registryAsset.policy == w.registry.config.stateToken.policy &&
    w.registryAsset.assetName == w.registry.config.stateToken.name

/-- Whole-envelope registration binding, independent of any hash injectivity. -/
def insertionBinding (law : Law) (w : World) (r : RegistrationRequest) (e : Envelope) : Bool :=
  w.registry.config.applicationPolicy == w.app.policy &&
  (!law.checkRegistryAsset || (w.app.registry == w.registryAsset && e.control.registry == w.registryAsset && registryAssetMatches w)) &&
  e.control.version == envelopeVersion && e.control.activePolicy == w.registry.config.activePolicy &&
  e.control.key == r.key && e.control.controller == r.refundAddress &&
  r.destination == destinationOf w.app e && r.datum == some (envelopeHash e) &&
  e.control.deposit == r.carrierAda

def bookInsertStep (law : Law) (w : World) (b : RegistrationBooking) (e : Envelope)
    (signatures : List Nat) : Except String World := do
  ensure (insertionBinding law w b.request e) "app-registration-binding"
  ensure (!law.checkBookingSigner || signatures.contains e.control.controller) "app-controller-signature"
  let economic ← Singular.book w.economic b
  pure { w with economic, pending := ⟨b.request.reference, e⟩ :: w.pending }

/-- Actual custody is consumed now. H = V + A, and the root separately checks
H = T + C and genuine pending tags. No amount of V is allocated to a refund;
ordinary additions may be zero. Root custody is a snapshot, never a purported
observation of the current output's lovelace or payload. -/
def bookTerminateStep (law : Law) (w : World) (b : TerminationBooking) (ref ordinaryAdded : Nat)
    (signatures : List Nat) : Except String World := do
  let some o := outputAt w ref | .error "no-application-output"
  let c := o.envelope.control
  ensure (w.registry.config.applicationPolicy == w.app.policy) "app-not-pinned"
  ensure (registryAssetMatches w) "app-registry-asset"
  ensure (o.address == appAddress w.app && o.assets == [((.active, b.request.key), 1)]) "app-terminate-token"
  ensure (c.key == b.request.key && c.registry == w.registryAsset &&
    c.activePolicy == w.registry.config.activePolicy && c == o.registered.control) "app-terminate-binding"
  ensure (!law.checkBookingSigner || signatures.contains c.controller) "app-controller-signature"
  ensure (b.request.destination == 0) "app-terminate-destination"
  ensure (b.custodyInputs == [rootHolding w o]) "app-custody-snapshot"
  ensure (!law.checkTransferredValue || b.request.contents.lovelace == o.lovelace + ordinaryAdded)
    "app-termination-value"
  let economic ← Singular.bookTermination w.economic b
  pure { w with economic, outputs := if law.removeBookedCustody then w.outputs.erase o else w.outputs }

def bookOtherStep (_r : Request) : Except String World := .error "app-edge-not-certified"

def updateStep (law : Law) (w : World) (ref : Nat) (successors : List Successor)
    (signatures : List Nat) : Except String World := do
  let some o := outputAt w ref | .error "no-application-output"
  let c := o.envelope.control
  ensure (!law.checkUpdateSigner || signatures.contains c.controller) "update-controller-signature"
  let carrying := successors.filter fun s => carriesKey s.assets c.key
  let some s := (match carrying with | [s] => some s | _ => none) | .error "update-token"
  ensure (!law.checkUpdateAddress || s.address == appAddress w.app) "update-escape"
  ensure (!law.checkUpdateControl || s.envelope.control == c) "update-control"
  ensure (s.assets == o.assets) "update-assets"
  ensure (!law.checkUpdateFloor || c.deposit ≤ s.lovelace) "update-deposit"
  let next : AppOutput :=
    { ref := w.nextRef, address := s.address, lovelace := s.lovelace, assets := s.assets,       envelope := s.envelope, registered := if law.preserveSnapshot then o.registered else s.envelope }
  pure { w with outputs := w.outputs.erase o ++ [next], nextRef := w.nextRef + 1 }

structure FoldRow where
  member : FoldMember
  envelope : Option Envelope
  deriving BEq

/-- Select by actual pending reference, not edge/key. Terminations have no
application metadata, output, signature, clock or application tag to select. -/
def selectRow (law : Law) (w : World) (reference : OutRef) : Except String FoldRow := do
  let some member := foldMemberAt w.economic reference | .error "no-pending-request"
  match member with
  | .registration b =>
    let some p := pendingOf w reference | .error "no-registration-envelope"
    ensure (insertionBinding law w b.request p.envelope) "app-registration-binding"
    pure ⟨member, some p.envelope⟩
  | .termination _ => pure ⟨member, none⟩

def selectedReferences (w : World) (tx : EconomicTransaction) : List OutRef :=
  tx.transaction.inputs.filterMap fun i => i.ref.filter (fun r => (foldMemberAt w.economic r).isSome)

def createdOutputs (app : App) (first : Nat) (rows : List FoldRow) : List AppOutput :=
  ((rows.filterMap fun row => match row.member, row.envelope with
    | .registration b, some e => some (b, e)
    | _, _ => none).zipIdx).map fun ((b, e), i) =>
      { ref := first + i, address := appAddress app, lovelace := b.request.carrierAda,         assets := [((.active, b.request.key), 1)], envelope := e, registered := e }

/-- Operational timing port, delegated with the exact root arguments. -/
def terminationFoldTiming (world : Singular.World) (interval : Interval)
    (booking : TerminationBooking) : Option String :=
  Singular.foldMemberRefusal world.registry.config interval (.termination booking)

/-- Only queried after root admission, in the root's selected input order. -/
def applicationFoldTimingRefusal (world : Singular.World) (tx : EconomicTransaction) : Option String :=
  match tx.transaction.validity with
  | none => none
  | some interval => (foldMembers world tx).findSome? fun member =>
    match member with
    | .registration _ => none
    | .termination booking => terminationFoldTiming world interval booking

/-- Root errors retain precedence; no successor is committed before the port. -/
def applicationFoldDecision (world : Singular.World) (u : EconomicUtxo)
    (tx : EconomicTransaction) : Except String Singular.World := do
  let after ← Singular.foldAccepted world u tx
  match applicationFoldTimingRefusal world tx with
  | some why => .error why
  | none => .ok after

/-- The root owns the entire rejection decision, including refusal precedence. -/
def applicationRejectionDecision (world : Singular.World) (u : EconomicUtxo)
    (rejection : Rejection) : Except String Singular.World :=
  Singular.rejectionAccepted world u rejection

/-- All economic admission and accounting is the frozen root fold. The local
projection adds only newly delivered registration outputs. Termination custody
was already removed at booking; it is never spent a second time here. -/
def foldEffect (law : Law) (w : World) (u : EconomicUtxo) (tx : EconomicTransaction) : Except String World := do
  let rows ← (selectedReferences w tx).mapM (selectRow law w)
  let economic ← applicationFoldDecision w.economic u tx
  let created := createdOutputs w.app w.nextRef rows
  pure { w with economic, outputs := w.outputs ++ created,         pending := w.pending.filter (fun p => !inputsContainReference tx.transaction.inputs p.reference),         nextRef := w.nextRef + created.length }

/-- Lawful registration rejection only, with the frozen root judgement. -/
def rejectStep (w : World) (u : EconomicUtxo) (r : Rejection) : Except String World := do
  let economic ← applicationRejectionDecision w.economic u r
  pure { w with economic,     pending := w.pending.filter fun p => !(r.members.any fun m => m.1 == p.reference) }

def withdrawStep (w : World) (ref : Nat) (_outputs : List TxOutput) : Except String World := do
  let some _ := outputAt w ref | .error "no-application-output"
  .error "no-withdrawal-path"

def appStepWith (law : Law) (w : World) : AppAction → Except String World
  | .bookInsert b e sigs => bookInsertStep law w b e sigs
  | .bookTerminate b ref added sigs => bookTerminateStep law w b ref added sigs
  | .bookOther r _ => bookOtherStep r
  | .update ref successors sigs => updateStep law w ref successors sigs
  | .fold u tx => foldEffect law w u tx
  | .reject u tx => rejectStep w u tx
  | .withdraw ref outputs => withdrawStep w ref outputs

def appStep : World → AppAction → Except String World := appStepWith Law.standard

inductive Reachable : World → Prop where
  | initial (app : App) (c : Config) (asset : StateAsset) : Reachable (genesis app c asset)
  | next {w w' : World} {a : AppAction} : Reachable w → appStep w a = .ok w' → Reachable w'

/-- The executable correspondence clauses are independent of reachability.
Root abstract holdings match actual outputs by their registration snapshots.
Supply includes pending termination tags, not only live application outputs. -/
def CustodyCorrespondence (w : World) : Prop :=
  (∀ o ∈ w.outputs, rootHolding w o ∈ w.registry.held) ∧
  (∀ h ∈ w.registry.held, ∃ o ∈ w.outputs, rootHolding w o = h)

def AppConsistent (w : World) : Prop :=
  Singular.Consistent (foldProjectedRegistry w.economic) ∧
  (w.outputs.map (·.ref)).Nodup ∧
  (∀ o ∈ w.outputs, o.address = appAddress w.app ∧
    o.assets = [((.active, o.envelope.control.key), 1)] ∧
    o.envelope.control = o.registered.control ∧
    o.envelope.control.registry = w.registryAsset ∧
    o.envelope.control.deposit ≤ o.lovelace ∧ o.ref < w.nextRef) ∧
  (∀ a ∈ w.outputs, ∀ b ∈ w.outputs,
    a.envelope.control.key = b.envelope.control.key ∨ a.ref = b.ref → a = b) ∧
  CustodyCorrespondence w ∧
  (w.pending.map (·.reference)).Nodup ∧
  ((w.economic.pending.map (·.request.reference)) ++
    w.economic.terminations.map (·.request.reference)).Nodup ∧
  (∀ p ∈ w.pending, ∃ b ∈ w.economic.pending,
    b.request.reference = p.reference ∧ insertionBinding Law.standard w b.request p.envelope = true) ∧
  (∀ b ∈ w.economic.pending, ∃ p ∈ w.pending, p.reference = b.request.reference) ∧
  (∀ b ∈ w.economic.pending, registrationBookingRefusal w.registry.config b = none) ∧
  (∀ b ∈ w.economic.terminations,
    terminationExactContents w.registry.config b.request = true ∧
    b.custodyInputs.length = 1 ∧
    ∀ h ∈ b.custodyInputs, h.key = b.request.key ∧ h.kind = .active)

def runActionsWith (law : Law) (w : World) : List AppAction → List (Except String World)
  | [] => []
  | a :: rest =>
    let result := appStepWith law w a
    result :: runActionsWith law (result.toOption.getD w) rest

end OpenDatumApplication
