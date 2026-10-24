import SingularApplicationHeld.History

/-! History statements for the application-held model. A finite
domain includes the queried active-role preimage as well as every occurrence
retained by the history. No cryptographic or ledger implementation is supplied.
The original CandidateReachable relation remains the authority for these
statements; neutral application transactions are included. -/
namespace SingularApplicationHeld
open Singular

/-- the queried role is not omitted. -/
def historyDomain (world : CandidateWorld) (registry : PublicRegistry) (key : Key) : List Preimage :=
  world.domain ++ [.active registry.identity key]

/-- independent serialization and hash premises. -/
def HistoryPremises (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (world : CandidateWorld) (registry : PublicRegistry) (key : Key) : Prop :=
  CandidateReachable h c t release world ∧ registry ∈ world.registries ∧
  FiniteEncoding c (historyDomain world registry key) ∧
  FiniteCollisionFree h c (historyDomain world registry key)

/-- actual observed census, including pending tokens. -/
def SupplyAt (h : Hash) (c : Codec) (world : CandidateWorld)
    (registry : PublicRegistry) (key : Key) : Prop :=
  liveActiveCount h c registry.identity key world.unspent =
    if trieGet registry.trie key = .known .active then 1 else 0

/-- the exact next physical fold and its history. -/
structure HistoryFoldPremises (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (before after : CandidateWorld) (o : FoldObservation) : Prop where
  reachable : CandidateReachable h c t release before
  ledger : LedgerObservationCorrespondence before after o.assets o.spentOutputs o.outputs o.fee o.donation
  present : o.before ∈ before.registries
  accepted : fold .none h c t release o = true
  registries : after.registries = before.registries.map fun registry =>
    if registry.identity == o.before.identity then o.after else registry
  domain : after.domain = before.domain ++ o.changes.flatMap (changePreimages o)

/-- every transaction constructor,
including the two paths that do not fold. The option records the actual fold,
and is none for a genesis or an application-only transaction. -/
def HistoryTransaction (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (before after : CandidateWorld) (view : SingularApplicationHeld.Assets.TxView) (folded : Option FoldObservation) : Prop :=
  CandidateReachable h c t release before ∧
  match folded with
  | some o => view = o.assets ∧ HistoryFoldPremises h c t release before after o
  | none =>
    (∃ seed inputs outputs registry fee donation,
      LedgerObservationCorrespondence before after view inputs outputs fee donation ∧
      genesis .none h c t release seed view outputs = true ∧
      registry.identity = stateAsset h c release seed ∧ registry.seed = seed ∧
      registry.state ∈ outputs ∧ recognizeState .none h c release seed registry.state = true ∧
      registry.trie = [] ∧ registry.identity ∉ before.registries.map (·.identity) ∧
      after.registries = before.registries ++ [registry] ∧ after.domain = before.domain ++ [.state seed]) ∨
    (∃ inputs outputs fee donation,
      LedgerObservationCorrespondence before after view inputs outputs fee donation ∧
      policyDelta view release.statePolicy [] = true ∧
      (∀ registry ∈ before.registries, registry.state.reference ∉ view.spent) ∧
      after.registries = before.registries ∧ after.domain = before.domain)

namespace HistoryStatements

/-- History statement; proof pending independent statement review.
For every reachable registry and every logical key, the actual live supply is
one exactly for an active leaf and zero for every other leaf. -/
theorem supply_in_step (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (world : CandidateWorld) (registry : PublicRegistry) (key : Key)
    (_premises : HistoryPremises h c t release world registry key) :
    SupplyAt h c world registry key := by sorry

/-- History statement; proof pending independent statement review.
Every reachable registry/key has at most one token in the complete unspent set.
This quantifies the full policy/name identity, never the seed-derived name alone. -/
theorem one_live_token (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (world : CandidateWorld) (registry : PublicRegistry) (key : Key)
    (_premises : HistoryPremises h c t release world registry key) :
    liveActiveCount h c registry.identity key world.unspent ≤ 1 := by sorry

/-- History statement; proof pending independent statement review.
Any burn in an accepted fold from a reachable world belongs to that registry
and a termination of that logical key, whose final leaf is terminal. -/
theorem burn_only_terminating_fold (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (before after : CandidateWorld) (view : SingularApplicationHeld.Assets.TxView)
    (folded : Option FoldObservation)
    (registry : PublicRegistry) (key : Key)
    (_premises : HistoryTransaction h c t release before after view folded ∧
      HistoryPremises h c t release before registry key ∧
      FiniteEncoding c (after.domain ++ [.active registry.identity key]) ∧
      FiniteCollisionFree h c (after.domain ++ [.active registry.identity key]) ∧
      SingularApplicationHeld.Assets.mintQty view (activeAsset h c registry.identity key) < 0) :
    ∃ o, folded = some o ∧ registry.identity = o.before.identity ∧
    (∃ reference, Change.terminate reference key ∈ o.changes) ∧
    trieGet o.after.trie key = .known .terminal := by sorry

/-- History statement; proof pending independent statement review.
An accepted fold cannot mint a terminal key again, including in another registry's fold.
The original history relation supplies the premise; no separate projection is assumed. -/
theorem no_remint_after_terminal (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (before after : CandidateWorld) (o : FoldObservation)
    (registry : PublicRegistry) (key : Key)
    (_premises : HistoryFoldPremises h c t release before after o ∧
      HistoryPremises h c t release before registry key ∧
      FiniteEncoding c (after.domain ++ [.active registry.identity key]) ∧
      FiniteCollisionFree h c (after.domain ++ [.active registry.identity key]) ∧
      trieGet registry.trie key = .known .terminal) :
    SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c registry.identity key) ≤ 0 ∧
      ∀ successor ∈ after.registries, successor.identity = registry.identity →
        trieGet successor.trie key = .known .terminal := by sorry

end HistoryStatements
end SingularApplicationHeld
