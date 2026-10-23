import NoPin.ApplicationRequests.Application

/-! Hypotheses under #741, not accepted law. All client inputs are published
constants or public chain data, including operation preimages from public
booking history. No reversal of a hash or per-client blueprint application. -/
namespace NoPin.ApplicationRequests
open Singular Lean

/-- Hypothesis under #741, not accepted law; exact same-output request descriptors. -/
inductive PendingRequest where
  | registration (output : ObservedOutput) (data : RegistrationData)
  | termination (output : ObservedOutput) (registry : TokenId) (key : Key)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; actual request source. -/
def PendingRequest.output : PendingRequest → ObservedOutput
  | .registration output _ | .termination output _ _ => output
/-- Hypothesis under #741, not accepted law; complete registry identity. -/
def PendingRequest.registry : PendingRequest → TokenId
  | .registration _ data => data.registry | .termination _ registry _ => registry
/-- Hypothesis under #741, not accepted law; key comes from public booking history. -/
def PendingRequest.key : PendingRequest → Key
  | .registration _ data => data.key | .termination _ _ key => key
/-- Hypothesis under #741, not accepted law; current actual ADA, no declared tip. -/
def PendingRequest.bid : PendingRequest → Nat
  | .registration output data => output.lovelace - data.deposit
  | .termination output _ _ => output.lovelace
/-- Hypothesis under #741, not accepted law; public role/data check, not complete-provider certification. -/
def pendingAuthentic (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) : PendingRequest → Bool
  | .registration output data => decoded decode output == some (.registration data) &&
      registrationShape .none hash code release output data
  | .termination output registry key => terminationShape .none hash code release output registry key
/-- Hypothesis under #741, not accepted law; hints are public preimages, never a hidden file. -/
def discover (hash : Hash) (code : Codec) (decode : DecodeApplication) (release : PublishedRelease)
    (registry : TokenId) (publicKeyPreimages : List Key) (outputs : List ObservedOutput) : List PendingRequest :=
  outputs.flatMap fun output =>
    let registrations := match decoded decode output with
      | some (.registration data) => [PendingRequest.registration output data]
      | _ => []
    let terminations := publicKeyPreimages.map (PendingRequest.termination output registry)
    (registrations ++ terminations).filter fun request =>
      request.registry == registry && pendingAuthentic hash code decode release request
/-- Hypothesis under #741, not accepted law; public derivations have no script-application argument. -/
inductive ClientAction where
  | create | register | terminate | fold | ownerReclaim | expiredCleanup | update
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; mechanically ranked derivation nodes. -/
structure Derivation where
  label : String
  rank : Nat
  dependencies : List Nat
  result : TokenId
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; hashes consume release/public inputs only. -/
def identitiesFor (hash : Hash) (code : Codec) (release : PublishedRelease) (seed : OutRef)
    (key address datum deposit : Nat) (action : ClientAction) : List Derivation :=
  let registry := stateAsset hash code release seed
  let state := Derivation.mk "published-state-policy-and-seed-hash" 0 [] registry
  let active := Derivation.mk "active-role" 1 [0] (activeAsset hash code registry key)
  let configuration := Derivation.mk "immutable-application-configuration" 1 [0]
    (configurationAsset hash code release registry)
  let registration := Derivation.mk "registration-approval-with-deposit" 2 [0, 1]
    (registrationApproval hash code release registry key address datum deposit)
  let termination := Derivation.mk "termination-approval" 2 [0, 1]
    (terminationApproval hash code release registry key)
  match action with
  | .create => [state, configuration]
  | .register | .ownerReclaim | .expiredCleanup => [state, configuration, registration]
  | .terminate => [state, active, termination]
  | .fold => [state, active, configuration, registration, termination]
  | .update => [state, active]
/-- Hypothesis under #741, not accepted law; dependency ranks evaluated, not typed success. -/
def dependencies (nodes : List Derivation) : Bool :=
  nodes.all fun node => node.dependencies.all fun rank => rank < node.rank
/-- Hypothesis under #741, not accepted law; public fold funding/output controls. -/
structure FoldFunding where
  ordinaryInput : ObservedOutput
  processorAddress : Nat
  transactionId : Nat
  interval : Interval
  fee : Nat
  deriving BEq, DecidableEq
