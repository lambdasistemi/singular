import Lean

/-! The registry-mode logical model: the trie answers two questions and nothing
else — is this key known, and where in its life is it.

`Leaf ::= Unknown | Known State` with `State ::= Absent | Active | Terminal`.
Seven edges move a leaf, each an MPFS primitive applied to a state, each a delta
over three token kinds. Six of them are tree changes admitted only by an
approval under the pinned application policy whose scoping tuple matches the
request (D-APPROVAL); the seventh, `witnessTerminal`, is a read that changes
nothing and needs none. The fold sums the deltas of the edges it folded and
refuses any claimed mint that differs.

Tagged commitments stand for collision-free canonical commitments; the trie is
an authenticated logical map whose root is derived from its content, and an
approval's asset name is a canonical commitment over the tuple it scopes. The
executable consumer supplies the real hashes; the model fixes the complete
preimages. Contract evidence is supplied, not verified application code. A
selected batch is atomic and never skips failures. This is an explicit model
profile, not a ruling on batch construction. -/

namespace Singular
open Lean

/-- The key a leaf is filed under. -/
abbrev Key := Nat

instance : ToJson ByteArray where
  toJson b := toJson (b.toList.map (·.toNat))

instance : FromJson ByteArray where
  fromJson? j := do
    let l : List Nat ← fromJson? j
    if l.all (· < 256) then pure (ByteArray.mk (l.map (fun n => (n % 256).toUInt8)).toArray)
    else throw "byte out of range"

/-- The three lifecycle states — the only leaf vocabulary. -/
inductive State where
  | absent | active | terminal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- One leaf per key: `unknown` is a non-membership proof, `known s` a
membership proof whose value is `s`. No application payload, no version
counter, no incarnation. -/
inductive Leaf where
  | unknown | known (s : State)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The codec byte of a state: `0x00` Absent, `0x01` Active, `0x02` Terminal. -/
def stateByte (s : State) : UInt8 :=
  match s with | .absent => 0x00 | .active => 0x01 | .terminal => 0x02

/-- The leaf codec (frozen sibling contract). Total and injective. -/
def encodeState (s : State) : ByteArray := ByteArray.mk #[stateByte s]

/-- Defined on exactly the three codec bytes; `none` on the empty string, any
longer string and every other byte. A naming-era leaf byte string does not
decode. -/
def decodeState (bytes : ByteArray) : Option State :=
  match bytes.toList with
  | [0x00] => some .absent
  | [0x01] => some .active
  | [0x02] => some .terminal
  | _ => none

/-- The seven edges. Exactly seven; there is no free-form `update`. -/
inductive Edge where
  | insertAbsent | insertActive | updateActive | updateTerminal
  | deleteAbsent | deleteActive | witnessTerminal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The three token kinds the deltas speak about. -/
inductive TokenKind where
  | active | absent | terminal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-! The derived `BEq` instances above are structural but not registered as
lawful, so `==` on a *variable* of these types does not reduce to `=` in a
proof. These instances supply that, and nothing else: they add no behaviour,
only the fact that the decidable equality the model already derives agrees with
propositional equality. -/

/-- `ByteArray`'s derived `BEq` is not registered as lawful in core either, and
the root is a `ByteArray`, so a proof about `config.root == rootOf trie` needs
this to reduce to an equation. -/
instance : LawfulBEq ByteArray where
  eq_of_beq {a b} h := by
    cases a; cases b
    simp only [BEq.beq, ByteArray.instBEq.beq] at h
    exact congrArg ByteArray.mk (eq_of_beq h)
  rfl {a} := by
    cases a
    simp only [BEq.beq, ByteArray.instBEq.beq]
    exact beq_self_eq_true (α := Array UInt8) _

instance : LawfulBEq State where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq Leaf where
  eq_of_beq {a b} h := by
    cases a with
    | unknown =>
      cases b with
      | unknown => rfl
      | known y => cases y <;> exact absurd h (by decide)
    | known x =>
      cases b with
      | unknown => cases x <;> exact absurd h (by decide)
      | known y => cases x <;> cases y <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by
    cases a with
    | unknown => rfl
    | known x => cases x <;> rfl

instance : LawfulBEq Edge where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq TokenKind where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

/-- The R2 table: each edge's delta, read off the edge and nothing else. -/
def delta (e : Edge) : List (TokenKind × Int) :=
  match e with
  | .insertAbsent => [(.absent, 1)]
  | .insertActive => [(.active, 1)]
  | .updateActive => [(.absent, -1), (.active, 1)]
  | .updateTerminal => [(.active, -1)]
  | .deleteAbsent => [(.absent, -1)]
  | .deleteActive => [(.active, -1)]
  | .witnessTerminal => [(.terminal, 1)]

/-- Sum a delta list along one token kind. -/
def deltaKind (ds : List (TokenKind × Int)) (k : TokenKind) : Int :=
  ds.foldl (fun n p => if p.1 == k then n + p.2 else n) 0

/-- A minted asset's identity: the token kind and the key the token is about.
On chain it is `(policy of the kind, asset name)`; the model pins the asset name
to the key, so the pair `(kind, key)` names the asset exactly. Mint accounting
is by this pair and never by the kind alone: two keys of one kind are two
different assets, and a fold that swapped them would balance per kind. -/
abbrev Asset := TokenKind × Key

/-- Sum a keyed delta list along one asset. -/
def assetKind (ds : List (Asset × Int)) (x : Asset) : Int :=
  ds.foldl (fun n p => if p.1 == x then n + p.2 else n) 0

