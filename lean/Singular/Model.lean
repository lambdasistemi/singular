import Lean

/-! Proposed logical abstractions for D1-D7, not a wire or ledger implementation.
Tagged terms stand for collision-free canonical commitments; lists are authenticated
logical maps/UTxO sets. Contract evidence is supplied, not verified application code.
A selected batch is atomic and never skips failures. This is an explicit model
profile, not a ruling on batch construction. Asset identity reuse is configurable. -/
namespace Singular
open Lean

inductive Value where | active | over
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
inductive Operation where | insert | update | delete
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Config where
  registry : Nat := 1
  applicationPolicy : Nat := 7
  requestAddress : Nat := 90
  representativePolicy : Nat := 8
  reuseIdentity : Bool := true
  /-- Pinned consumer script (NOTE-013/NOTE-019, sixth `State` field): the
  consumer script hash selected at bootstrap, preserved across every fold
  by whole-`Config` equality (`consume_config`, `setEntry_config`, and the
  `hc : s'.config = s.config` hypotheses below). A nonempty fold must also
  carry its invocation witness (`Witnesses.consumerWithdraw`). -/
  consumerPin : Nat := 9
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Representative where
  registry : Nat
  key : Nat
  policy : Nat
  assetScope : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Output where
  representative : Representative
  quantity : Nat := 1
  destination : Nat
  datum : Nat
  value : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Proposal where
  registry : Nat
  key : Nat
  applicationPolicy : Nat
  /-- Cancellation destination fixed by the application before the Insert
  commitment is minted. Because the proposal is the Insert token name, this
  address is committed rather than selected during withdrawal. -/
  refundAddress : Nat
  initial : Output
  scope : List Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Refund where
  destination : Nat
  value : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
inductive Commitment where
  | insert (proposal : Proposal)
  | withdraw (registry request : Nat) (refund : Refund)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Asset where
  policy : Nat
  name : Commitment
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Approval where
  asset : Asset
  accepted : Bool
  /-- Diagnostic contract-conformance evidence; never a native issuer check. -/
  conforms : Bool := true
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Request where
  id : Nat
  operation : Operation
  proposal : Proposal
  token : Option Asset := none
  held : Option Representative := none
  destination : Nat
  authenticatedOrigin : Bool
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure ApplicationUTxO where
  id : Nat
  key : Nat
  output : Output
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Entry where
  key : Nat
  value : Option Value := none
  incarnation : Nat := 0
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure State where
  config : Config := {}
  entries : List Entry := []
  applications : List ApplicationUTxO := []
  requests : List Request := []
  approvals : List Approval := []
  used : List Nat := []
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure ReleaseEvidence where
  source : Nat
  request : Request
  accepted : Bool
  conforms : Bool := true
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure EvolutionEvidence where
  source : Nat
  successor : ApplicationUTxO
  accepted : Bool
  conforms : Bool := true
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure FoldItem where
  request : Nat
  outputId : Nat := 0
  output : Option Output := none
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Witnesses where
  applicationMint : Bool := false
  applicationSpend : Bool := false
  nativeSpend : Bool := false
  representativeMint : Bool := false
  /-- Pinned-hook invocation (NOTE-013/NOTE-019): the nonempty fold's
  withdrawal of the exact `Config.consumerPin` script executed. A
  caller-written flag is not an invocation; this witness stands for the
  ledger-executed withdrawal. -/
  consumerWithdraw : Bool := false
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Delta where
  asset : Representative
  quantity : Int
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure ActionDelta where
  asset : Asset
  quantity : Int
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
inductive Action where
  | createInsert (request : Request) (approval : Approval) (witness : Witnesses)
  | mintWithdraw (approval : Approval) (witness : Witnesses)
  | release (source : Nat) (request : Request) (evidence : ReleaseEvidence) (witness : Witnesses)
  | evolve (source : Nat) (successor : ApplicationUTxO) (evidence : EvolutionEvidence) (witness : Witnesses)
  | outsider (request : Request)
  | withdraw (request : Nat) (asset : Asset) (refund : Refund) (witness : Witnesses)
  | fold (items : List FoldItem) (mint : List Delta) (actionNet : List ActionDelta) (witness : Witnesses)
  | moveAction (asset : Asset) (net : Int) (witness : Witnesses)
  | escape (request : Nat)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
structure Result where
  state : State
  logical : List Delta := []
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def entry (s : State) (key : Nat) : Entry :=
  (s.entries.find? (·.key == key)).getD { key := key }
