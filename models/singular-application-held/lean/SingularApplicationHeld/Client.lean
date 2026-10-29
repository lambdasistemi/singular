import SingularApplicationHeld.RequestShapes

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/
namespace SingularApplicationHeld
open Singular Lean

/-- exact same-output request descriptors. -/
inductive PendingRequest where
  | registration (output : ObservedOutput) (data : RegistrationData)
  | termination (output : ObservedOutput) (registry : TokenId) (key : Key)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- actual request source. -/
def PendingRequest.output : PendingRequest → ObservedOutput
  | .registration output _ | .termination output _ _ => output
/-- complete registry identity. -/
def PendingRequest.registry : PendingRequest → TokenId
  | .registration _ data => data.registry | .termination _ registry _ => registry
/-- key comes from public booking history. -/
def PendingRequest.key : PendingRequest → Key
  | .registration _ data => data.key | .termination _ _ key => key
/-- current actual ADA, no declared tip. -/
def PendingRequest.bid : PendingRequest → Nat
  | .registration output data => output.lovelace - data.deposit
  | .termination output _ _ => output.lovelace
/-- public role/data check, not complete-provider certification. -/
def pendingAuthentic (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) : PendingRequest → Bool
  | .registration output data => decoded decode output == some (.registration data) &&
      registrationShape .none hash code release output data
  | .termination output registry key => terminationShape .none hash code release output registry key
/-- public fold funding/output controls. -/
structure FoldFunding where
  ordinaryInput : ObservedOutput
  processorAddress : Nat
  transactionId : Nat
  interval : Interval
  fee : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- numbered outputs are actual same-tx outputs. -/
def numbered (transactionId : Nat) (outputs : List ObservedOutput) : List ObservedOutput :=
  outputs.zipIdx |>.map fun (output, index) => { output with reference := ⟨transactionId, index⟩ }
/-- request order derives holding indices and changes together. -/
def prepareChanges (hash : Hash) (code : Codec) (requests : List PendingRequest) : List Change × List ObservedOutput :=
  requests.foldl (fun (changes, holdings) request => match request with
    | .registration output data =>
      (changes ++ [.register output.reference data.key (holdings.length + 1) data.deposit],
       holdings ++ [⟨⟨0, 0⟩, data.holdingAddress.paymentCredential, data.deposit, .application data.initialDatum,
         [(activeAsset hash code data.registry data.key, 1)], data.holdingAddress.stakingCredential⟩])
    | .termination output _ key => (changes ++ [.terminate output.reference key], holdings)) ([], [])
/-- a constructive transaction, with public premise checks later. -/
def buildFold (hash : Hash) (code : Codec) (commit : TrieCommit) (release : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) : FoldObservation := Id.run do
  let (changes, holdings) := prepareChanges hash code requests
  let processorValue := (requests.map PendingRequest.bid).sum + funding.ordinaryInput.lovelace - funding.fee
  let processor : ObservedOutput := ⟨⟨0, 0⟩, funding.processorAddress, processorValue, .empty, [], none⟩
  let outputs := numbered funding.transactionId ([registry.state] ++ holdings ++ [processor])
  let state := outputs.head?.getD registry.state
  let inputs := [registry.state] ++ requests.map PendingRequest.output ++ [funding.ordinaryInput]
  let approvals := requests.map fun request =>
    let asset := match request with
      | .registration _ data => registrationAsset hash code release data
      | .termination _ registry key => terminationApproval hash code release registry key
    (asset, (-1 : Int))
  let view : SingularApplicationHeld.Assets.TxView := ⟨inputs.map (·.reference), outputs.map (fun output => ⟨output.assets⟩),
    [], [release.statePolicy, release.applicationPolicy]⟩
  let provisional : FoldObservation := ⟨registry, { registry with state }, view, inputs, outputs,
    changes, [], funding.interval, funding.fee, 0⟩
  let observation := { provisional with assets := { view with mint := expectedDelta hash code provisional ++ approvals } }
  let afterTrie := match changeBatch .none hash code release observation with
    | .ok trie => trie | .error _ => registry.trie
  let nextState := { state with datum := .root (commit afterTrie) }
  let finalOutputs := nextState :: outputs.drop 1
  let after : PublicRegistry := { registry with state := nextState, trie := afterTrie }
  let finalView : SingularApplicationHeld.Assets.TxView := { observation.assets with
    outputs := finalOutputs.map (fun output => ⟨output.assets⟩) }
  return { observation with after := after, outputs := finalOutputs, assets := finalView }
/-- explicit arithmetic equality over actual observed values. -/
def observedBalance (inputs outputs : List ObservedOutput) (fee donation : Nat) : Bool :=
  (inputs.map (·.lovelace)).sum == (outputs.map (·.lovelace)).sum + fee + donation
/-- public-input preconditions, no success judgement hidden here. -/
def PublicFoldPremises (hash : Hash) (code : Codec) (commit : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (registry : PublicRegistry) (requests : List PendingRequest)
    (funding : FoldFunding) : Prop :=
  requests ≠ [] ∧ (requests.map (·.output.reference)).Nodup ∧
  (requests.map PendingRequest.key).Nodup ∧
  recognizeState .none hash code release registry.seed registry.state = true ∧
  registry.identity = stateAsset hash code release registry.seed ∧
  registry.state.datum = .root (commit registry.trie) ∧
  funding.fee ≤ funding.ordinaryInput.lovelace ∧ funding.ordinaryInput.assets = [] ∧
  funding.ordinaryInput.credential ≠ release.applicationCredential ∧
  funding.processorAddress ≠ release.applicationCredential ∧
  (registry.state.reference :: requests.map (·.output.reference) ++ [funding.ordinaryInput.reference]).Nodup ∧
  (∀ output ∈ registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput],
    output.reference.tx ≠ funding.transactionId) ∧
  ∀ request ∈ requests, request.registry = registry.identity ∧
    pendingAuthentic hash code decode release request = true ∧
    match request with
    | .registration _ data => trieGet registry.trie data.key = .unknown ∧
        classifyPhase data funding.interval = .processing
    | .termination _ _ key => trieGet registry.trie key = .known .active

end SingularApplicationHeld
