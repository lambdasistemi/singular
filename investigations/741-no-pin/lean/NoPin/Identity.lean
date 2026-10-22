import Singular.Model.Registry

/-! Hypotheses under #741, not accepted law. Questions: complete registry identity,
shared-policy role authentication and finite hash premises. No custody or ledger
validity is specified. All results are pure functions of explicit inputs. -/

namespace NoPin
open Singular Lean

/-- Hypothesis under #741, not accepted law; identity and hash questions. -/
abbrev Hash := List Nat → Nat
/-- Hypothesis under #741, not accepted law; identity and authorization tuple. -/
structure Payload where
  edge : Nat
  key : Nat
  owner : Nat
  destination : Nat
  nonce : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; shared-policy role question. -/
inductive Role where
  | state | witness | trieReady | application
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; complete-identity ruling and rejected contrast. -/
inductive Binding where
  | full | nameOnly
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; unresolved recognition readings. -/
inductive Reading where
  | policyOnly | authenticated
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; identity/hash question and complete-identity ruling. -/
inductive Preimage where
  | application (release : Nat)
  | statePolicy (application : Nat)
  | seed (reference : OutRef)
  | role (role : Role) (registry : TokenId) (key : Nat)
  | approval (registry : TokenId) (payload : Payload)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; explicit encoding premise. -/
abbrev Codec := Preimage → List Nat
/-- Hypothesis under #741, not accepted law; structural natural encoding, not chain bytes. -/
def encode : Codec
  | .application r => [0, r]
  | .statePolicy a => [1, a]
  | .seed r => [2, r.tx, r.index]
  | .role role r k => [3, match role with
      | .state => 0 | .witness => 1 | .trieReady => 2 | .application => 3,
      r.policy, r.name, k]
  | .approval r p => [4, r.policy, r.name, p.edge, p.key, p.owner, p.destination, p.nonce]
/-- Hypothesis under #741, not accepted law; finite encoding question. -/
abbrev finiteEncoding (code : Codec) (domain : List Preimage) : Prop :=
  domain.all (fun a => domain.all (fun b => a == b || code a != code b)) = true
/-- Hypothesis under #741, not accepted law; finite collision question, no universal injectivity. -/
abbrev finiteHash (hash : Hash) (code : Codec) (domain : List Preimage) : Prop :=
  domain.all (fun a => domain.all (fun b => code a == code b || hash (code a) != hash (code b))) = true
/-- Hypothesis under #741, not accepted law; acyclic application identity. -/
def applicationPolicy (hash : Hash) (code : Codec) (release : Nat) : Nat :=
  hash (code (.application release))
/-- Hypothesis under #741, not accepted law; state identity depends on application only. -/
def statePolicy (hash : Hash) (code : Codec) (applicationPolicyId : Nat) : Nat :=
  hash (code (.statePolicy applicationPolicyId))
/-- Hypothesis under #741, not accepted law; same-seed name scope question. -/
def stateName (hash : Hash) (code : Codec) (seed : OutRef) : Nat :=
  hash (code (.seed seed))
/-- Hypothesis under #741, not accepted law; complete-identity ruling. -/
def registry (hash : Hash) (code : Codec) (release : Nat) (seed : OutRef) : TokenId :=
  ⟨statePolicy hash code (applicationPolicy hash code release), stateName hash code seed⟩
/-- Hypothesis under #741, not accepted law; shared-policy role question. -/
def roleAsset (hash : Hash) (code : Codec) (r : TokenId) (role : Role) (key : Nat) : TokenId :=
  match role with
  | .state => r
  | _ => ⟨r.policy, hash (code (.role role r key))⟩
/-- Hypothesis under #741, not accepted law; complete approval identity ruling. applicationPolicyId is the application policy; r is the complete state policy/name identity. -/
def approvalAsset (binding : Binding) (hash : Hash) (code : Codec) (applicationPolicyId : Nat)
    (r : TokenId) (payload : Payload) : TokenId :=
  let bound := match binding with | .full => r | .nameOnly => { r with policy := 0 }
  ⟨applicationPolicyId, hash (code (.approval bound payload))⟩