/-- Hypothesis under #741, not accepted law; numbered outputs are actual same-tx outputs. -/
def numbered (transactionId : Nat) (outputs : List ObservedOutput) : List ObservedOutput :=
  outputs.zipIdx |>.map fun (output, index) => { output with reference := ⟨transactionId, index⟩ }
/-- Hypothesis under #741, not accepted law; request order derives holding indices and changes together. -/
def prepareChanges (hash : Hash) (code : Codec) (requests : List PendingRequest) : List Change × List ObservedOutput :=
  requests.foldl (fun (changes, holdings) request => match request with
    | .registration output data =>
      (changes ++ [.register output.reference data.key (holdings.length + 1) data.deposit],
       holdings ++ [⟨⟨0, 0⟩, data.holdingAddress, data.deposit, .application data.initialDatum,
         [(activeAsset hash code data.registry data.key, 1)]⟩])
    | .termination output _ key => (changes ++ [.terminate output.reference key], holdings)) ([], [])
/-- Hypothesis under #741, not accepted law; a constructive transaction, with public premise checks later. -/
def buildFold (hash : Hash) (code : Codec) (commit : TrieCommit) (release : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) : FoldObservation := Id.run do
  let (changes, holdings) := prepareChanges hash code requests
  let processorValue := (requests.map PendingRequest.bid).sum + funding.ordinaryInput.lovelace - funding.fee
  let processor : ObservedOutput := ⟨⟨0, 0⟩, funding.processorAddress, processorValue, .empty, []⟩
  let outputs := numbered funding.transactionId ([registry.state] ++ holdings ++ [processor])
  let state := outputs.head?.getD registry.state
  let inputs := [registry.state] ++ requests.map PendingRequest.output ++ [funding.ordinaryInput]
  let approvals := requests.map fun request =>
    let asset := match request with
      | .registration _ data => registrationAsset hash code release data
      | .termination _ registry key => terminationApproval hash code release registry key
    (asset, (-1 : Int))
  let view : NoPin.TxView := ⟨inputs.map (·.reference), outputs.map (fun output => ⟨output.assets⟩),
    [], [release.statePolicy, release.applicationPolicy]⟩
  let provisional : FoldObservation := ⟨registry, { registry with state }, view, inputs, outputs,
    changes, [], funding.interval, funding.fee, 0⟩
  let observation := { provisional with assets := { view with mint := expectedDelta hash code provisional ++ approvals } }
  let afterTrie := match changeBatch .none hash code release observation with
    | .ok trie => trie | .error _ => registry.trie
  let nextState := { state with datum := .root (commit afterTrie) }
  let finalOutputs := nextState :: outputs.drop 1
  let after : PublicRegistry := { registry with state := nextState, trie := afterTrie }
  let finalView : NoPin.TxView := { observation.assets with
    outputs := finalOutputs.map (fun output => ⟨output.assets⟩) }
  return { observation with after := after, outputs := finalOutputs, assets := finalView }
/-- Hypothesis under #741, not accepted law; project transaction fields, never trie fields, into A. -/
def applicationFoldView (observation : FoldObservation) (requests : List PendingRequest) : ApplicationObservation :=
  let (actions, _) := requests.foldl (fun (actions, index) request => match request with
    | .registration output _ => (actions ++ [ApplicationAction.registrationFold output.reference index], index + 1)
    | .termination output registry key => (actions ++ [.terminationFold output.reference registry key], index)) ([], 1)
  ⟨observation.assets, observation.spentOutputs, observation.outputs, [], [], observation.signers,
    observation.interval, observation.fee, observation.donation, actions⟩
/-- Hypothesis under #741, not accepted law; explicit arithmetic equality over actual observed values. -/
def observedBalance (inputs outputs : List ObservedOutput) (fee donation : Nat) : Bool :=
  (inputs.map (·.lovelace)).sum == (outputs.map (·.lovelace)).sum + fee + donation
/-- Hypothesis under #741, not accepted law; public-input preconditions, no success judgement hidden here. -/
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

end NoPin.ApplicationRequests
