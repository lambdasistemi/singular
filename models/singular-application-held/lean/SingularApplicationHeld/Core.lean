import SingularApplicationHeld.Assets

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/

namespace SingularApplicationHeld
open Singular Lean

/-- published identities stay distinct. -/
structure PublishedRelease where
  applicationPolicy : Nat
  applicationCredential : Nat
  stateProgram : Nat
  statePolicy : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Abstract full address; the staking reference is an identity, not chain bytes. -/
structure Address where
  paymentCredential : Nat
  stakingCredential : Option Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

instance : LawfulBEq Address where
  eq_of_beq := by intro a b same; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]

/-- complete operation/role preimages. -/
inductive Preimage where
  | state (seed : OutRef)
  | active (registry : TokenId) (key : Key)
  | applicationConfiguration (registry : TokenId)
  | registrationApproval (registry : TokenId) (key : Key)
      (holdingAddress : Address) (initialDatum : Nat) (deposit : Nat)
  | terminationApproval (registry : TokenId) (key : Key)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- no chain byte codec is selected. -/
abbrev Codec := Preimage → List Nat
/-- no cryptographic implementation is selected. -/
abbrev Hash := List Nat → Nat
/-- the root interpretation is explicit. -/
abbrev TrieCommit := Trie → Nat
/-- separate finite serialization premise. -/
def FiniteEncoding (code : Codec) (domain : List Preimage) : Prop :=
  ∀ a ∈ domain, ∀ b ∈ domain, code a = code b → a = b
/-- separate finite collision premise. -/
def FiniteCollisionFree (hash : Hash) (code : Codec) (domain : List Preimage) : Prop :=
  ∀ a ∈ domain, ∀ b ∈ domain, hash (code a) = hash (code b) → code a = code b

/-- state identity binds the public seed. -/
def stateAsset (hash : Hash) (code : Codec) (release : PublishedRelease)
    (seed : OutRef) : TokenId :=
  ⟨release.statePolicy, hash (code (.state seed))⟩
/-- complete registry and active role. -/
def activeAsset (hash : Hash) (code : Codec) (registry : TokenId) (key : Key) : TokenId :=
  ⟨registry.policy, hash (code (.active registry key))⟩
/-- exact approved registration payload. -/
def registrationApproval (hash : Hash) (code : Codec) (release : PublishedRelease)
    (registry : TokenId) (key : Key) (address : Address) (datum deposit : Nat) : TokenId :=
  ⟨release.applicationPolicy, hash (code (.registrationApproval registry key address datum deposit))⟩
/-- exact approved termination identity. -/
def terminationApproval (hash : Hash) (code : Codec) (release : PublishedRelease)
    (registry : TokenId) (key : Key) : TokenId :=
  ⟨release.applicationPolicy, hash (code (.terminationApproval registry key))⟩
/-- immutable per-registry parameters. -/
structure ApplicationParameters where
  registrationCost : Nat
  minimumTip : Nat
  processTime : Nat
  retractTime : Nat
  bookingWidth : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- same-output datum category observation. -/
inductive OutputDatum where
  | root (commitment : Nat)
  | application (data : Nat)
  | configuration (parameters : ApplicationParameters)
  | empty
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- quantities/datums belong to this output. -/
structure ObservedOutput where
  reference : OutRef
  credential : Nat
  lovelace : Nat
  datum : OutputDatum
  assets : List (TokenId × Nat)
  stakingCredential : Option Nat := none
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The approval commits both observed address components. Custody checks use `credential`. -/
@[simp] def ObservedOutput.address (output : ObservedOutput) : Address :=
  ⟨output.credential, output.stakingCredential⟩

/-- complete positive-quantity census. -/
def quantity (output : ObservedOutput) (asset : TokenId) : Nat :=
  ((output.assets.filter fun entry => entry.1 == asset).map (·.2)).sum
/-- public genesis seed is not hash inversion. -/
structure PublicRegistry where
  identity : TokenId
  seed : OutRef
  state : ObservedOutput
  trie : Trie
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- one action and its physical input reference. -/
inductive Change where
  | register (requestReference : OutRef) (key : Key) (holdingIndex : Nat) (approvedDeposit : Nat)
  | terminate (requestReference : OutRef) (key : Key)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- action provenance is explicit. -/
def Change.reference : Change → OutRef
  | .register ref _ _ _ | .terminate ref _ => ref
/-- logical keys are not hashed asset names. -/
def Change.key : Change → Key
  | .register _ key _ _ | .terminate _ key => key

/-- no ledger evaluator or UTxO updater. -/
structure FoldObservation where
  before : PublicRegistry
  after : PublicRegistry
  assets : SingularApplicationHeld.Assets.TxView
  spentOutputs : List ObservedOutput
  outputs : List ObservedOutput
  changes : List Change
  signers : List Nat
  interval : Interval
  fee : Nat
  donation : Nat
  deriving BEq, DecidableEq, ToJson, FromJson

