import Singular.Model.Request
import Singular.Model.Transaction

/-! Allowed edges, approval and refusal, step and atomic batch, consistency and reachability. -/

namespace Singular
open Lean

/-- The historical edge constructors retain their wire ordinals. Only these
 two operations belong to the permanent first-milestone contract. -/
def allowed (e : Edge) : Bool :=
  e == .insertActive || e == .updateTerminal

/-- Mint deltas exist only for supported operations. Excluded encodings never
 reach an admitted fold and have no production token movement. -/
def delta (e : Edge) : List (TokenKind × Int) :=
  match e with
  | .insertActive => [(.active, 1)]
  | .updateTerminal => [(.active, -1)]
  | _ => []

/-- Exactly two trie transitions; every excluded encoding returns none. -/
def transition (e : Edge) (before : Leaf) : Option Leaf :=
  match e, before with
  | .insertActive, .unknown => some (.known .active)
  | .updateTerminal, .known .active => some (.known .terminal)
  | _, _ => none

/-- One fold action is one request. -/
def Action := Request

/-- The keyed delta of one request: the edge's seven-edge delta, each entry named by the
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

/-- Where a minted token is routed (token-routing). -/
inductive Destination where
  | requestOutput
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The active witness goes to the output the request named. -/
def route (k : TokenKind) (_request : Request) : Destination :=
  match k with
  | .active => .requestOutput

/-- The canonical request of each edge, in the frame where the frozen
three-argument `admits` observes admission: key 5; owner 42, or 91 — the refund
address — for the absent edges; destination 99, or the cage-custody sentinel 0
for `insertAbsent`. -/
def canonicalRequest (e : Edge) : Request :=
  match e with
  | .insertAbsent => { edge := e, key := 5, owner := 91, refundAddress := 91 }
  | .deleteAbsent => { edge := e, key := 5, owner := 91, refundAddress := 91 }
  | _ => { edge := e, key := 5, owner := 42, output := 99 }

/-- Both supported operations need the pinned application's exact approval.
 This shared predicate checks a tuple; refusal separately enforces the two-edge boundary. -/
def admitsFor (c : Config) (r : Request) (approval : Option Approval) : Bool :=
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
  allowed e && admitsFor c (canonicalRequest e) approval

/-- Refuse excluded encodings before approvals or proofs; accepted actions
 still owe every original approval, leaf and active-token obligation. -/
def refusal (s : RegistryState) (a : Action) : Option String :=
  if !allowed a.edge then some "edge-inadmissible"
  else match a.approval with
    | none => some "no-approval"
    | some ap =>
      if ap.policy != s.config.applicationPolicy then some "no-approval"
      else if !admitsFor s.config a a.approval then some "approval-mismatch"
      else
        let before := trieGet s.trie a.key
        let activePresent := s.held.any fun h => h.key == a.key && h.kind == .active
        match a.edge, before with
        | .insertActive, .unknown => none
        | .insertActive, _ => some "key-exists"
        | .updateTerminal, .known .active =>
            if activePresent then none else some "token-missing"
        | .updateTerminal, .unknown => some "key-unknown"
        | .updateTerminal, .known .absent => some "not-booked"
        | .updateTerminal, .known .terminal => some "terminal-immutable"
        | _, _ => some "edge-inadmissible"

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

/-- Apply one of the two admitted operations. The fallback has no effect and
 is unreachable through step, which refuses every excluded encoding. -/
def applyEdge (s : RegistryState) (a : Action) : Result :=
  let state : RegistryState :=
    match a.edge with
    | .insertActive =>
      let trie := trieSet s.trie a.key (.known .active)
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , held := { key := a.key, kind := .active, output := a.output
                        , datum := a.datum } :: s.held }
    | .updateTerminal =>
      let trie := trieSet s.trie a.key (.known .terminal)
      { s with trie := trie
             , config := { s.config with root := rootOf trie }
             , held := s.held.filter fun h => !(h.key == a.key && h.kind == .active) }
    | _ => s
  { state, mint := assetDelta a, paid := [] }

/-- A step succeeds only when refusal admits its action. -/
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

/-- A batch can burn only inputs, never an active holding created by one of
its earlier requests. Step and mint refusals are checked before this scan. -/
def batchConsumesCreated (batch : List Request) : Option String := go [] batch
where
  go (created : List Key) : List Request → Option String
    | [] => none
    | r :: rs =>
      if r.edge == .updateTerminal && created.contains r.key then some "token-missing"
      else go (if r.edge == .insertActive then r.key :: created else created) rs

/-- The atomic fold: a zero-request batch is refused; every request applies or
the whole batch refuses; any claimed mint differing from the summed delta of the
folded edges at any `(kind, key)` is refused. The guard is per asset, not per
kind: a batch that claims one key's token twice and another's not at all
balances per kind and is still refused. After that check, a termination of an
active holding created earlier in this batch is refused `token-missing`. -/
def foldBatch (s : RegistryState) (batch : List Action) : Except String Result := do
  if batch.isEmpty then throw "empty-fold"
  let r ← foldActions s batch
  if assetSame (claimedMint batch) (actualMint batch) then
    match batchConsumesCreated batch with
    | some why => throw why
    | none => pure r
  else throw "net-mint-mismatch"

/-- The ledger/trie consistency invariant: the root commits to the map, the
biconditional supply law holds for active tokens: at most one per key, and exactly one
iff the leaf is active.
Holds for every reachable state; the naming profile specializes it as
`WellFormed`. -/
def Consistent (s : RegistryState) : Prop :=
  s.config.root = rootOf s.trie ∧
  (∀ key, kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) ∧
  (∀ key, kindCount s .active key ≤ 1)

/-- Reachability from genesis: the empty trie under a supplied configuration,
closed over successful steps. Reachability is a hypothesis, not a weakening:
over arbitrary `State` values the supply laws are simply false. -/
inductive Reachable : RegistryState → Prop where
  | initial (c : Config) :
      Reachable { config := { c with root := rootOf [] }, trie := [], held := [] }
  | next {s : RegistryState} {a : Action} {r : Result} :
      Reachable s → step s a = .ok r → Reachable r.state


end Singular