/-- Hypothesis under #741, not accepted law; role provenance is supplied evidence. -/
structure Observation where
  asset : TokenId
  stateDatum : Bool
  provenance : TokenId
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; public inversion inventory. -/
inductive Case where
  | approvalFull | approvalNameOnly | policyOnly
  | state | witness | trieReady | application | genesis | history
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; atomic guard sites for the mutant ledger only. -/
inductive Guard where
  | approvalFull | approvalNameOnly | policyOnlyPolicy | policyOnlyDatum
  | statePolicy | stateName | stateProvenance | stateDatum
  | witnessPolicy | witnessName | witnessProvenance
  | trieReadyPolicy | trieReadyName | trieReadyProvenance
  | applicationPolicy | applicationName | applicationProvenance
  | genesisSeed | genesisInvocation | genesisMint | genesisQuantity | genesisOutput
  | historySpentOnce
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; none is the candidate, flip changes one guard. -/
inductive Mutation where
  | none | flip (guard : Guard)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; one-site mutation interpretation. -/
def applyGuard (m : Mutation) (site : Guard) (condition : Bool) : Bool :=
  if m == .flip site then !condition else condition
/-- Hypothesis under #741, not accepted law; role-to-guard classification. -/
def roleGuards : Role → Guard × Guard × Guard
  | .state => (.statePolicy, .stateName, .stateProvenance)
  | .witness => (.witnessPolicy, .witnessName, .witnessProvenance)
  | .trieReady => (.trieReadyPolicy, .trieReadyName, .trieReadyProvenance)
  | .application => (.applicationPolicy, .applicationName, .applicationProvenance)
/-- Hypothesis under #741, not accepted law; full binding ruling and rejected name-only reading. -/
def approve (m : Mutation) (binding : Binding) (hash : Hash) (code : Codec)
    (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) : Bool :=
  let site := match binding with | .full => Guard.approvalFull | .nameOnly => .approvalNameOnly
  applyGuard m site (supplied == approvalAsset binding hash code app r payload)
/-- Hypothesis under #741, not accepted law; policy-only versus role/name/provenance question.
A genuine witness with a fabricated state datum retains its own asset and origin. -/
def recognize (m : Mutation) (reading : Reading) (hash : Hash) (code : Codec)
    (r : TokenId) (role : Role) (key : Nat) (o : Observation) : Bool :=
  match reading with
  | .policyOnly => applyGuard m .policyOnlyPolicy (o.asset.policy == r.policy) &&
      applyGuard m .policyOnlyDatum o.stateDatum
  | .authenticated =>
      let expected := roleAsset hash code r role key
      let (policySite, nameSite, provenanceSite) := roleGuards role
      applyGuard m policySite (o.asset.policy == expected.policy) &&
      applyGuard m nameSite (o.asset.name == expected.name) &&
      applyGuard m provenanceSite (o.provenance == expected) &&
      (if role == .state then applyGuard m .stateDatum o.stateDatum else true)
/-- Hypothesis under #741, not accepted law; minimal ledger-boundary observation. -/
structure TxOutput where
  assets : List (TokenId × Nat)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; maps to future #679/#680 vocabulary, carries no laws. -/
structure TxView where
  spent : List OutRef
  outputs : List TxOutput
  mint : List (TokenId × Int)
  invoked : List Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; complete asset quantity observation. -/
def mintQty (tx : TxView) (asset : TokenId) : Int :=
  ((tx.mint.filter (fun entry => entry.1 == asset)).map (·.2)).sum
/-- Hypothesis under #741, not accepted law; output quantity observation. -/
def outputQty (o : TxOutput) (asset : TokenId) : Nat :=
  ((o.assets.filter (fun entry => entry.1 == asset)).map (·.2)).sum
/-- Hypothesis under #741, not accepted law; abstract genesis predicate, never ledger validity. -/
def genesis (m : Mutation) (tx : TxView) (seed : OutRef) (asset : TokenId) : Bool :=
  applyGuard m .genesisSeed (tx.spent.count seed == 1) &&
  applyGuard m .genesisInvocation (tx.invoked.contains asset.policy) &&
  applyGuard m .genesisMint (mintQty tx asset == 1) &&
  applyGuard m .genesisQuantity ((tx.outputs.map (fun o => outputQty o asset)).sum == 1) &&
  applyGuard m .genesisOutput ((tx.outputs.filter (fun o => outputQty o asset == 1)).length == 1)
/-- Hypothesis under #741, not accepted law; history spent-once is an explicit premise only. -/
def historyAllows (m : Mutation) (history : List TxView) : Bool :=
  applyGuard m .historySpentOnce (decide (history.flatMap (·.spent)).Nodup)

end NoPin