/-- Merge two keyed delta lists into their per-asset sum. -/
def assetPlus (a b : List (Asset × Int)) : List (Asset × Int) :=
  ((a.map Prod.fst ++ b.map Prod.fst).eraseDups).map fun x =>
    (x, assetKind a x + assetKind b x)

/-- Two keyed delta lists carry the same per-asset sums. -/
def assetSame (a b : List (Asset × Int)) : Bool :=
  (a.map Prod.fst ++ b.map Prod.fst).all fun x => assetKind a x == assetKind b x

/-- The per-kind total of a keyed delta list: the coarser accounting the keyed
one refines. Two lists can agree at every kind and still differ at an asset,
which is exactly the fault `assetSame` catches and a per-kind sum does not. -/
def assetKindTotal (ds : List (Asset × Int)) (k : TokenKind) : Int :=
  ds.foldl (fun n p => if p.1.1 == k then n + p.2 else n) 0

/-- The R2 from→to column: `none` is refusal; every edge out of
`known terminal` is `none`. -/
def transition (e : Edge) (before : Leaf) : Option Leaf :=
  match e, before with
  | .insertAbsent, .unknown => some (.known .absent)
  | .insertActive, .unknown => some (.known .active)
  | .updateActive, .known .absent => some (.known .active)
  | .updateTerminal, .known .active => some (.known .terminal)
  | .deleteAbsent, .known .absent => some .unknown
  | .deleteActive, .known .active => some .unknown
  | .witnessTerminal, .known .terminal => some (.known .terminal)
  | _, _ => none

/-- The state configuration: eight fields. All eight are pinned when the
registry's seed is spent; the four policies are equal before and after every
fold (I-P1), while `root` tracks the authenticated map. -/
structure Config where
  root : ByteArray
  maxFee : Nat
  processTime : Nat
  retractTime : Nat
  applicationPolicy : Nat
  activePolicy : Nat
  absentPolicy : Nat
  terminalPolicy : Nat
  deriving BEq, DecidableEq

instance : ToJson Config where
  toJson c := Json.mkObj
    [ ("root", toJson c.root), ("maxFee", toJson c.maxFee)
    , ("processTime", toJson c.processTime), ("retractTime", toJson c.retractTime)
    , ("applicationPolicy", toJson c.applicationPolicy)
    , ("activePolicy", toJson c.activePolicy)
    , ("absentPolicy", toJson c.absentPolicy)
    , ("terminalPolicy", toJson c.terminalPolicy) ]

instance : FromJson Config where
  fromJson? j := do
    let root ← j.getObjVal? "root" >>= fromJson?
    let maxFee ← j.getObjVal? "maxFee" >>= fromJson?
    let processTime ← j.getObjVal? "processTime" >>= fromJson?
    let retractTime ← j.getObjVal? "retractTime" >>= fromJson?
    let applicationPolicy ← j.getObjVal? "applicationPolicy" >>= fromJson?
    let activePolicy ← j.getObjVal? "activePolicy" >>= fromJson?
    let absentPolicy ← j.getObjVal? "absentPolicy" >>= fromJson?
    let terminalPolicy ← j.getObjVal? "terminalPolicy" >>= fromJson?
    pure { root, maxFee, processTime, retractTime, applicationPolicy
         , activePolicy, absentPolicy, terminalPolicy }

/-- The policy a token kind is minted under, read off the registry's pins. -/
def kindPolicy (c : Config) : TokenKind → Nat
  | .active => c.activePolicy
  | .absent => c.absentPolicy
  | .terminal => c.terminalPolicy

/-- The asset name of a witness token is the key it is about, so the token's
identity is `(kindPolicy c kind, key)` and nothing else. -/
def tokenAssetName (_kind : TokenKind) (key : Key) : Nat := key

/-- FNV-1a over a byte list: the model's canonical commitment function. The
executable consumer supplies the real BLAKE2b-256; the model fixes the complete
preimage and binds each name to what it commits to. -/
def fnv1a (bs : List UInt8) : UInt64 :=
  bs.foldl (fun h b => (h ^^^ b.toUInt64) * 16777619) 14695981039346656037

def u64bytes (n : UInt64) : List UInt8 :=
  [(n >>> 56).toNat.toUInt8, (n >>> 48).toNat.toUInt8, (n >>> 40).toNat.toUInt8,
   (n >>> 32).toNat.toUInt8, (n >>> 24).toNat.toUInt8, (n >>> 16).toNat.toUInt8,
   (n >>> 8).toNat.toUInt8, n.toNat.toUInt8]

/-- The authenticated map's logical content. -/
abbrev Trie := List (Key × Leaf)

/-- Read a key's leaf; an unbound key reads `unknown`. -/
def trieGet (t : Trie) (k : Key) : Leaf :=
  ((t.filter (·.1 == k)).head?).map (·.2) |>.getD .unknown

/-- Write a key's leaf. -/
def trieSet (t : Trie) (k : Key) (l : Leaf) : Trie :=
  (k, l) :: t.filter (fun p => p.1 != k)

/-- Remove a key. A deleted key is a non-member: no pair of it is kept, so it
reads `unknown` by the lookup default and contributes nothing to the root. -/
def trieErase (t : Trie) (k : Key) : Trie :=
  t.filter (fun p => p.1 != k)

/-- The commitment byte of a leaf in the root: a bound key commits to its
state's codec byte. `0xFF` is the codec of the lookup answer `unknown`; the root
commits only stored pairs, and a reachable registry stores no `unknown` leaf. -/
def leafByte (l : Leaf) : UInt8 :=
  match l with | .unknown => 0xFF | .known s => stateByte s