/-- atomic production decision sites. -/
inductive Guard where
  | stateCredential | statePolicy | stateName | stateQuantity | stateDatum | stateBare
  | genesisSeed | genesisInvocation | genesisMint | genesisOutput | genesisEmpty
  | changeReference | changeApprovalShape | changeApproval | changeApprovalBurn | changeLeaf
  | registrationPlacement | registrationMint | registrationDeposit
  | terminationHeld | terminationBurn
  | foldIdentity | foldBefore | foldNonempty | foldDistinct
  | foldPairing | foldTrie | foldContinuation | foldAddress | foldValue
  | foldWholePolicy | foldNoNewConsumed
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- a selector changes one decision site. -/
inductive Mutation where
  | none | flip (guard : Guard)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- isolated selector interpretation. -/
def applyGuard (mutation : Mutation) (site : Guard) (condition : Bool) : Bool :=
  if mutation == .flip site then !condition else condition

/-- ADA plus exactly the one state asset. -/
def bareState (output : ObservedOutput) (asset : TokenId) : Bool :=
  quantity output asset == 1 && output.assets.all (fun entry => entry.1 == asset)
/-- genuine active assets cannot pass by policy alone. -/
def recognizeState (mutation : Mutation) (hash : Hash) (code : Codec)
    (release : PublishedRelease) (seed : OutRef) (output : ObservedOutput) : Bool :=
  let asset := stateAsset hash code release seed
  let entry := output.assets.head?.getD (asset, 0)
  applyGuard mutation .stateCredential (output.credential == release.statePolicy) &&
  applyGuard mutation .statePolicy (entry.1.policy == asset.policy) &&
  applyGuard mutation .stateName (entry.1.name == asset.name) &&
  applyGuard mutation .stateQuantity (entry.2 == 1) &&
  applyGuard mutation .stateDatum (match output.datum with | .root _ => true | _ => false) &&
  applyGuard mutation .stateBare (output.assets.length == 1)

/-- compare signed sums over complete own-policy support. -/
def policyDelta (tx : SingularApplicationHeld.Assets.TxView) (policy : Nat) (expected : List (TokenId × Int)) : Bool :=
  let support := (tx.mint ++ expected).map (·.1)
  support.all fun asset => asset.policy != policy ||
    SingularApplicationHeld.Assets.mintQty tx asset == ((expected.filter fun entry => entry.1 == asset).map (·.2)).sum

/-- first state comes only from once-spent seed genesis. -/
def genesis (mutation : Mutation) (hash : Hash) (code : Codec) (commit : TrieCommit)
    (release : PublishedRelease) (seed : OutRef) (tx : SingularApplicationHeld.Assets.TxView)
    (outputs : List ObservedOutput) : Bool :=
  let asset := stateAsset hash code release seed
  let candidates := outputs.filter fun output => quantity output asset > 0
  applyGuard mutation .genesisSeed (tx.spent.count seed == 1) &&
  applyGuard mutation .genesisInvocation (tx.invoked.contains release.statePolicy) &&
  applyGuard mutation .genesisMint (policyDelta tx release.statePolicy [(asset, 1)]) &&
  applyGuard mutation .genesisOutput (candidates.length == 1 && candidates.all (fun output =>
    recognizeState .none hash code release seed output)) &&
  applyGuard mutation .genesisEmpty (candidates.all fun output => output.datum == .root (commit []))

/-- read the actual committed holding output. -/
def holdingAt (observation : FoldObservation) (index : Nat) : Option ObservedOutput :=
  observation.outputs[index]?
/-- registration payload comes from its proposed actual output. -/
def approvalFor (hash : Hash) (code : Codec) (release : PublishedRelease)
    (observation : FoldObservation) (change : Change) : Option TokenId := do
  match change with
  | .register _ key index deposit =>
    let output ← holdingAt observation index
    let .application datum := output.datum | none
    return registrationApproval hash code release observation.before.identity key output.address datum deposit
  | .terminate _ key =>
    return terminationApproval hash code release observation.before.identity key

/-- actual whole-policy delta derived from operations. -/
def expectedDelta (hash : Hash) (code : Codec) (observation : FoldObservation) : List (TokenId × Int) :=
  observation.changes.map fun change =>
    (activeAsset hash code observation.before.identity change.key,
      match change with | .register .. => 1 | .terminate .. => -1)

/-- each registration has its own carrier. -/
def separateHolding (observation : FoldObservation) (reference : OutRef) (index : Nat) : Bool :=
  observation.changes.all fun action => match action with
    | .register other _ otherIndex _ => other == reference || otherIndex != index
    | .terminate .. => true
/-- the carrier contains one new token in total. -/
def oneNewToken (hash : Hash) (code : Codec) (observation : FoldObservation)
    (output : ObservedOutput) : Bool :=
  ((observation.changes.filterMap fun action => match action with
    | .register _ key _ _ => some (activeAsset hash code observation.before.identity key)
    | .terminate .. => none).map (quantity output)).sum == 1

