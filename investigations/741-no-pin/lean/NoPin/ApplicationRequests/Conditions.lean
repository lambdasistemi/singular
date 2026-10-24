import NoPin.ApplicationRequests.Oracle

/-! Hypothetical #741 inversion conditions, not accepted law. These expose
all production guards without mutation or an acceptance oracle call. -/
namespace NoPin.ApplicationRequests
open Singular Lean

/-- Hypothesis under #741, not accepted law; complete recognizeState branch conditions. -/
def recognitionConditions (hash : Hash) (code : Codec)
    (release : PublishedRelease) (seed : OutRef) (output : ObservedOutput) : Bool :=
  let asset := stateAsset hash code release seed
  let entry := output.assets.head?.getD (asset, 0)
  (output.credential == release.statePolicy) &&
  (entry.1.policy == asset.policy) &&
  (entry.1.name == asset.name) &&
  (entry.2 == 1) &&
  (match output.datum with | .root _ => true | _ => false) &&
  (output.assets.length == 1)

/-- Hypothesis under #741, not accepted law; complete genesis branch conditions. -/
def genesisConditions (hash : Hash) (code : Codec) (commit : TrieCommit)
    (release : PublishedRelease) (seed : OutRef) (tx : NoPin.TxView)
    (outputs : List ObservedOutput) : Bool :=
  let asset := stateAsset hash code release seed
  let candidates := outputs.filter fun output => quantity output asset > 0
  (tx.spent.count seed == 1) &&
  (tx.invoked.contains release.statePolicy) &&
  (policyDelta tx release.statePolicy [(asset, 1)]) &&
  (candidates.length == 1 && candidates.all (fun output =>
    recognizeState .none hash code release seed output)) &&
  (candidates.all fun output => output.datum == .root (commit []))

/-- Hypothesis under #741, not accepted law; complete change branch conditions. -/
def changeConditions (hash : Hash) (code : Codec) (release : PublishedRelease)
    (trie : Trie) (action : Change) (observation : FoldObservation) : Except String Trie := do
  let some input := observation.spentOutputs.find? (fun output => output.reference == action.reference)
    | throw "missing-request-input"
  let some approval := approvalFor hash code release observation action | throw "missing-approval-preimage"
  let active := activeAsset hash code observation.before.identity action.key
  unless (observation.assets.spent.count action.reference == 1 &&
       (observation.spentOutputs.filter fun output => output.reference == action.reference).length == 1)
    do throw "request-reference"
  let supplied := input.assets.filter fun entry => entry.1.policy == release.applicationPolicy && entry.2 > 0
  let actual := supplied.head?.getD (approval, 0)
  unless (supplied.length == 1 && actual.2 == 1)
    do throw "approval-shape"
  unless (actual.1 == approval) do throw "operation-approval"
  unless (NoPin.mintQty observation.assets actual.1 == -1)
    do throw "approval-burn"
  match action with
  | .register _ key index deposit =>
    unless (trieGet trie key == .unknown) do throw "key-not-unknown"
    let some output := holdingAt observation index | throw "missing-new-holding"
    unless (quantity output active == 1 &&
         (observation.outputs.map fun output => quantity output active).sum == 1 &&
         separateHolding observation action.reference index && oneNewToken hash code observation output)
      do throw "active-placement"
    unless (NoPin.mintQty observation.assets active == 1)
      do throw "active-mint"
    unless (deposit ≤ output.lovelace)
      do throw "holding-deposit-short"
    return trieSet trie key (.known .active)
  | .terminate _ key =>
    unless (trieGet trie key == .known .active) do throw "key-not-active"
    unless (quantity input active == 1) do throw "held-active"
    unless (NoPin.mintQty observation.assets active == -1)
      do throw "active-burn"
    return trieSet trie key (.known .terminal)

/-- Hypothesis under #741, not accepted law; complete fold branch conditions. -/
def foldConditions (hash : Hash) (code : Codec) (commit : TrieCommit)
    (release : PublishedRelease) (observation : FoldObservation) : Bool :=
  let before := observation.before
  let after := observation.after
  let result := changeBatch .none hash code release observation
  let newHoldings := observation.changes.filterMap fun action => match action with
    | .register _ _ index _ => holdingAt observation index
    | .terminate .. => none
  (before.identity == stateAsset hash code release before.seed && after.identity == before.identity &&
      after.seed == before.seed) &&
  (recognizeState .none hash code release before.seed before.state &&
     before.state.datum == .root (commit before.trie) &&
     observation.assets.spent.count before.state.reference == 1 &&
     observation.spentOutputs.contains before.state) &&
  (!observation.changes.isEmpty) &&
  (decide (observation.changes.map Change.reference).Nodup) &&
  (exactPairing release observation) &&
  ((match result with | .ok trie => trie == after.trie | .error _ => false) &&
      after.state.datum == .root (commit after.trie)) &&
  ((observation.outputs.filter fun output => quantity output before.identity > 0) == [after.state] &&
     bareState after.state before.identity) &&
  (after.state.credential == before.state.credential) &&
  (before.state.lovelace ≤ after.state.lovelace) &&
  (wholePolicyDelta hash code observation) &&
  (newHoldings.all fun output => !observation.assets.spent.contains output.reference)

/-- Hypothesis under #741, not accepted law; explicit guards for each public branch. -/
def expectedWith (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query) : Bool :=
  match q.surface with
  | .recognition => recognitionConditions hash code q.release q.seed q.output
  | .genesis => genesisConditions hash code commit q.release q.seed q.transaction q.outputs
  | .registration | .termination => (changeConditions hash code q.release q.trie q.action q.observation).isOk
  | .batch => foldConditions hash code commit q.release q.observation
  | .publicFold => foldConditions hash code commit q.release
      (buildFold hash code commit q.release q.observation.before q.requests q.funding)

end NoPin.ApplicationRequests