/-- The root is the canonical commitment over the sorted (key, leaf byte)
pairs. Collision-free by model fiat, like every tagged commitment in this
profile. -/
def rootOf (t : Trie) : ByteArray :=
  let sorted := (t.toArray.qsort (fun a b => a.1 < b.1)).toList
  let bytes : List UInt8 :=
    sorted.flatMap fun p =>
      u64bytes (fnv1a [p.1.toUInt8]) ++ [p.1.toUInt8, leafByte p.2]
  ByteArray.mk (u64bytes (fnv1a bytes)).toArray

/-- One outstanding absent token in cage custody: the token, the refund address
the `insertAbsent` request named, and the value the token holds (R-ADA). -/
structure Custody where
  key : Key
  refundAddress : Nat
  value : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- One active or terminal token routed to the output the request named. -/
structure Holding where
  key : Key
  kind : TokenKind
  output : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The registry state. -/
structure RegistryState where
  config : Config
  trie : Trie
  custody : List Custody
  held : List Holding
  deriving BEq, DecidableEq

/-- A leaf as the consumer sees it: `null` for `Unknown`, the state's name for
`Known`. The simulator reads exactly this. -/
def leafJson (l : Leaf) : Json :=
  match l with
  | .unknown => Json.null
  | .known .absent => "absent"
  | .known .active => "active"
  | .known .terminal => "terminal"

/-- The state serialises COMPLETELY — the whole config, not only its root — so a
corpus row is a replayable input and not merely a picture of an output. -/
instance : ToJson RegistryState where
  toJson s := Json.mkObj
    [ ("config", toJson s.config)
    , ("trie", Json.arr ((s.trie.map fun p =>
        Json.mkObj [("key", toJson p.1), ("leaf", leafJson p.2)]).toArray))
    , ("custody", toJson s.custody)
    , ("held", toJson s.held) ]

/-- Outstanding active tokens of one key: at most one (I-W1). -/
def kindCount (s : RegistryState) (k : TokenKind) (key : Key) : Nat :=
  (s.held.filter fun h => h.key == key && h.kind == k).length

/-- Outstanding absent tokens of one key: the custody census (I-W2). -/
def custodyCount (s : RegistryState) (key : Key) : Nat :=
  (s.custody.filter fun c => c.key == key).length

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

