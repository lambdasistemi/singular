import SingularApplicationHeld.History
import SingularApplicationHeld.MintedProofs

/-! History proof helpers. -/
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
namespace SingularApplicationHeld.HistoryProofs
open Singular

theorem reference_eq (a b : OutRef) (same : (a == b) = true) : a = b := by
  cases a
  cases b
  simp_all [BEq.beq, instBEqOutRef.beq]

theorem change_key_law (h : Hash) (c : Codec) (r : PublishedRelease)
    (trie next : Trie) (action : Change) (o : FoldObservation)
    (accepted : change .none h c r trie action o = .ok next) :
    match action with
    | .register _ key _ _ => trieGet trie key = .unknown ∧
        SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c o.before.identity key) = 1
    | .terminate _ key => trieGet trie key = .known .active ∧
        SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c o.before.identity key) = -1 := by
  cases action <;> simp only []
  all_goals
    simp only [change, Proofs.applyGuard_none, bind, Except.bind, pure, Except.pure] at accepted
  all_goals repeat' first |
    (simp [throw, throwThe] at accepted; done) |
    split at accepted
  all_goals
    cases leaf : trieGet trie _ with
    | unknown => simp_all [BEq.beq, instBEqLeaf.beq, Change.key]
    | known state => cases state <;> simp_all [BEq.beq, instBEqLeaf.beq, instBEqState.beq, State.ctorIdx, Change.key]

theorem terminal_batch (h : Hash) (c : Codec) (r : PublishedRelease) (o : FoldObservation)
    (actions : List Change) (trie next : Trie) (key : Key)
    (accepted : actions.foldlM (fun trie action => change .none h c r trie action o) trie = .ok next)
    (terminal : trieGet trie key = .known .terminal) :
    key ∉ actions.map Change.key ∧ trieGet next key = .known .terminal := by
  induction actions generalizing trie with
  | nil =>
    have same : trie = next := by simpa [pure, Except.pure] using accepted
    simpa [same] using terminal
  | cons action actions ih =>
    simp only [List.foldlM_cons, bind, Except.bind] at accepted
    cases first : change .none h c r trie action o with
    | error why => simp [first] at accepted
    | ok middle =>
      simp only [first] at accepted
      have law := change_key_law h c r trie middle action o first
      have target := Proofs.change_success h c r trie middle action o first
      have different : key ≠ action.key := by
        intro same
        cases action <;> simp_all [Change.key]
      have middleTerminal : trieGet middle key = .known .terminal := by
        rw [target]
        cases action <;>
          rw [targetTrie, trieGet_set_of_ne _ _ _ _ (by simpa [Change.key] using different)] <;>
          exact terminal
      obtain ⟨outside, final⟩ := ih middle accepted middleTerminal
      exact ⟨by simpa using And.intro different outside, final⟩