def representative (s : State) (key : Nat) : Representative :=
  { registry := s.config.registry, key, policy := s.config.representativePolicy,     assetScope := if s.config.reuseIdentity then 0 else (entry s key).incarnation }
def fresh (s : State) (id : Nat) : Bool := !s.used.contains id
def consume (s : State) (id : Nat) : State :=
  { s with requests := s.requests.filter (·.id != id),            applications := s.applications.filter (·.id != id) }
def setEntry (s : State) (e : Entry) : State :=
  { s with entries := e :: s.entries.filter (·.key != e.key) }
def insertAsset (p : Proposal) : Asset := { policy := p.applicationPolicy, name := .insert p }
def proposalNative (s : State) (p : Proposal) : Bool :=
  p.registry == s.config.registry && p.applicationPolicy == s.config.applicationPolicy &&
  p.initial.representative.registry == p.registry && p.initial.representative.key == p.key &&
  p.initial.representative.policy == s.config.representativePolicy && p.initial.quantity == 1
def insertNative (s : State) (r : Request) : Bool :=
  r.operation == .insert && proposalNative s r.proposal && r.held.isNone &&
  r.destination == s.config.requestAddress && r.token == some (insertAsset r.proposal)
def releaseNative (s : State) (r : Request) : Bool :=
  r.operation != .insert && r.proposal.registry == s.config.registry &&
  r.destination == s.config.requestAddress && r.held.any (fun nft =>
    nft.registry == s.config.registry && nft.key == r.proposal.key &&
    nft.policy == s.config.representativePolicy)
def recognized (s : State) (a : Asset) : Bool :=
  a.policy == s.config.applicationPolicy && s.approvals.any (fun e => e.asset == a && e.accepted)
def approved (s : State) (a : Approval) (w : Witnesses) : Bool :=
  w.applicationMint && a.accepted && a.asset.policy == s.config.applicationPolicy

def requireSome (o : Option α) (reason : String) : Except String α :=
  match o with | some a => .ok a | none => .error reason

def foldOne (s : State) (i : FoldItem) : Except String Result := do
  let r ← requireSome (s.requests.find? (·.id == i.request)) "request-unavailable"
  if !r.authenticatedOrigin then throw "unauthenticated-request"
  let e := entry s r.proposal.key
  match r.operation with
  | .insert =>
    if !insertNative s r || !(r.token.any (recognized s)) then throw "insert-binding"
    if e.value.isSome then throw "occupied-key"
    if !r.proposal.scope.contains e.incarnation then throw "approval-scope"
    if r.proposal.initial.representative != representative s e.key then throw "representative-identity"
    if i.output != some r.proposal.initial || !fresh s i.outputId then throw "certified-output"
    let t := setEntry (consume s r.id) { e with value := some .active }
    return { state := { t with applications := { id := i.outputId, key := e.key,       output := r.proposal.initial } :: t.applications, used := i.outputId :: t.used },       logical := [{ asset := representative s e.key, quantity := 1 }] }
  | .update | .delete =>
    if !releaseNative s r || r.held != some (representative s r.proposal.key) then throw "terminal-binding"
    if e.value != some .active then throw "not-active"
    if i.output.isSome then throw "terminal-output"
    let t := setEntry (consume s r.id) { e with       value := if r.operation == .update then some .over else none,       incarnation := if r.operation == .delete then e.incarnation + 1 else e.incarnation }
    return { state := t, logical := [{ asset := representative s e.key, quantity := -1 }] }

def foldItems : State → List FoldItem → Except String Result
  | s, [] => .ok { state := s }
  | s, i :: items => do
    let first ← foldOne s i
    let rest ← foldItems first.state items
    return { state := rest.state, logical := first.logical ++ rest.logical }
def quantity (ds : List Delta) (asset : Representative) : Int :=
  (ds.filter (·.asset == asset)).foldl (fun n d => n + d.quantity) 0
def sameNet (a b : List Delta) : Bool :=
  (a ++ b).all (fun d => quantity a d.asset == quantity b d.asset)
def nonzero (ds : List Delta) : Bool := ds.any (fun d => quantity ds d.asset != 0)

def actionQuantity (ds : List ActionDelta) (asset : Asset) : Int :=
  (ds.filter (·.asset == asset)).foldl (fun n d => n + d.quantity) 0
def actionNonzero (ds : List ActionDelta) : Bool :=
  ds.any (fun d => actionQuantity ds d.asset != 0)