/-- An approval scoped by the tuple `(edge, key, owner, destination)` (D-APPROVAL,
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
the refund address is named by `insertAbsent` and recorded in the custody datum
(R-ADA); `deposit` is the value the absent token holds; `output` is where active
and terminal tokens are routed; `approval` is the admission evidence; `claimed`
is the mint the transaction claims for this request, summed by the fold; `tip`
is what the request holds beyond its deposit (on chain `held − deposit`). -/
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
  deriving Repr, BEq, DecidableEq

/-- A request that holds nothing beyond its deposit, given field by field in
declaration order. -/
@[reducible] def Request.mk (edge : Edge) (key : Key) (owner refundAddress deposit output : Nat)
    (approval : Option Approval) (claimed : List (TokenKind × Int)) : Request :=
  Request.make edge key owner refundAddress deposit output approval claimed 0

/-- A request serialises completely too, so a corpus row carries the exact input
the fold was given. -/
instance : ToJson Request where
  toJson r := Json.mkObj
    [ ("edge", toJson r.edge), ("key", toJson r.key), ("owner", toJson r.owner)
    , ("refundAddress", toJson r.refundAddress), ("deposit", toJson r.deposit)
    , ("tip", toJson r.tip)
    , ("output", toJson r.output)
    , ("approval", match r.approval with | none => Json.null | some a => toJson a)
    , ("claimed", Json.arr ((r.claimed.map fun d =>
        Json.mkObj [("kind", toJson d.1), ("quantity", toJson d.2)]).toArray)) ]

/-- The destination a request names: the cage-custody sentinel `0` for
`insertAbsent`, whose token goes to the cage; otherwise the output the request
named. -/
def requestDestination (r : Request) : Nat :=
  if r.edge == .insertAbsent then 0 else r.output

/-- One fold action is one request. -/
def Action := Request

/-- The keyed delta of one request: the edge's R2 delta, each entry named by the
key the request moves. -/
def assetDelta (a : Action) : List (Asset × Int) :=
  (delta a.edge).map fun p => ((p.1, a.key), p.2)

/-- The keyed mint one request claims. A request claims at the key it moves and
at no other, so a claim naming a foreign key is only expressible by claiming the
wrong quantity here — which is what the fold's per-asset guard then catches. -/
def requestClaim (b : Action) : List (Asset × Int) :=
  b.claimed.map fun p => ((p.1, b.key), p.2)

/-- The whole batch's claimed mint, summed per asset. -/
def claimedMint (batch : List Action) : List (Asset × Int) :=
  batch.foldl (fun acc b => assetPlus acc (requestClaim b)) []

/-- The whole batch's actual mint, summed per asset. -/
def actualMint (batch : List Action) : List (Asset × Int) :=
  batch.foldl (fun acc b => assetPlus acc (assetDelta b)) []

/-- Where a minted token is routed (R6). -/
inductive Destination where
  | cageCustody | requestOutput
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Absent tokens go to cage custody — a later fold consumes them without a
signature — and active and terminal tokens go to the output the request
named. -/
def route (k : TokenKind) (_request : Request) : Destination :=
  match k with
  | .absent => .cageCustody
  | .active => .requestOutput
  | .terminal => .requestOutput

/-- A read of `key` claiming `value` is verified against the root of `s` — the
state at the read's position in the batch — and only a leaf that can no longer
move may be attested. `position` names the position `s` occupies in the batch;
the verification binds to `s` itself, which the fold threads. -/
def readAt (s : RegistryState) (_position : Nat) (key : Key) (value : State) : Bool :=
  s.config.root == rootOf s.trie && trieGet s.trie key == .known value && value == .terminal

/-- The canonical request of each edge, in the frame where the frozen
three-argument `admits` observes admission: key 5; owner 42, or 91 — the refund
address — for the absent edges; destination 99, or the cage-custody sentinel 0
for `insertAbsent`. -/
def canonicalRequest (e : Edge) : Request :=
  match e with
  | .insertAbsent => { edge := e, key := 5, owner := 91, refundAddress := 91 }
  | .deleteAbsent => { edge := e, key := 5, owner := 91, refundAddress := 91 }
  | _ => { edge := e, key := 5, owner := 42, output := 99 }

/-- The real admission decision for a request (R4 with D-APPROVAL). The six
tree edges need an approval under the pinned application policy whose
`(edge, key, owner, destination)` tuple matches the request and whose asset
name binds its own tuple: right policy is necessary and not sufficient.
`witnessTerminal` requires none and is never refused for carrying a stray
one (D-SELF: `insertAbsent` is admitted exactly like the other five tree
edges, by an approval under the pinned policy and nothing else). -/
def admitsFor (c : Config) (r : Request) (approval : Option Approval) : Bool :=
  match r.edge with
  | .witnessTerminal => true
  | _ =>
    match approval with
    | none => false
    | some ap =>
      ap.policy == c.applicationPolicy && ap.edge == r.edge && ap.key == r.key &&
        ap.owner == r.owner && ap.destination == requestDestination r &&
        ap.assetName == approvalAssetName ap.edge ap.key ap.owner ap.destination

/-- Admission at one edge, observed from the edge alone: the frozen
three-argument shape evaluates the real per-request decision at the edge's
canonical request. -/
def admits (c : Config) (e : Edge) (approval : Option Approval) : Bool :=
  admitsFor c (canonicalRequest e) approval

/-- The refusal decision: `none` admits, `some why` refuses with an observable
reason. This is the complement of the R2 table, stated as a function, so a
triple nobody thought of is refused by construction rather than by omission. -/
def refusal (s : RegistryState) (a : Action) : Option String :=
  let before := trieGet s.trie a.key
  if a.edge == .witnessTerminal then
    if readAt s 0 a.key .terminal then none
    else some (match before with
      | .unknown => "read-unknown"
      | .known .absent => "read-absent"
      | .known .active => "read-active"
      | .known .terminal => "read-invalid")
  else
    match a.approval with
    | none => some "no-approval"
    | some ap =>
      if ap.policy != s.config.applicationPolicy then some "no-approval"
      else if !admitsFor s.config a a.approval then some "approval-mismatch"
      else
        let custodyPresent := s.custody.any (·.key == a.key)
        let activePresent := s.held.any fun h => h.key == a.key && h.kind == .active
        match a.edge, before with
        | .insertAbsent, .unknown
        | .insertActive, .unknown => none
        | .insertAbsent, _ | .insertActive, _ => some "key-exists"
        | .witnessTerminal, _ => some "read-invalid"
        | .updateActive, .known .absent =>
            if custodyPresent then none else some "custody-missing"
        | .updateActive, .unknown => some "key-unknown"
        | .updateActive, .known .active => some "already-booked"
        | .updateActive, .known .terminal => some "terminal-immutable"
        | .updateTerminal, .known .active =>
            if activePresent then none else some "token-missing"
        | .updateTerminal, .unknown => some "key-unknown"
        | .updateTerminal, .known .absent => some "not-booked"
        | .updateTerminal, .known .terminal => some "terminal-immutable"
        | .deleteAbsent, .known .absent =>
            if custodyPresent then none else some "custody-missing"
        | .deleteAbsent, .unknown => some "key-unknown"
        | .deleteAbsent, .known .active => some "not-absent"
        | .deleteAbsent, .known .terminal => some "terminal-immutable"
        | .deleteActive, .known .active =>
            if activePresent then none else some "token-missing"
        | .deleteActive, .unknown => some "key-unknown"
        | .deleteActive, .known .absent => some "not-active"
        | .deleteActive, .known .terminal => some "terminal-immutable"

/-- The result of folding a batch. -/
structure Result where
  state : RegistryState
  mint : List (Asset × Int)
  paid : List (Nat × Nat)
  deriving BEq

def emptyResult (s : RegistryState) : Result :=
  { state := s, mint := [], paid := [] }

def combineResults (first rest : Result) : Result :=
  { state := rest.state, mint := assetPlus first.mint rest.mint, paid := first.paid ++ rest.paid }

/-- Apply an admitted edge. The trie change, the token ledgers and the mint are
exactly the R2 row of the edge; consuming an absent token pays its value to the
refund address recorded in its custody datum (R-ADA). -/
def applyEdge (s : RegistryState) (a : Action) : Result :=
  let entry := s.custody.find? (·.key == a.key)
  let state : RegistryState :=
    match a.edge with
    | .insertAbsent =>
      let trie := trieSet s.trie a.key (.known .absent)
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , custody := { key := a.key, refundAddress := a.refundAddress
                          , value := a.deposit } :: s.custody }
    | .insertActive =>
      let trie := trieSet s.trie a.key (.known .active)
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , held := { key := a.key, kind := .active, output := a.output } :: s.held }
    | .updateActive =>
      let trie := trieSet s.trie a.key (.known .active)
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , custody := s.custody.filter (·.key != a.key)
             , held := { key := a.key, kind := .active, output := a.output } :: s.held }
    | .updateTerminal =>
      let trie := trieSet s.trie a.key (.known .terminal)
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , held := s.held.filter fun h => !(h.key == a.key && h.kind == .active) }
    | .deleteAbsent =>
      let trie := trieErase s.trie a.key
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , custody := s.custody.filter (·.key != a.key) }
    | .deleteActive =>
      let trie := trieErase s.trie a.key
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , held := s.held.filter fun h => !(h.key == a.key && h.kind == .active) }
    | .witnessTerminal =>
      { s with held := { key := a.key, kind := .terminal, output := a.output } :: s.held }
  let paid : List (Nat × Nat) :=
    match a.edge, entry with
    | .updateActive, some c => [(c.refundAddress, c.value)]
    | .deleteAbsent, some c => [(c.refundAddress, c.value)]
    | _, _ => []
  { state := state, mint := assetDelta a, paid := paid }

