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

/-- Merge two delta lists into their per-kind sum. -/
def deltaPlus (a b : List (TokenKind × Int)) : List (TokenKind × Int) :=
  ((a.map Prod.fst ++ b.map Prod.fst).eraseDups).map fun k =>
    (k, deltaKind a k + deltaKind b k)

/-- Two delta lists carry the same per-kind sums. -/
def deltaSame (a b : List (TokenKind × Int)) : Bool :=
  (a.map Prod.fst ++ b.map Prod.fst).all fun k => deltaKind a k == deltaKind b k

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

/-- The commitment byte of a leaf in the root: a bound key commits to its
state's codec byte; `unknown` is a non-membership entry. -/
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
is the mint the transaction claims for this request, summed by the fold. -/
structure Request where
  edge : Edge
  key : Key
  owner : Nat := 0
  refundAddress : Nat := 0
  deposit : Nat := 0
  output : Nat := 0
  approval : Option Approval := none
  claimed : List (TokenKind × Int) := []
  deriving Repr, BEq, DecidableEq

/-- A request serialises completely too, so a corpus row carries the exact input
the fold was given. -/
instance : ToJson Request where
  toJson r := Json.mkObj
    [ ("edge", toJson r.edge), ("key", toJson r.key), ("owner", toJson r.owner)
    , ("refundAddress", toJson r.refundAddress), ("deposit", toJson r.deposit)
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
  mint : List (TokenKind × Int)
  paid : List (Nat × Nat)
  deriving BEq

def emptyResult (s : RegistryState) : Result :=
  { state := s, mint := [], paid := [] }

def combineResults (first rest : Result) : Result :=
  { state := rest.state, mint := deltaPlus first.mint rest.mint, paid := first.paid ++ rest.paid }

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
      let trie := trieSet s.trie a.key .unknown
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , custody := s.custody.filter (·.key != a.key) }
    | .deleteActive =>
      let trie := trieSet s.trie a.key .unknown
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
  { state := state, mint := delta a.edge, paid := paid }

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
the whole batch refuses; any claimed mint differing from the summed delta of
the folded edges is refused. -/
def foldBatch (s : RegistryState) (batch : List Action) : Except String Result := do
  if batch.isEmpty then throw "empty-fold"
  let r ← foldActions s batch
  let claimed := batch.foldl (fun acc b => deltaPlus acc b.claimed) []
  let actual := batch.foldl (fun acc b => deltaPlus acc (delta b.edge)) []
  if deltaSame claimed actual then pure r else throw "net-mint-mismatch"

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
