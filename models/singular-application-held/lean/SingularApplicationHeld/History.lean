import SingularApplicationHeld.Client

/-! These are observation/history
correspondence relations, not a second ledger evaluator. Real ledger, script
invocation, complete UTxO and trie-proof correspondence remain external debts. -/
namespace SingularApplicationHeld
open Singular

/-- Count the complete active asset identity across all unspent outputs. -/
def liveActiveCount (hash : Hash) (code : Codec) (registry : TokenId) (key : Key)
    (unspent : List ObservedOutput) : Nat :=
  (unspent.map fun output => quantity output (activeAsset hash code registry key)).sum

/-- Complete observed unspent world. -/
structure CandidateWorld where
  registries : List PublicRegistry
  unspent : List ObservedOutput
  spentReferences : List OutRef
  domain : List Preimage
  deriving BEq, DecidableEq
/-- finite actual asset support, not just mentioned keys. -/
def assetSupport (outputs : List ObservedOutput) : List TokenId :=
  outputs.flatMap fun output => output.assets.map (·.1)
/-- supply is an actual output census. -/
def totalQuantity (outputs : List ObservedOutput) (asset : TokenId) : Nat :=
  (outputs.map fun output => quantity output asset).sum
/-- checked conservation on complete finite support. -/
def tokenConserved (before after : List ObservedOutput) (view : SingularApplicationHeld.Assets.TxView) : Bool :=
  (assetSupport before ++ assetSupport after ++ view.mint.map (·.1)).all fun asset =>
    Int.ofNat (totalQuantity before asset) + SingularApplicationHeld.Assets.mintQty view asset == Int.ofNat (totalQuantity after asset)
/-- relation to the externally validated actual transaction. -/
structure LedgerObservationCorrespondence (before after : CandidateWorld) (view : SingularApplicationHeld.Assets.TxView)
    (inputs outputs : List ObservedOutput) (fee donation : Nat) : Prop where
  spending : view.spent = inputs.map (·.reference)
  outputAssets : view.outputs = outputs.map (fun output => ⟨output.assets⟩)
  inputsPresent : ∀ input ∈ inputs, input ∈ before.unspent
  uniqueInputs : (inputs.map (·.reference)).Nodup
  completeBefore : (before.unspent.map (·.reference)).Nodup
  completeAfter : (after.unspent.map (·.reference)).Nodup
  nextUnspent : after.unspent =
    before.unspent.filter (fun output => !view.spent.contains output.reference) ++ outputs
  spentHistory : after.spentReferences = before.spentReferences ++ view.spent
  neverRespent : after.spentReferences.Nodup
  freshOutputs : ∀ output ∈ outputs, output.reference ∉ before.spentReferences ++ view.spent ++ before.unspent.map (·.reference)
  assetsConserved : tokenConserved before.unspent after.unspent view = true
  valueConserved : observedBalance inputs outputs fee donation = true
/-- explicitly bound occurrence domain of one change. -/
def changePreimages (observation : FoldObservation) (action : Change) : List Preimage :=
  [.active observation.before.identity action.key] ++ match action with
  | .terminate _ key => [.terminationApproval observation.before.identity key]
  | .register _ key index deposit => match observation.outputs[index]? with
    | some output => match output.datum with
      | .application datum => [.registrationApproval observation.before.identity key output.credential datum deposit]
      | _ => []
    | _ => []
/-- all registry histories under the single shared S. -/
inductive CandidateReachable (hash : Hash) (code : Codec) (commit : TrieCommit)
    (release : PublishedRelease) : CandidateWorld → Prop where
  | initial (outputs : List ObservedOutput)
      (unique : (outputs.map (·.reference)).Nodup)
      (noOwnAssets : ∀ output ∈ outputs, ∀ asset ∈ assetSupport [output], asset.policy ≠ release.statePolicy) :
      CandidateReachable hash code commit release ⟨[], outputs, [], []⟩
  | genesis {before after : CandidateWorld} (reachable : CandidateReachable hash code commit release before)
      (seed : OutRef) (view : SingularApplicationHeld.Assets.TxView) (inputs outputs : List ObservedOutput)
      (registry : PublicRegistry) (fee donation : Nat)
      (ledger : LedgerObservationCorrespondence before after view inputs outputs fee donation)
      (accepted : genesis .none hash code commit release seed view outputs = true)
      (identity : registry.identity = stateAsset hash code release seed)
      (seedBinding : registry.seed = seed)
      (statePresent : registry.state ∈ outputs)
      (recognized : recognizeState .none hash code release seed registry.state = true)
      (emptyTrie : registry.trie = [])
      (newRegistry : registry.identity ∉ before.registries.map (·.identity))
      (registries : after.registries = before.registries ++ [registry])
      (domain : after.domain = before.domain ++ [.state seed]) :
      CandidateReachable hash code commit release after
  | fold {before after : CandidateWorld} (reachable : CandidateReachable hash code commit release before)
      (observation : FoldObservation)
      (ledger : LedgerObservationCorrespondence before after observation.assets observation.spentOutputs
        observation.outputs observation.fee observation.donation)
      (present : observation.before ∈ before.registries)
      (accepted : fold .none hash code commit release observation = true)
      (registries : after.registries = before.registries.map fun registry =>
        if registry.identity == observation.before.identity then observation.after else registry)
      (domain : after.domain = before.domain ++ observation.changes.flatMap (changePreimages observation)) :
      CandidateReachable hash code commit release after
  | neutral {before after : CandidateWorld} (reachable : CandidateReachable hash code commit release before)
      (view : SingularApplicationHeld.Assets.TxView) (inputs outputs : List ObservedOutput) (fee donation : Nat)
      (ledger : LedgerObservationCorrespondence before after view inputs outputs fee donation)
      (noOwnMint : policyDelta view release.statePolicy [] = true)
      (stateUntouched : ∀ registry ∈ before.registries, registry.state.reference ∉ view.spent)
      (registries : after.registries = before.registries)
      (domain : after.domain = before.domain) :
      CandidateReachable hash code commit release after

end SingularApplicationHeld