/-- The step function: refuse every `(primitive, value, before-leaf)` triple
outside the R2 table — the refused reads included — and otherwise apply the
edge. -/
def step (s : RegistryState) (a : Action) : Except String Result :=
  match refusal s a with
  | some why => .error why
  | none => .ok (applyEdge s a)

/-- Sequentially fold a nonempty batch; the k-th request is applied to the
state the first k−1 produced, so a read is verified against the intermediate
root at its own position. -/
def foldActions (s : RegistryState) (batch : List Action) : Except String Result :=
  match batch with
  | [] => .ok (emptyResult s)
  | b :: bs => do
    let first ← step s b
    let rest ← foldActions first.state bs
    pure (combineResults first rest)

/-- The atomic fold: a zero-request batch is refused; every request applies or
the whole batch refuses; any claimed mint differing from the summed delta of the
folded edges at any `(kind, key)` is refused. The guard is per asset, not per
kind: a batch that claims one key's token twice and another's not at all
balances per kind and is still refused. -/
def foldBatch (s : RegistryState) (batch : List Action) : Except String Result := do
  if batch.isEmpty then throw "empty-fold"
  let r ← foldActions s batch
  if assetSame (claimedMint batch) (actualMint batch) then pure r else throw "net-mint-mismatch"

/-- The ledger/trie consistency invariant: the root commits to the map, the
biconditional supply laws hold for active and absent tokens, and every terminal
attestation and custody entry is about a leaf that can still be what it says.
Holds for every reachable state; the naming profile specializes it as
`WellFormed`. -/
def Consistent (s : RegistryState) : Prop :=
  s.config.root = rootOf s.trie ∧
  (∀ key, kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) ∧
  (∀ key, kindCount s .active key ≤ 1) ∧
  (∀ key, custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) ∧
  (∀ key, custodyCount s key ≤ 1) ∧
  (∀ h ∈ s.held, h.kind = .terminal → trieGet s.trie h.key = .known .terminal) ∧
  (∀ c ∈ s.custody, trieGet s.trie c.key = .known .absent) ∧
  (∀ c₁ ∈ s.custody, ∀ c₂ ∈ s.custody, c₁.key = c₂.key → c₁ = c₂)

/-- Reachability from genesis: the empty trie under a supplied configuration,
closed over successful steps. Reachability is a hypothesis, not a weakening:
over arbitrary `State` values the supply laws are simply false. -/
inductive Reachable : RegistryState → Prop where
  | initial (c : Config) :
      Reachable { config := { c with root := rootOf [] }, trie := [], custody := [], held := [] }
  | next {s : RegistryState} {a : Action} {r : Result} :
      Reachable s → step s a = .ok r → Reachable r.state

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

/-- How an output presents its datum: inline, by hash, or not at all. -/
inductive DatumForm where
  | inline | hashed | none
  deriving Repr, BEq, DecidableEq

/-- The state token count of the registry's single state UTxO. -/
def registryStateTokens : Nat := 1

/-- The cage reads the state and the destination datum directly, so both are
inline. -/
def registryDatumForm : DatumForm := .inline

/-- The approvals a request carries. An admitted tree edge carries exactly one;
a request with none is refused `no-approval` before it can spend anything. -/
def approvalsIn (r : Request) : Nat := r.approval.toList.length

/-- The request input covers the fold's tip when its lovelace reaches the
registry's pinned fee ceiling. -/
def lovelaceCoversTip (c : Config) (lovelace : Nat) : Bool := c.maxFee ≤ lovelace

/-- Every pin of the configuration except the root is unchanged: the state
output carries the same eight-field datum with one field moved. -/
def onlyRootChanged (before after : Config) : Bool :=
  after.maxFee == before.maxFee && after.processTime == before.processTime &&
  after.retractTime == before.retractTime &&
  after.applicationPolicy == before.applicationPolicy &&
  after.activePolicy == before.activePolicy &&
  after.absentPolicy == before.absentPolicy &&
  after.terminalPolicy == before.terminalPolicy

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

/-- The part an input or output plays in a fold transaction. `witness` is the
UTxO a requester holds a witness token at: the place an active or terminal token
lives between the fold that minted it and the fold that consumes it. `owner` is
an output paying a request's owner back. -/
inductive TxRole where
  | state | request | destination | cage | witness | owner
  deriving Repr, BEq, DecidableEq

/-- An input the fold spends: the registry's state UTxO, a request UTxO carrying
its approvals and the lovelace that pays the tip, or a UTxO holding a token the
fold destroys. `assets` is what the input brings in, so a burn has a source and
not merely a negative number in the mint. -/
structure TxInput where
  role : TxRole
  datum : DatumForm
  stateTokens : Nat
  approvals : Nat
  lovelace : Nat
  assets : List (Asset × Int) := []
  deriving BEq, DecidableEq

