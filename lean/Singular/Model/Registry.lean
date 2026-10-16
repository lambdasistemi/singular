import Singular.Model.Primitives

/-! Registry configuration, authenticated state and holdings. -/

namespace Singular
open Lean

/-- A ledger output identified by its creating transaction and position. -/
structure OutRef where
  tx : Nat
  index : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- A finite validity interval, lower included and upper excluded. -/
structure Interval where
  lower : Nat
  upper : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def Interval.width (i : Interval) : Nat := i.upper - i.lower
def Interval.valid (i : Interval) : Prop := i.lower < i.upper
def Interval.contains (i : Interval) (time : Nat) : Prop := i.lower ≤ time ∧ time < i.upper

instance (i : Interval) : Decidable i.valid := inferInstanceAs (Decidable (i.lower < i.upper))
instance (i : Interval) (time : Nat) : Decidable (i.contains time) :=
  inferInstanceAs (Decidable (i.lower ≤ time ∧ time < i.upper))

/-- Exact token identity, including both policy and asset name. -/
structure TokenId where
  policy : Nat
  name : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The state configuration. Every field except the root is fixed at creation. -/
structure Config where
  root : ByteArray
  minimumTip : Nat
  processTime : Nat
  retractTime : Nat
  applicationPolicy : Nat
  activePolicy : Nat
  absentPolicy : Nat
  terminalPolicy : Nat
  /-- Abstract identity of the registry state token, allocated by the consumer. -/
  registryId : Nat := 0
  registrationCost : Nat := 0
  bookingWidth : Nat := 0
  deriving BEq, DecidableEq

instance : ToJson Config where
  toJson c := Json.mkObj <|
    [ ("registryId", toJson c.registryId), ("root", toJson c.root), ("maxFee", toJson c.minimumTip)
    , ("processTime", toJson c.processTime), ("retractTime", toJson c.retractTime)
    , ("applicationPolicy", toJson c.applicationPolicy)
    , ("activePolicy", toJson c.activePolicy)
    , ("absentPolicy", toJson c.absentPolicy)
    , ("terminalPolicy", toJson c.terminalPolicy) ] ++
    (if c.registrationCost == 0 then [] else [("registrationCost", toJson c.registrationCost)]) ++
    (if c.bookingWidth == 0 then [] else [("bookingWidth", toJson c.bookingWidth)])

instance : FromJson Config where
  fromJson? j := do
    let root ← j.getObjVal? "root" >>= fromJson?
    let minimumTip ← j.getObjVal? "maxFee" >>= fromJson?
    let processTime ← j.getObjVal? "processTime" >>= fromJson?
    let retractTime ← j.getObjVal? "retractTime" >>= fromJson?
    let applicationPolicy ← j.getObjVal? "applicationPolicy" >>= fromJson?
    let activePolicy ← j.getObjVal? "activePolicy" >>= fromJson?
    let absentPolicy ← j.getObjVal? "absentPolicy" >>= fromJson?
    let terminalPolicy ← j.getObjVal? "terminalPolicy" >>= fromJson?
    let registryId ← match j.getObjVal? "registryId" with
      | .error _ => pure 0
      | .ok x => fromJson? x
    let registrationCost ← match j.getObjVal? "registrationCost" with
      | .error _ => pure 0
      | .ok x => fromJson? x
    let bookingWidth ← match j.getObjVal? "bookingWidth" with
      | .error _ => pure 0
      | .ok x => fromJson? x
    pure { root, minimumTip, processTime, retractTime, applicationPolicy
         , activePolicy, absentPolicy, terminalPolicy, registryId
         , registrationCost, bookingWidth }

/-- The booking interval is sized below the processing window. This is a
predicate for booking rules, not a restriction on decoding old configurations. -/
def Config.bookingWidthSized (c : Config) : Prop := c.bookingWidth < c.processTime

instance (c : Config) : Decidable c.bookingWidthSized :=
  inferInstanceAs (Decidable (c.bookingWidth < c.processTime))

/-- The expected state token uses the registry identity as an abstract policy
and the fixed abstract name zero. Observed tokens retain both components.
Mapping a real registry's token name into this abstraction is a separate
correspondence obligation; this definition does not establish that mapping. -/
def Config.stateToken (c : Config) : TokenId := ⟨c.registryId, 0⟩

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
the `insertAbsent` request named, and the value the token holds (custody-lovelace-refund). -/
structure Custody where
  key : Key
  refundAddress : Nat
  value : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- How an output presents its datum: inline, by hash, or not at all. -/
inductive DatumForm where
  | inline | hashed | none
  deriving Repr, BEq, DecidableEq

/-- A datum form's name, as every consumer spells it. -/
def datumFormName : DatumForm → String
  | .inline => "inline"
  | .hashed => "hashed"
  | .none => "none"

instance : ToJson DatumForm where
  toJson d := toJson (datumFormName d)

instance : FromJson DatumForm where
  fromJson? j := do
    match (← fromJson? j : String) with
    | "inline" => pure .inline
    | "hashed" => pure .hashed
    | "none" => pure .none
    | other => throw s!"no datum form is named {other}"

/-- The form an output carrying this datum presents: inline when it carries a
datum value, none when it carries none. A delivered output never presents its
datum by hash. -/
def datumFormOf : Option Nat → DatumForm
  | some _ => .inline
  | none => .none

/-- A datum value as every consumer spells it: the value, or `null` for none. -/
def datumJson : Option Nat → Json
  | some v => toJson v
  | none => Json.null

/-- Read a datum value spelled by `datumJson`; a field a caller omits is none. -/
def datumOfJson (j : Json) (field : String) : Except String (Option Nat) :=
  match j.getObjVal? field with
  | .error _ => pure none
  | .ok Json.null => pure none
  | .ok v => some <$> fromJson? v

/-- One active or terminal token routed to the output the request named. The
output carries the datum the delivering fold gave it — the request's own datum,
or none — which is what a later fold spending it as a witness finds there. -/
structure Holding where
  key : Key
  kind : TokenKind
  output : Nat
  datum : Option Nat := none
  deriving Repr, BEq, DecidableEq

/-- A holding serialises completely, its datum included, so a saved state
replays with the witness its delivery wrote. -/
instance : ToJson Holding where
  toJson h := Json.mkObj
    [ ("key", toJson h.key), ("kind", toJson h.kind), ("output", toJson h.output)
    , ("datum", datumJson h.datum) ]

/-- A holding a caller spells without a datum carries none, as a delivery under a
request carrying no datum does. -/
instance : FromJson Holding where
  fromJson? j := do
    let key ← j.getObjValAs? Key "key"
    let kind ← j.getObjValAs? TokenKind "kind"
    let output ← j.getObjValAs? Nat "output"
    let datum ← datumOfJson j "datum"
    pure { key, kind, output, datum }

/-- The `held` observation of one holding: the census reads its key, kind and
output. Its datum is observed on the transaction that spends it. -/
def heldObservationJson (h : Holding) : Json :=
  Json.mkObj [("key", toJson h.key), ("kind", toJson h.kind), ("output", toJson h.output)]

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

end Singular
