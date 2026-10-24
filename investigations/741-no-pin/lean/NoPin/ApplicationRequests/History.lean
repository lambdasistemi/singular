import NoPin.ApplicationRequests.Client
import Singular.Statements.Batch
import Singular.Statements.Preservation

/-! Hypotheses under #741, not accepted law. These are observation/history
correspondence relations, not a second ledger evaluator. Real ledger, script
invocation, complete UTxO and trie-proof correspondence remain external debts. -/
namespace NoPin.ApplicationRequests
open Singular

/-- Hypothesis under #741, not accepted law; complete observed unspent world. -/
structure CandidateWorld where
  registries : List PublicRegistry
  unspent : List ObservedOutput
  spentReferences : List OutRef
  domain : List Preimage
  deriving BEq, DecidableEq
/-- Hypothesis under #741, not accepted law; finite actual asset support, not just mentioned keys. -/
def assetSupport (outputs : List ObservedOutput) : List TokenId :=
  outputs.flatMap fun output => output.assets.map (·.1)
/-- Hypothesis under #741, not accepted law; supply is an actual output census. -/
def totalQuantity (outputs : List ObservedOutput) (asset : TokenId) : Nat :=
  (outputs.map fun output => quantity output asset).sum
/-- Hypothesis under #741, not accepted law; checked conservation on complete finite support. -/
def tokenConserved (before after : List ObservedOutput) (view : NoPin.TxView) : Bool :=
  (assetSupport before ++ assetSupport after ++ view.mint.map (·.1)).all fun asset =>
    Int.ofNat (totalQuantity before asset) + NoPin.mintQty view asset == Int.ofNat (totalQuantity after asset)
/-- Hypothesis under #741, not accepted law; relation to the externally validated actual transaction. -/
structure LedgerObservationCorrespondence (before after : CandidateWorld) (view : NoPin.TxView)
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
/-- Hypothesis under #741, not accepted law; explicitly bound occurrence domain of one change. -/
def changePreimages (observation : FoldObservation) (action : Change) : List Preimage :=
  [.active observation.before.identity action.key] ++ match action with
  | .terminate _ key => [.terminationApproval observation.before.identity key]
  | .register _ key index deposit => match observation.outputs[index]? with
    | some output => match output.datum with
      | .application datum => [.registrationApproval observation.before.identity key output.credential datum deposit]
      | _ => []
    | _ => []
/-- Hypothesis under #741, not accepted law; all registry histories under the single shared S. -/
inductive CandidateReachable (hash : Hash) (code : Codec) (commit : TrieCommit)
    (release : PublishedRelease) : CandidateWorld → Prop where
  | initial (outputs : List ObservedOutput)
      (unique : (outputs.map (·.reference)).Nodup)
      (noOwnAssets : ∀ output ∈ outputs, ∀ asset ∈ assetSupport [output], asset.policy ≠ release.statePolicy) :
      CandidateReachable hash code commit release ⟨[], outputs, [], []⟩
  | genesis {before after : CandidateWorld} (reachable : CandidateReachable hash code commit release before)
      (seed : OutRef) (view : NoPin.TxView) (inputs outputs : List ObservedOutput)
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
      (view : NoPin.TxView) (inputs outputs : List ObservedOutput) (fee donation : Nat)
      (ledger : LedgerObservationCorrespondence before after view inputs outputs fee donation)
      (noOwnMint : policyDelta view release.statePolicy [] = true)
      (stateUntouched : ∀ registry ∈ before.registries, registry.state.reference ∉ view.spent)
      (registries : after.registries = before.registries)
      (domain : after.domain = before.domain) :
      CandidateReachable hash code commit release after
/-- Hypothesis under #741, not accepted law; A history is separate from S history. -/
inductive ApplicationReachable (hash : Hash) (code : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) : List ObservedOutput → Prop where
  | initial (outputs : List ObservedOutput)
      (ordinary : ∀ output ∈ outputs, output.credential ≠ release.applicationCredential ∧
        ∀ asset ∈ assetSupport [output], asset.policy ≠ release.applicationPolicy) :
      ApplicationReachable hash code decode release outputs
  | next {before after : CandidateWorld}
      (reachable : ApplicationReachable hash code decode release before.unspent)
      (observation : ApplicationObservation)
      (ledger : LedgerObservationCorrespondence before after observation.assets observation.inputs
        observation.outputs observation.fee observation.donation)
      (accepted : applicationStep .none hash code decode release observation = true) :
      ApplicationReachable hash code decode release after.unspent
/-- Hypothesis under #741, not accepted law; accepted logical history, no economics or burn-coupling shortcut. -/
structure AcceptedProjection (candidate : PublicRegistry) where
  state : RegistryState
  reachable : Singular.Reachable state
  trie : state.trie = candidate.trie
/-- Hypothesis under #741, not accepted law; accepted permanent law reused by its actual constant. -/
abbrev acceptedTermination := @Singular.Statements.termination
/-- Hypothesis under #741, not accepted law; accepted batch burn law reused by its actual constant. -/
abbrev acceptedBatchBurnsOnlyLiveHoldings := @Singular.Statements.batch_burns_only_live_holdings
/-- Hypothesis under #741, not accepted law; honest standalone physical monetary net bound. -/
def processorNetBound (inputs outputs : List ObservedOutput) (processor : Nat)
    (requestBid ordinaryInput stateBefore stateAfter holdingDeposit fee donation : Nat) : Prop :=
  observedBalance inputs outputs fee donation = true ∧
  (inputs.map (·.lovelace)).sum = stateBefore + requestBid + holdingDeposit + ordinaryInput ∧
  stateBefore ≤ stateAfter ∧
  stateAfter + holdingDeposit + paidTo outputs processor ≤ (outputs.map (·.lovelace)).sum

end NoPin.ApplicationRequests