theorem registry_identity (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (world : CandidateWorld) (reachable : CandidateReachable h c t r world) :
    ∀ registry ∈ world.registries,
      registry.identity = stateAsset h c r registry.seed ∧ Preimage.state registry.seed ∈ world.domain := by
  induction reachable with
  | initial => simp
  | genesis reachable seed view inputs outputs registry fee donation ledger accepted identity seedBinding
      statePresent recognized emptyTrie newRegistry registries domain ih =>
    intro candidate member
    rw [registries] at member
    rcases List.mem_append.mp member with old | added
    · obtain ⟨identity, origin⟩ := ih candidate old
      exact ⟨identity, by rw [domain]; simp [origin]⟩
    · have same : candidate = registry := by simpa using added
      subst candidate
      exact ⟨by simpa [seedBinding] using identity, by rw [domain]; simp [seedBinding]⟩
  | fold reachable o ledger present accepted registries domain ih =>
    intro candidate member
    rw [registries] at member
    obtain ⟨previous, previousMember, same⟩ := List.mem_map.mp member
    have conditions := accepted
    simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
    have identity := conditions.1.1.1.1.1.1.1.1.1.1
    have afterIdentity := Proofs.token_eq _ _ identity.1.2
    have seed := reference_eq _ _ identity.2
    by_cases hit : previous.identity == o.before.identity
    · simp only [hit, ↓reduceIte] at same
      subst candidate
      obtain ⟨beforeIdentity, origin⟩ := ih o.before present
      exact ⟨by rw [afterIdentity, seed, beforeIdentity], by rw [domain, seed]; simp [origin]⟩
    · simp only [hit, Bool.false_eq_true, ↓reduceIte] at same
      subst candidate
      obtain ⟨identity, origin⟩ := ih previous previousMember
      exact ⟨identity, by rw [domain]; simp [origin]⟩
  | neutral reachable view inputs outputs fee donation ledger noOwnMint stateUntouched registries domain ih =>
    simpa [registries, domain] using ih

theorem registry_unique (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (world : CandidateWorld) (reachable : CandidateReachable h c t r world) :
    ∀ a ∈ world.registries, ∀ b ∈ world.registries, a.identity = b.identity → a = b := by
  induction reachable with
  | initial => simp
  | genesis reachable seed view inputs outputs registry fee donation ledger accepted identity seedBinding
      statePresent recognized emptyTrie newRegistry registries domain ih =>
    intro a ha b hb same
    rw [registries] at ha hb
    simp only [List.mem_append, List.mem_singleton] at ha hb
    rcases ha with ha | ha <;> rcases hb with hb | hb
    · exact ih a ha b hb same
    · subst b; exact False.elim (newRegistry (List.mem_map.mpr ⟨a, ha, same⟩))
    · subst a; exact False.elim (newRegistry (List.mem_map.mpr ⟨b, hb, same.symm⟩))
    · exact ha.trans hb.symm
  | fold reachable o ledger present accepted registries domain ih =>
    intro a ha b hb same
    rw [registries] at ha hb
    obtain ⟨a', ha', rfl⟩ := List.mem_map.mp ha
    obtain ⟨b', hb', rfl⟩ := List.mem_map.mp hb
    have conditions := accepted
    simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
    have afterIdentity := Proofs.token_eq _ _ conditions.1.1.1.1.1.1.1.1.1.1.1.2
    have each : ∀ previous, (if previous.identity == o.before.identity then o.after else previous).identity =
        previous.identity := by
      intro previous
      split
      · rename_i hit
        exact afterIdentity.trans (Proofs.token_eq _ _ hit).symm
      · rfl
    rw [each, each] at same
    rw [ih a' ha' b' hb' same]
  | neutral reachable view inputs outputs fee donation ledger noOwnMint stateUntouched registries domain ih =>
    simpa [registries] using ih

theorem active_in_change_domain (o : FoldObservation) (action : Change) :
    Preimage.active o.before.identity action.key ∈ changePreimages o action := by
  cases action <;> simp [changePreimages, Change.key]

theorem active_in_fold_domain (before after : CandidateWorld) (o : FoldObservation)
    (domain : after.domain = before.domain ++ o.changes.flatMap (changePreimages o))
    (action : Change) (member : action ∈ o.changes) :
    Preimage.active o.before.identity action.key ∈ after.domain := by
  rw [domain]
  exact List.mem_append_right _ (List.mem_flatMap.mpr ⟨action, member, active_in_change_domain o action⟩)

theorem active_injective (h : Hash) (c : Codec) (domain : List Preimage)
    (encoding : FiniteEncoding c domain) (collision : FiniteCollisionFree h c domain)
    (a b : TokenId) (x y : Key)
    (ha : Preimage.active a x ∈ domain) (hb : Preimage.active b y ∈ domain)
    (same : activeAsset h c a x = activeAsset h c b y) : a = b ∧ x = y := by
  have names := congrArg TokenId.name same
  have preimages := encoding _ ha _ hb (collision _ ha _ hb names)
  cases preimages
  exact ⟨rfl, rfl⟩

theorem negative_entry (entries : List (TokenId × Int))
    (negative : (entries.map (·.2)).sum < 0) :
    ∃ entry ∈ entries, entry.2 < 0 := by
  induction entries with
  | nil => simp at negative
  | cons entry entries ih =>
    simp only [List.map_cons, List.sum_cons] at negative
    by_cases first : entry.2 < 0
    · exact ⟨entry, by simp, first⟩
    · obtain ⟨other, member, negative⟩ := ih (by omega)
      exact ⟨other, by simp [member], negative⟩

theorem fold_burn_action (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (before after : CandidateWorld) (o : FoldObservation)
    (domain : after.domain = before.domain ++ o.changes.flatMap (changePreimages o))
    (registry : PublicRegistry) (key : Key)
    (encoding : FiniteEncoding c (after.domain ++ [.active registry.identity key]))
    (collision : FiniteCollisionFree h c (after.domain ++ [.active registry.identity key]))
    (own : registry.identity.policy = r.statePolicy)
    (accepted : fold .none h c t r o = true)
    (burn : SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c registry.identity key) < 0) :
    registry.identity = o.before.identity ∧ ∃ reference, Change.terminate reference key ∈ o.changes := by
  have conditions := accepted
  simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
  have beforeIdentity := Proofs.token_eq _ _ conditions.1.1.1.1.1.1.1.1.1.1.1.1
  have policy : o.before.identity.policy = r.statePolicy := by rw [beforeIdentity]; rfl
  have delta := Proofs.delta_at o.assets o.before.identity.policy (expectedDelta h c o)
    conditions.1.2 (activeAsset h c registry.identity key) (by simpa [activeAsset, policy] using own)
  rw [delta] at burn
  obtain ⟨entry, member, negative⟩ := negative_entry _ burn
  obtain ⟨entryMember, same⟩ := List.mem_filter.mp member
  obtain ⟨action, actionMember, rfl⟩ := List.mem_map.mp entryMember
  have identities := active_injective h c _ encoding collision o.before.identity registry.identity
    action.key key (by exact List.mem_append_left _ (active_in_fold_domain before after o domain action actionMember))
    (by simp) (Proofs.token_eq _ _ same)
  cases action with
  | register => simp at negative
  | terminate reference actionKey =>
    simp only [Change.key] at identities
    exact ⟨identities.1.symm, reference, by simpa [identities.2] using actionMember⟩

theorem delta_zero_outside (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (before after : CandidateWorld) (o : FoldObservation)
    (domain : after.domain = before.domain ++ o.changes.flatMap (changePreimages o))
    (registry : PublicRegistry) (key : Key)
    (encoding : FiniteEncoding c (after.domain ++ [.active registry.identity key]))
    (collision : FiniteCollisionFree h c (after.domain ++ [.active registry.identity key]))
    (own : registry.identity.policy = r.statePolicy)
    (accepted : fold .none h c t r o = true)
    (outside : registry.identity = o.before.identity → key ∉ o.changes.map Change.key) :
    SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c registry.identity key) = 0 := by
  have conditions := accepted
  simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
  have beforeIdentity := Proofs.token_eq _ _ conditions.1.1.1.1.1.1.1.1.1.1.1.1
  have policy : o.before.identity.policy = r.statePolicy := by rw [beforeIdentity]; rfl
  have absent : activeAsset h c registry.identity key ∉ (expectedDelta h c o).map (·.1) := by
    intro member
    obtain ⟨entry, entryMember, same⟩ := List.mem_map.mp member
    obtain ⟨action, actionMember, rfl⟩ := List.mem_map.mp entryMember
    obtain ⟨identities, keys⟩ := active_injective h c _ encoding collision o.before.identity registry.identity
      action.key key (by exact List.mem_append_left _ (active_in_fold_domain before after o domain action actionMember))
      (by simp) same
    exact outside identities.symm (List.mem_map.mpr ⟨action, actionMember, keys⟩)
  have delta := Proofs.delta_at o.assets o.before.identity.policy (expectedDelta h c o)
    conditions.1.2 (activeAsset h c registry.identity key) (by simpa [activeAsset, policy] using own)
  simpa [Proofs.filter_absent _ _ absent] using delta

theorem terminal_after_burn (h : Hash) (c : Codec) (r : PublishedRelease) (o : FoldObservation)
    (actions : List Change) (trie next : Trie) (key : Key) (reference : OutRef)
    (member : Change.terminate reference key ∈ actions)
    (accepted : actions.foldlM (fun trie action => change .none h c r trie action o) trie = .ok next) :
    trieGet next key = .known .terminal := by
  induction actions generalizing trie with
  | nil => simp at member
  | cons action actions ih =>
    simp only [List.foldlM_cons, bind, Except.bind] at accepted
    cases first : change .none h c r trie action o with
    | error why => simp [first] at accepted
    | ok middle =>
      simp only [first] at accepted
      rcases List.mem_cons.mp member with same | later
      · subst action
        have target := Proofs.change_success h c r trie middle (.terminate reference key) o first
        have terminal : trieGet middle key = .known .terminal := by
          rw [target]; exact trieGet_set_eq _ _ _
        exact (terminal_batch h c r o actions middle next key accepted terminal).2
      · exact ih middle later accepted

theorem genesis_nonnegative (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (seed : OutRef) (view : SingularApplicationHeld.Assets.TxView) (outputs : List ObservedOutput)
    (asset : TokenId) (own : asset.policy = r.statePolicy)
    (accepted : genesis .none h c t r seed view outputs = true) :
    0 ≤ SingularApplicationHeld.Assets.mintQty view asset := by
  simp only [genesis, Proofs.applyGuard_none, Bool.and_eq_true] at accepted
  have delta := Proofs.delta_at view r.statePolicy [(stateAsset h c r seed, 1)]
    accepted.1.1.2 asset own
  rw [delta]
  simp only [List.filter_cons, List.filter_nil]
  split <;> simp

end SingularApplicationHeld.HistoryProofs