/-- An output the fold produces. `address` is `none` for the state output: the
model has no vocabulary for the registry's own address, and a constant invented
here would be exactly the kind of non-derivation this section exists to remove.
`commitment` is the hash the inline destination datum presents. -/
structure TxOutput where
  role : TxRole
  datum : DatumForm
  address : Option Nat
  stateTokens : Nat
  config : Option Config
  commitment : Option Nat
  assets : List (Asset × Int)
  /-- Ordered logical fields of the custody datum; `[refundAddress]` is the
  refund-only payload. This models field shape, not ledger serialization. -/
  custodyDatum : Option (List Nat) := none
  lovelace : Nat := 0
  deriving BEq, DecidableEq

/-- Recover custody identity from one absent asset of quantity one. Neither
the datum nor the request can supply a fallback key. -/
def custodyKey (o : TxOutput) : Option Key :=
  match o.assets with
  | [((.absent, key), 1)] => some key
  | _ => none

/-- The transaction of an admitted fold. -/
structure Tx where
  inputs : List TxInput
  outputs : List TxOutput
  mint : List (Asset × Int)
  signers : List Nat
  refunds : List (Nat × Nat)
  deriving BEq, DecidableEq

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
spends to destroy one: cage custody holds the absent tokens, and a requester
holds the active and terminal witnesses at the output the fold that minted them
named. Read off `route`, so the token is consumed from the place the same rule
sent it to. -/
def burnSourceRole (d : Destination) : TxRole :=
  match d with
  | .cageCustody => .cage
  | .requestOutput => .witness

/-- The inputs that supply the tokens this fold destroys: one UTxO per burned
asset, carrying exactly that asset in the quantity the mint takes away, at the
place the model says that kind of token lives. A fold that burns nothing spends
none of them, which is why `insertActive` still has two inputs. -/
def txBurnInputs (t : Result) (r : Request) : List TxInput :=
  t.mint.filterMap fun p =>
    if p.2 < 0 then
      some { role := burnSourceRole (route p.1.1 r), datum := registryDatumForm
           , stateTokens := 0, approvals := 0, lovelace := 0
           , assets := [(p.1, -p.2)] }
    else none

/-- The state output: the registry's single state UTxO, moved, carrying the
configuration the step produced under an inline datum. -/
def txStateOutput (t : Result) : TxOutput :=
  { role := .state, datum := registryDatumForm, address := none
  , stateTokens := registryStateTokens, config := some t.state.config
  , commitment := none, assets := [] }

/-- The destination output: routed to the address the request named, carrying an
inline datum whose commitment is the scoping tuple's, and holding exactly the
tokens the edge routed to the requester. -/
def txDestinationOutput (t : Result) (r : Request) : TxOutput :=
  { role := .destination, datum := registryDatumForm
  , address := some (requestDestination r), stateTokens := 0, config := none
  , commitment := some (datumHash (destinationDatum r))
  , assets := routedPayment t r .requestOutput }

/-- The address custody outputs sit at: the cage. -/
abbrev cageAddress : Nat := 0

/-- The cage output, present only when this edge routes a token to cage custody.
`insertActive` routes none, so its transaction has exactly two outputs; the
constructor is general so the shape is not special-cased to one edge. -/
def txCageOutputs (t : Result) (r : Request) : List TxOutput :=
  let assets := routedPayment t r .cageCustody
  if assets.isEmpty then []
  else [{ role := .cage, datum := registryDatumForm, address := some cageAddress
        , stateTokens := 0, config := none, commitment := none, assets := assets
        , custodyDatum := some [r.refundAddress], lovelace := r.deposit }]

/-! ### Exits and what each one owes

A request leaves the registry's queue by exactly one exit: a fold of one of the
seven edges, a reject, or a retract. Each exit owes payments, stated per exit and
per request, reading no state and no configuration. A payment is a floor: value
an exit's payments do not name — fees, the folder's tip — is unconstrained. -/

/-- The nine ways a request ends: seven folds, a reject, a retract. -/
inductive Exit where
  | fold (e : Edge) | reject | retract
  deriving Repr, BEq, DecidableEq

/-- Who a payment is owed to: the address a delivering fold names, the cage's
custody, or the request's owner. -/
inductive Recipient where
  | destination (address : Nat) | custody | owner (key : Nat)
  deriving Repr, DecidableEq

/-- A payment owed: at least `atLeast` lovelace to `recipient`. -/
structure Payment where
  recipient : Recipient
  atLeast : Nat
  deriving Repr, BEq, DecidableEq

/-- What an exit owes. A fold delivering a token owes the deposit with it: to cage
custody for `insertAbsent`, to the named destination for `insertActive`,
`updateActive` and `witnessTerminal`. A fold delivering nothing and a reject owe
the deposit back to the owner. A retract owes the owner everything the request
held, deposit and tip; every other exit leaves the tip to the folder. -/
def obligations (exit : Exit) (request : Request) : List Payment :=
  match exit with
  | .fold .insertAbsent => [{ recipient := .custody, atLeast := request.deposit }]
  | .fold .insertActive | .fold .updateActive | .fold .witnessTerminal =>
    [{ recipient := .destination (requestDestination request), atLeast := request.deposit }]
  | .fold .updateTerminal | .fold .deleteAbsent | .fold .deleteActive | .reject =>
    [{ recipient := .owner request.owner, atLeast := request.deposit }]
  | .retract => [{ recipient := .owner request.owner, atLeast := request.deposit + request.tip }]

