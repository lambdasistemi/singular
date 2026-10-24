import NoPin.ApplicationRequests.HistoryProofs

/-! Hypothetical history statements under #741, not accepted law. A finite
domain includes the queried active-role preimage as well as every occurrence
retained by the history. No cryptographic or ledger implementation is supplied.
The original CandidateReachable relation remains the authority for these
statements; neutral application transactions are included. -/
namespace NoPin.ApplicationRequests
open Singular

/-- Hypothesis under #741, not accepted law; the queried role is not omitted. -/
def historyDomain (world : CandidateWorld) (registry : PublicRegistry) (key : Key) : List Preimage :=
  world.domain ++ [.active registry.identity key]

/-- Hypothesis under #741, not accepted law; independent serialization and hash premises. -/
def HistoryPremises (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (world : CandidateWorld) (registry : PublicRegistry) (key : Key) : Prop :=
  CandidateReachable h c t release world ∧ registry ∈ world.registries ∧
  FiniteEncoding c (historyDomain world registry key) ∧
  FiniteCollisionFree h c (historyDomain world registry key)

/-- Hypothesis under #741, not accepted law; actual observed census, including pending tokens. -/
def SupplyAt (h : Hash) (c : Codec) (world : CandidateWorld)
    (registry : PublicRegistry) (key : Key) : Prop :=
  liveActiveCount h c registry.identity key world.unspent =
    if trieGet registry.trie key = .known .active then 1 else 0

/-- Hypothesis under #741, not accepted law; the exact next physical fold and its history. -/
structure HistoryFoldPremises (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (before after : CandidateWorld) (o : FoldObservation) : Prop where
  reachable : CandidateReachable h c t release before
  ledger : LedgerObservationCorrespondence before after o.assets o.spentOutputs o.outputs o.fee o.donation
  present : o.before ∈ before.registries
  accepted : fold .none h c t release o = true
  registries : after.registries = before.registries.map fun registry =>
    if registry.identity == o.before.identity then o.after else registry
  domain : after.domain = before.domain ++ o.changes.flatMap (changePreimages o)

/-- Hypothesis under #741, not accepted law; every transaction constructor,
including the two paths that do not fold. The option records the actual fold,
and is none for a genesis or an application-only transaction. -/
def HistoryTransaction (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (before after : CandidateWorld) (view : NoPin.TxView) (folded : Option FoldObservation) : Prop :=
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

/-- Hypothesis under #741, not accepted law. Status: STATED.
For every reachable registry and every logical key, the actual live supply is
one exactly for an active leaf and zero for every other leaf. -/
theorem supply_in_step (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (world : CandidateWorld) (registry : PublicRegistry) (key : Key)
    (_premises : HistoryPremises h c t release world registry key) :
    SupplyAt h c world registry key := by sorry

/-- Hypothesis under #741, not accepted law. Status: STATED.
Every reachable registry/key has at most one token in the complete unspent set.
This quantifies the full policy/name identity, never the seed-derived name alone. -/
theorem one_live_token (h : Hash) (c : Codec) (t : TrieCommit) (release : PublishedRelease)
    (world : CandidateWorld) (registry : PublicRegistry) (key : Key)
    (_premises : HistoryPremises h c t release world registry key) :
    liveActiveCount h c registry.identity key world.unspent ≤ 1 := by sorry

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Any burn in an accepted fold from a reachable world belongs to that registry
and a termination of that logical key, whose final leaf is terminal. -/
theorem burn_only_terminating_fold (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (before after : CandidateWorld) (view : NoPin.TxView)
    (folded : Option FoldObservation)
    (registry : PublicRegistry) (key : Key)
    (_premises : HistoryTransaction h c t release before after view folded ∧
      HistoryPremises h c t release before registry key ∧
      FiniteEncoding c (after.domain ++ [.active registry.identity key]) ∧
      FiniteCollisionFree h c (after.domain ++ [.active registry.identity key]) ∧
      NoPin.mintQty view (activeAsset h c registry.identity key) < 0) :
    ∃ o, folded = some o ∧ registry.identity = o.before.identity ∧
    (∃ reference, Change.terminate reference key ∈ o.changes) ∧
    trieGet o.after.trie key = .known .terminal := by
  rcases _premises with ⟨transaction, history, encoding, collision, burn⟩
  rcases history with ⟨reachable, member, _, _⟩
  have own : registry.identity.policy = release.statePolicy := by
    rw [(HistoryProofs.registry_identity h c t release before reachable registry member).1]
    rfl
  rcases transaction with ⟨_, transaction⟩
  cases folded with
  | none =>
    rcases transaction with created | neutral
    · rcases created with ⟨seed, inputs, outputs, created, fee, donation, ledger, accepted, _⟩
      have nonnegative := HistoryProofs.genesis_nonnegative h c t release seed view outputs
        (activeAsset h c registry.identity key) own accepted
      omega
    · rcases neutral with ⟨inputs, outputs, fee, donation, ledger, noMint, _⟩
      have zero := Proofs.delta_at view release.statePolicy [] noMint
        (activeAsset h c registry.identity key) own
      simp only [List.filter_nil, List.map_nil, List.sum_nil] at zero
      omega
  | some o =>
    rcases transaction with ⟨rfl, premises⟩
    obtain ⟨same, reference, action⟩ := HistoryProofs.fold_burn_action h c t release before after o
      premises.domain registry key encoding collision own premises.accepted burn
    refine ⟨o, rfl, same, ⟨reference, action⟩, ?_⟩
    exact HistoryProofs.terminal_after_burn h c release o o.changes o.before.trie o.after.trie
      key reference action (Proofs.fold_result h c t release o premises.accepted).1

/-- Hypothesis under #741, not accepted law. Status: PROVED.
An accepted fold cannot mint a terminal key again, including in another registry's fold.
Accepted permanent-key constants remain available through acceptedTermination and
acceptedBatchBurnsOnlyLiveHoldings; no unproved projection is assumed here. -/
theorem no_remint_after_terminal (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (before after : CandidateWorld) (o : FoldObservation)
    (registry : PublicRegistry) (key : Key)
    (_premises : HistoryFoldPremises h c t release before after o ∧
      HistoryPremises h c t release before registry key ∧
      FiniteEncoding c (after.domain ++ [.active registry.identity key]) ∧
      FiniteCollisionFree h c (after.domain ++ [.active registry.identity key]) ∧
      trieGet registry.trie key = .known .terminal) :
    NoPin.mintQty o.assets (activeAsset h c registry.identity key) ≤ 0 ∧
      ∀ successor ∈ after.registries, successor.identity = registry.identity →
        trieGet successor.trie key = .known .terminal := by
  rcases _premises with ⟨premises, history, encoding, collision, terminal⟩
  rcases history with ⟨reachable, member, _, _⟩
  have own : registry.identity.policy = release.statePolicy := by
    rw [(HistoryProofs.registry_identity h c t release before reachable registry member).1]
    rfl
  have outside : registry.identity = o.before.identity → key ∉ o.changes.map Change.key := by
    intro same
    have equal := HistoryProofs.registry_unique h c t release before reachable registry member
      o.before premises.present same
    exact (HistoryProofs.terminal_batch h c release o o.changes o.before.trie o.after.trie key
      (Proofs.fold_result h c t release o premises.accepted).1 (by simpa [equal] using terminal)).1
  have zero := HistoryProofs.delta_zero_outside h c t release before after o premises.domain
    registry key encoding collision own premises.accepted outside
  refine ⟨by omega, ?_⟩
  intro successor successorMember sameIdentity
  rw [premises.registries] at successorMember
  obtain ⟨previous, previousMember, same⟩ := List.mem_map.mp successorMember
  have conditions := premises.accepted
  simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
  have afterIdentity := Proofs.token_eq _ _ conditions.1.1.1.1.1.1.1.1.1.1.1.2
  by_cases hit : previous.identity == o.before.identity
  · simp only [hit, ↓reduceIte] at same
    subst successor
    have equal := HistoryProofs.registry_unique h c t release before reachable registry member
      o.before premises.present (sameIdentity.symm.trans afterIdentity)
    exact (HistoryProofs.terminal_batch h c release o o.changes o.before.trie o.after.trie key
      (Proofs.fold_result h c t release o premises.accepted).1 (by simpa [equal] using terminal)).2
  · simp only [hit, Bool.false_eq_true, ↓reduceIte] at same
    subst successor
    have equal := HistoryProofs.registry_unique h c t release before reachable previous previousMember
      registry member sameIdentity
    simpa [equal] using terminal

end HistoryStatements
end NoPin.ApplicationRequests