def step (s : State) (a : Action) : Except String Result := do
  match a with
  | .createInsert r cert w =>
    if !insertNative s r || !r.authenticatedOrigin || cert.asset != insertAsset r.proposal then
      throw "insert-binding"
    if !approved s cert w then throw "application-approval"
    if !fresh s r.id then throw "utxo-id-reuse"
    return { state := { s with requests := r :: s.requests,       approvals := cert :: s.approvals, used := r.id :: s.used } }
  | .mintWithdraw cert w =>
    if !approved s cert w then throw "application-approval"
    match cert.asset.name with
    | .insert _ => throw "withdraw-tag"
    | .withdraw registry _ _ =>
      if registry != s.config.registry then throw "registry-binding"
      return { state := { s with approvals := cert :: s.approvals } }
  | .release source r evidence w =>
    let u ← requireSome (s.applications.find? (·.id == source)) "application-unavailable"
    if !w.applicationSpend || !evidence.accepted || evidence.source != source ||
      evidence.request != r then throw "exact-release-authorization"
    if !releaseNative s r || !r.authenticatedOrigin || r.held != some u.output.representative ||
      u.key != r.proposal.key then throw "terminal-binding"
    if !fresh s r.id then throw "utxo-id-reuse"
    let t := consume s source
    return { state := { t with requests := r :: t.requests, used := r.id :: t.used } }
  | .evolve source successor evidence w =>
    let u ← requireSome (s.applications.find? (·.id == source)) "application-unavailable"
    if !w.applicationSpend || !evidence.accepted || evidence.source != source ||
      evidence.successor != successor then throw "application-evolution-authorization"
    if successor.output.representative != u.output.representative || successor.output.quantity != 1 ||
      successor.key != u.key then throw "evolution-representative"
    if !fresh s successor.id then throw "utxo-id-reuse"
    let t := consume s source
    return { state := { t with applications := successor :: t.applications,       used := successor.id :: t.used } }
  | .outsider r =>
    if !fresh s r.id then throw "utxo-id-reuse"
    if r.held.isSome then throw "outsider-cannot-create-representative"
    return { state := { s with requests := { r with authenticatedOrigin := false } :: s.requests,       used := r.id :: s.used } }
  | .withdraw id asset refund w =>
    let r ← requireSome (s.requests.find? (·.id == id)) "request-unavailable"
    if !w.nativeSpend then throw "native-witness"
    if !r.authenticatedOrigin || !insertNative s r then throw "withdraw-insert-only"
    if refund.destination != r.proposal.refundAddress then throw "withdraw-refund-address"
    if !recognized s asset || asset.name != .withdraw s.config.registry id refund then
      throw "withdraw-binding"
    return { state := consume s id }
  | .fold items mint actionNet w =>
    if !w.nativeSpend then throw "native-witness"
    if items == [] then throw "empty-fold"
    if !w.consumerWithdraw then throw "consumer-witness"
    let result ← foldItems s items
    if !sameNet result.logical mint then throw "net-mint-mismatch"
    if nonzero mint && !w.representativeMint then throw "representative-witness"
    if actionNonzero actionNet && !w.applicationMint then throw "application-mint-witness"
    return result
  | .moveAction asset net w =>
    if !recognized s asset then throw "unrecognized-action"
    if net != 0 then throw "movement-net-not-zero"
    -- Existing-token movement requires no mint witness and grants no new scope.
    return { state := s }
  | .escape _ => throw "completion-only-custody"

inductive Resolution where
  | absent | retired | pending | address (datum : Nat) | unauthenticated
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Proposed D7 profile: authenticated logical ledger view, Nat address datum. -/
def resolve (s : State) (key : Nat) (authenticated : Bool) : Resolution :=
  if !authenticated then .unauthenticated else
  match (entry s key).value with
  | none => .absent
  | some .over => .retired
  | some .active =>
    match s.applications.find? (fun u => u.key == key &&
      u.output.representative == representative s key && u.output.quantity == 1) with
    | some u => .address u.output.datum
    | none => .pending

def supply (s : State) (key : Nat) : Nat :=
  (s.applications.filter (fun u => u.output.representative == representative s key)).length +
  (s.requests.filter (fun r => r.held == some (representative s key))).length
def WellFormed (s : State) : Prop :=
  ∀ key, supply s key = if (entry s key).value = some .active then 1 else 0
inductive Reachable : State → Prop where
  | initial (c : Config) : Reachable { config := c }
  | next {s : State} {a : Action} {r : Result} : Reachable s → step s a = .ok r → Reachable r.state
end Singular