/-- one exact approval/input, trie step and active movement. -/
def change (mutation : Mutation) (hash : Hash) (code : Codec) (release : PublishedRelease)
    (trie : Trie) (action : Change) (observation : FoldObservation) : Except String Trie := do
  let some input := observation.spentOutputs.find? (fun output => output.reference == action.reference)
    | throw "missing-request-input"
  let some approval := approvalFor hash code release observation action | throw "missing-approval-preimage"
  let active := activeAsset hash code observation.before.identity action.key
  unless applyGuard mutation .changeReference
      (observation.assets.spent.count action.reference == 1 &&
       (observation.spentOutputs.filter fun output => output.reference == action.reference).length == 1)
    do throw "request-reference"
  let supplied := input.assets.filter fun entry => entry.1.policy == release.applicationPolicy && entry.2 > 0
  let actual := supplied.head?.getD (approval, 0)
  unless applyGuard mutation .changeApprovalShape (supplied.length == 1 && actual.2 == 1)
    do throw "approval-shape"
  unless applyGuard mutation .changeApproval (actual.1 == approval) do throw "operation-approval"
  unless applyGuard mutation .changeApprovalBurn (SingularApplicationHeld.Assets.mintQty observation.assets actual.1 == -1)
    do throw "approval-burn"
  match action with
  | .register _ key index deposit =>
    unless applyGuard mutation .changeLeaf (trieGet trie key == .unknown) do throw "key-not-unknown"
    let some output := holdingAt observation index | throw "missing-new-holding"
    unless applyGuard mutation .registrationPlacement
        (quantity output active == 1 &&
         (observation.outputs.map fun output => quantity output active).sum == 1 &&
         separateHolding observation action.reference index && oneNewToken hash code observation output)
      do throw "active-placement"
    unless applyGuard mutation .registrationMint (SingularApplicationHeld.Assets.mintQty observation.assets active == 1)
      do throw "active-mint"
    unless applyGuard mutation .registrationDeposit (deposit ≤ output.lovelace)
      do throw "holding-deposit-short"
    return trieSet trie key (.known .active)
  | .terminate _ key =>
    unless applyGuard mutation .changeLeaf (trieGet trie key == .known .active) do throw "key-not-active"
    unless applyGuard mutation .terminationHeld (quantity input active == 1) do throw "held-active"
    unless applyGuard mutation .terminationBurn (SingularApplicationHeld.Assets.mintQty observation.assets active == -1)
      do throw "active-burn"
    return trieSet trie key (.known .terminal)

/-- all supplied operations execute in order. -/
def changeBatch (mutation : Mutation) (hash : Hash) (code : Codec) (release : PublishedRelease)
    (observation : FoldObservation) : Except String Trie :=
  observation.changes.foldlM (fun trie action => change mutation hash code release trie action observation)
    observation.before.trie

/-- every input carrying an application asset pairs once. -/
def exactPairing (release : PublishedRelease) (observation : FoldObservation) : Bool :=
  let refs := observation.changes.map Change.reference
  let approvals := observation.spentOutputs.filter fun output =>
    output.assets.any fun entry => entry.1.policy == release.applicationPolicy && entry.2 > 0
  refs.length == approvals.length && approvals.all (fun output => refs.contains output.reference)

/-- the complete state-policy support is checked. -/
def wholePolicyDelta (hash : Hash) (code : Codec) (observation : FoldObservation) : Bool :=
  policyDelta observation.assets observation.before.identity.policy (expectedDelta hash code observation)

/-- routes no request money; committed holding deposit and state integrity stay checked. -/
def fold (mutation : Mutation) (hash : Hash) (code : Codec) (commit : TrieCommit)
    (release : PublishedRelease) (observation : FoldObservation) : Bool :=
  let before := observation.before
  let after := observation.after
  let result := changeBatch mutation hash code release observation
  let newHoldings := observation.changes.filterMap fun action => match action with
    | .register _ _ index _ => holdingAt observation index
    | .terminate .. => none
  applyGuard mutation .foldIdentity
    (before.identity == stateAsset hash code release before.seed && after.identity == before.identity &&
      after.seed == before.seed) &&
  applyGuard mutation .foldBefore
    (recognizeState .none hash code release before.seed before.state &&
     before.state.datum == .root (commit before.trie) &&
     observation.assets.spent.count before.state.reference == 1 &&
     observation.spentOutputs.contains before.state) &&
  applyGuard mutation .foldNonempty (!observation.changes.isEmpty) &&
  applyGuard mutation .foldDistinct (decide (observation.changes.map Change.reference).Nodup) &&
  applyGuard mutation .foldPairing (exactPairing release observation) &&
  applyGuard mutation .foldTrie ((match result with | .ok trie => trie == after.trie | .error _ => false) &&
      after.state.datum == .root (commit after.trie)) &&
  applyGuard mutation .foldContinuation
    ((observation.outputs.filter fun output => quantity output before.identity > 0) == [after.state] &&
     bareState after.state before.identity) &&
  applyGuard mutation .foldAddress (after.state.credential == before.state.credential) &&
  applyGuard mutation .foldValue (before.state.lovelace ≤ after.state.lovelace) &&
  applyGuard mutation .foldWholePolicy (wholePolicyDelta hash code observation) &&
  applyGuard mutation .foldNoNewConsumed
    (newHoldings.all fun output => !observation.assets.spent.contains output.reference)

end SingularApplicationHeld