/-- Whether an output pays a recipient, by its role and address. Each output pays
at most one recipient, and the state continuation pays none. -/
def paysRecipient (recipient : Recipient) (output : TxOutput) : Bool :=
  match recipient with
  | .custody => output.role == .cage && output.address == some cageAddress
  | .destination address => output.role == .destination && output.address == some address
  | .owner key => output.role == .owner && output.address == some key

/-- The chain's reason for a recipient left unpaid: custody or a destination no
output reaches is `absent-custody` or `destination`; custody or a destination
reached short, or an owner short or unreached, is `deposit-returned`. -/
def unpaidReason (recipient : Recipient) (paying : List TxOutput) : String :=
  match recipient with
  | .custody => if paying.isEmpty then "absent-custody" else "deposit-returned"
  | .destination _ => if paying.isEmpty then "destination" else "deposit-returned"
  | .owner _ => "deposit-returned"

/-- What the payments owe one recipient: their floors, summed. -/
def owedTo (recipient : Recipient) (payments : List Payment) : Nat :=
  (payments.filter (·.recipient == recipient)).foldl (· + ·.atLeast) 0

/-- Judge a transaction's outputs against the payments owed: `none` when every
recipient is paid its summed floor, else the chain's reason for the first
recipient, in the order the payments are owed, that is not. One exit's judgement
is `settle (obligations exit request) outputs`; a batch is the concatenation of
its exits' payments. -/
def settle (payments : List Payment) (outputs : List TxOutput) : Option String :=
  (payments.map (·.recipient)).eraseDups.findSome? fun recipient =>
    let owed := owedTo recipient payments
    let paying := outputs.filter (paysRecipient recipient)
    if owed ≤ paying.foldl (· + ·.lovelace) 0 then none
    else some (unpaidReason recipient paying)

/-- A payment as the (address, value) pair `Result.paid` carries, at the address
`paysRecipient` reads for its recipient: the cage's for custody, the named address
for a destination, and the owner's key for the owner. -/
def paymentPaid (payment : Payment) : Nat × Nat :=
  match payment.recipient with
  | .custody => (cageAddress, payment.atLeast)
  | .destination address => (address, payment.atLeast)
  | .owner key => (key, payment.atLeast)

/-- One exit as a model step. A fold of edge `e` is exactly `step` when the
request names `e`, and is refused `exit-edge-mismatch` otherwise. A reject or a
retract carries no admission: it leaves the registry state as it was and mints
nothing. Every exit pays what it owes, each payment recorded by `paymentPaid`,
and then what its step pays: the custody refunds of `updateActive` and
`deleteAbsent`. -/
def exitStep (state : RegistryState) (exit : Exit) (request : Request) : Except String Result :=
  let executed : Except String Result :=
    match exit with
    | .fold e => if request.edge == e then step state request else .error "exit-edge-mismatch"
    | .reject | .retract => .ok (emptyResult state)
  match executed with
  | .error why => .error why
  | .ok t => .ok { t with paid := (obligations exit request).map paymentPaid ++ t.paid }

/-- One owner output per owner payment, at the owner's key, carrying the
payment's floor, presenting its datum in `datum` and naming `commitment`. -/
def ownerOutputs (datum : DatumForm) (commitment : Option Nat) (payments : List Payment) :
    List TxOutput :=
  payments.filterMap fun payment =>
    match payment.recipient with
    | .owner key =>
      some { role := .owner, datum := datum, address := some key, stateTokens := 0
           , config := none, commitment := commitment, assets := []
           , lovelace := payment.atLeast }
    | _ => Option.none

/-- The transaction an exit builds, or the model's refusal. A fold's spends the
registry's state and the request, and the tokens its mint destroys; it moves the
state, delivers to the destination the request names, locks custody when its edge
routes a token there, and pays the owner one output per owner payment: an
output with no datum that returns the request's approval, so it names that
approval's asset name as its commitment. A reject is
settled inside a transaction that spends the registry's state and returns it
unchanged, beside the request it spends; a retract is its own transaction,
spending only the request; each pays the owner one output per owner payment and
requires no signer. Every output that pays a recipient carries the lovelace the
exit owes it — the destination output its summed destination floor, the cage
output the deposit — and the transaction refunds exactly what the exit pays. -/
def txOfExit (state : RegistryState) (exit : Exit) (request : Request) (lovelace : Nat) :
    Except String Tx :=
  match exitStep state exit request with
  | .error why => .error why
  | .ok t =>
    let owed := obligations exit request
    let requestInput : TxInput :=
      { role := .request, datum := registryDatumForm
      , stateTokens := 0, approvals := approvalsIn request, lovelace := lovelace }
    let stateInput : TxInput :=
      { role := .state, datum := registryDatumForm
      , stateTokens := registryStateTokens, approvals := 0, lovelace := 0 }
    match exit with
    | .fold _ =>
      let destinationFloor := owedTo (.destination (requestDestination request)) owed
      .ok { inputs := [stateInput, requestInput] ++ txBurnInputs t request
          , outputs := txStateOutput t
              :: { txDestinationOutput t request with lovelace := destinationFloor }
              :: txCageOutputs t request
              ++ ownerOutputs .none (request.approval.map (·.assetName)) owed
          , mint := t.mint
          , signers := requiredSigners request
          , refunds := t.paid }
    | .reject =>
      .ok { inputs := [stateInput, requestInput]
          , outputs := txStateOutput t :: ownerOutputs registryDatumForm Option.none owed
          , mint := t.mint, signers := [], refunds := t.paid }
    | .retract =>
      .ok { inputs := [requestInput], outputs := ownerOutputs registryDatumForm Option.none owed
          , mint := t.mint, signers := [], refunds := t.paid }

