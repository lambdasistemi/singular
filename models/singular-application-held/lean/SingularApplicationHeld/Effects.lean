import SingularApplicationHeld.Role

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/
namespace SingularApplicationHeld
open Singular Lean

/-- literal successor leaf by operation. -/
def targetTrie (trie : Trie) (action : Change) : Trie :=
  match action with
  | .register _ key _ _ => trieSet trie key (.known .active)
  | .terminate _ key => trieSet trie key (.known .terminal)
/-- independently ordered batch effects. -/
def targetBatch (o : FoldObservation) : Trie := o.changes.foldl targetTrie o.before.trie
/-- literal successor trie and its commitment. -/
abbrev batchEffects (commit : TrieCommit) (o : FoldObservation) : Prop :=
  o.after.trie = targetBatch o ∧ o.after.state.datum = .root (commit (targetBatch o))
/-- each registration has its own deposit-bearing output. -/
def holdingDelivery (hash : Hash) (code : Codec) (o : FoldObservation) : Bool :=
  o.changes.all fun action => match action with
  | .register ref key index deposit => match o.outputs[index]? with
    | some output => separateHolding o ref index && oneNewToken hash code o output &&
        quantity output (activeAsset hash code o.before.identity key) == 1 && deposit ≤ output.lovelace
    | none => false
  | .terminate .. => true
/-- every active role occurring in this fold. -/
def foldRoleDomain (o : FoldObservation) : List Preimage :=
  .state o.before.seed :: o.changes.map (fun action => .active o.before.identity action.key)
/-- encoding, collision freedom and actual fold admission. -/
def MintedOutputsPremises (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  FiniteEncoding c (foldRoleDomain q.observation) ∧
  FiniteCollisionFree h c (foldRoleDomain q.observation) ∧
  fold m h c t q.release q.observation = true
/-- actual minted own-policy assets in actual fold outputs. -/
def MintedOutputsConclusion (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  fold m h c t q.release q.observation = true ∧
  ∀ output ∈ q.observation.outputs, ∀ entry ∈ output.assets,
    entry.1.policy = q.release.statePolicy → entry.2 > 0 →
    SingularApplicationHeld.Assets.mintQty q.observation.assets entry.1 > 0 →
    recognizeState .none h c q.release q.observation.before.seed output = false

/-- the untouched-key frame over all keys. -/
def FoldFrame (o : FoldObservation) : Prop :=
  ∀ key, key ∉ o.changes.map Change.key → trieGet o.after.trie key = trieGet o.before.trie key

end SingularApplicationHeld