/-- The transaction an admitted single-request fold builds, or the model's own
refusal: the transaction of the fold exit the request names. -/
def txOf (s : RegistryState) (r : Request) (lovelace : Nat) : Except String Tx :=
  txOfExit s (.fold r.edge) r lovelace

/-! The oracle observation surface. Ten total observations under
`Singular.Oracle` — the contract the frozen gate oracle reads. Each is defined
in terms of the real model: they delegate to it, or execute it, never restate
it. A surface that hard-coded answers while the model did something else is the
defect the mutation ledger exists to catch. -/

namespace Oracle

/-- The four admission cases the oracle distinguishes. `mismatched` is an
approval under the correct pinned policy whose `(edge, key, owner, destination)`
tuple does not match — the case that makes D-APPROVAL observable. -/
inductive Approval where
  | none | application | other | mismatched
  deriving Repr, BEq, DecidableEq

/-- Where a minted token goes. -/
inductive Destination where
  | cageCustody | requestOutput
  deriving Repr, BEq, DecidableEq

/-- The three candidate deposit destinations for a consumed absent token. Only
the first is correct (R-ADA); the other two exist so a wrong answer is
expressible and therefore detectable. -/
inductive RefundTarget where
  | insertRefundAddress | requestOutput | folder
  deriving Repr, BEq, DecidableEq

/-- The reference configuration the observation surface pins: the oracle's
`application` case is an approval minted under this configuration's pinned
application policy. -/
def referenceConfig : Config :=
  { root := rootOf [], maxFee := 0, processTime := 0, retractTime := 0
  , applicationPolicy := 7, activePolicy := 8, absentPolicy := 9, terminalPolicy := 10 }

/-- A well-formed approval under the reference policy, scoped exactly to the
canonical request of the edge. -/
def canonicalApproval (e : Edge) : Singular.Approval :=
  let r := canonicalRequest e
  { policy := referenceConfig.applicationPolicy, edge := e, key := r.key
  , owner := r.owner, destination := requestDestination r
  , assetName := approvalAssetName e r.key r.owner (requestDestination r) }

/-- The oracle's approval vocabulary, translated into real approvals:
`application` matches the canonical request, `other` carries a foreign policy,
`mismatched` carries the right policy but a perturbed key with an asset name
that binds the wrong tuple — well-formed, and wrong. -/
def toApproval (e : Edge) : Approval → Option Singular.Approval := fun
  | .none => none
  | .application => some (canonicalApproval e)
  | .other =>
    let ap := canonicalApproval e
    some { ap with policy := referenceConfig.applicationPolicy + 100 }
  | .mismatched =>
    let r := canonicalRequest e
    let ap := canonicalApproval e
    let perturbed := approvalAssetName e (r.key + 1) r.owner (requestDestination r)
    some { ap with key := r.key + 1, assetName := perturbed }

/-- The R2 from→to column, observed. -/
def transition (e : Edge) (before : Leaf) : Option Leaf :=
  Singular.transition e before

/-- Every delta cell, total: a kind the edge does not move is `0`. -/
def delta (e : Edge) (k : TokenKind) : Int :=
  deltaKind (Singular.delta e) k

/-- The leaf codec, one way. -/
def encode (s : State) : List UInt8 := (encodeState s).toList

/-- The leaf codec, the other way, including bytes that must not decode. -/
def decode (bytes : List UInt8) : Option State := decodeState bytes.toByteArray

/-- Admission for all four approval cases (R4, D-SELF and D-APPROVAL), answered
by the real per-request decision at the edge's canonical request. -/
def admits (e : Edge) (a : Approval) : Bool :=
  admitsFor referenceConfig (canonicalRequest e) (toApproval e a)

/-- Routing (R6, D7), observed. -/
def route (k : TokenKind) : Destination :=
  match Singular.route k (canonicalRequest .insertActive) with
  | .cageCustody => .cageCustody
  | .requestOutput => .requestOutput

/-- A canonical reachable-shape state: key 5 is `Known Absent`, its absent token
in cage custody with refund address 77 and value 100, named by the
`insertAbsent` request that created it. -/
def canonicalCustody : RegistryState :=
  let trie : Trie := [(5, .known .absent)]
  { config := { referenceConfig with root := rootOf trie }
  , trie := trie
  , custody := [{ key := 5, refundAddress := 77, value := 100 }]
  , held := [] }

/-- The reference request `refund` executes at the canonical state: an approval
under the pinned policy scoped to the request, key 5, refund address 91,
destination 99. -/
def referenceEdgeRequest (e : Edge) : Request :=
  let r := canonicalRequest e
  { r with deposit := 55
         , approval := if e == .witnessTerminal then none else some (canonicalApproval e) }

/-- R-ADA, observed by executing the model: fold each edge at the canonical
state and classify where the consumed absent token's value was paid. The two
edges that consume the absent token pay the refund address its custody datum
records; a wrong model pays the consuming request's output, the folder, or
retains the value, and is detected. -/
def refund (e : Edge) : Option RefundTarget :=
  match step canonicalCustody (referenceEdgeRequest e) with
  | .error _ => none
  | .ok r =>
    match r.paid with
    | [] => none
    | (dest, _) :: _ =>
      if dest == 77 then some .insertRefundAddress
      else if dest == 99 then some .requestOutput
      else some .folder

end Oracle

end Singular
