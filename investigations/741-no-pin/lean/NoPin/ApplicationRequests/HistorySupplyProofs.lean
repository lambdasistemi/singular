import NoPin.ApplicationRequests.HistoryProofs

/-! Hypothetical history supply proof helpers, not accepted law. -/
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
namespace NoPin.ApplicationRequests.HistoryProofs
open Singular

theorem quantity_absent (output : ObservedOutput) (asset : TokenId)
    (absent : asset ∉ output.assets.map (·.1)) : quantity output asset = 0 := by
  have empty : output.assets.filter (fun entry => entry.1 == asset) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro entry member same
    exact absent (List.mem_map.mpr ⟨entry, member, Proofs.token_eq _ _ same⟩)
  simp [quantity, empty]

theorem total_absent (outputs : List ObservedOutput) (asset : TokenId)
    (absent : asset ∉ assetSupport outputs) : totalQuantity outputs asset = 0 := by
  induction outputs with
  | nil => rfl
  | cons output outputs ih =>
    change asset ∉ output.assets.map (·.1) ++ assetSupport outputs at absent
    have headAbsent : asset ∉ output.assets.map (·.1) := by
      intro member; exact absent (List.mem_append_left _ member)
    have tailAbsent : asset ∉ assetSupport outputs := by
      intro member; exact absent (List.mem_append_right _ member)
    change quantity output asset + totalQuantity outputs asset = 0
    rw [quantity_absent _ _ headAbsent, ih tailAbsent]

theorem conserved_at (before after : List ObservedOutput) (view : NoPin.TxView)
    (conserved : tokenConserved before after view = true) (asset : TokenId) :
    Int.ofNat (totalQuantity before asset) + NoPin.mintQty view asset =
      Int.ofNat (totalQuantity after asset) := by
  by_cases present : asset ∈ assetSupport before ++ assetSupport after ++ view.mint.map (·.1)
  · have law := List.all_eq_true.mp conserved asset present
    simpa using law
  · have beforeAbsent : asset ∉ assetSupport before := by
      intro member; exact present (by simp [member])
    have afterAbsent : asset ∉ assetSupport after := by
      intro member; exact present (by simp [member])
    have mintAbsent : asset ∉ view.mint.map (·.1) := by
      intro member; exact present (by simp [member])
    simp [total_absent _ _ beforeAbsent, total_absent _ _ afterAbsent,
      NoPin.mintQty, Proofs.filter_absent _ _ mintAbsent]

def activeIndicator (trie : Trie) (key : Key) : Int :=
  if trieGet trie key = .known .active then 1 else 0

def actionDelta (action : Change) : Int :=
  match action with | .register .. => 1 | .terminate .. => -1

theorem change_indicator (h : Hash) (c : Codec) (r : PublishedRelease)
    (trie next : Trie) (action : Change) (o : FoldObservation) (key : Key)
    (accepted : change .none h c r trie action o = .ok next) :
    (if action.key = key then actionDelta action else 0) =
      activeIndicator next key - activeIndicator trie key := by
  have target := Proofs.change_success h c r trie next action o accepted
  have law := change_key_law h c r trie next action o accepted
  by_cases same : action.key = key
  · cases action with
    | register reference actionKey index deposit =>
      simp only [Change.key] at same
      subst actionKey
      simp [target, targetTrie, activeIndicator, trieGet_set_eq, law.1, actionDelta, Change.key]
    | terminate reference actionKey =>
      simp only [Change.key] at same
      subst actionKey
      simp [target, targetTrie, activeIndicator, trieGet_set_eq, law.1, actionDelta, Change.key]
  · have frame : trieGet next key = trieGet trie key := by
      rw [target]
      cases action <;> apply trieGet_set_of_ne <;> exact Ne.symm same
    simp [same, activeIndicator, frame]

theorem batch_indicator (h : Hash) (c : Codec) (r : PublishedRelease)
    (actions : List Change) (trie next : Trie) (o : FoldObservation) (key : Key)
    (accepted : actions.foldlM (fun trie action => change .none h c r trie action o) trie = .ok next) :
    (actions.map fun action => if action.key = key then actionDelta action else 0).sum =
      activeIndicator next key - activeIndicator trie key := by
  induction actions generalizing trie with
  | nil =>
    have same : trie = next := by simpa [pure, Except.pure] using accepted
    simp [same]
  | cons action actions ih =>
    simp only [List.foldlM_cons, bind, Except.bind] at accepted
    cases first : change .none h c r trie action o with
    | error why => simp [first] at accepted
    | ok middle =>
      simp only [first] at accepted
      have one := change_indicator h c r trie middle action o key first
      have rest := ih middle accepted
      simp only [List.map_cons, List.sum_cons]
      omega

theorem sum_filter_entries (entries : List (TokenId × Int)) (asset : TokenId) :
    ((entries.filter fun entry => entry.1 == asset).map (·.2)).sum =
      (entries.map fun entry => if entry.1 == asset then entry.2 else 0).sum := by
  induction entries with
  | nil => rfl
  | cons entry entries ih =>
    simp only [List.filter_cons, List.map_cons, List.sum_cons]
    split <;> simp_all

@[simp] theorem token_refl (asset : TokenId) : (asset == asset) = true := by
  cases asset
  simp [BEq.beq, instBEqTokenId.beq]

@[simp] theorem sum_zero_map {α : Type} (xs : List α) :
    (xs.map fun _ => (0 : Int)).sum = 0 := by
  induction xs <;> simp_all

theorem fold_mint_indicator (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (before after : CandidateWorld) (o : FoldObservation)
    (domain : after.domain = before.domain ++ o.changes.flatMap (changePreimages o))
    (registry : TokenId) (key : Key)
    (encoding : FiniteEncoding c (after.domain ++ [.active registry key]))
    (collision : FiniteCollisionFree h c (after.domain ++ [.active registry key]))
    (own : registry.policy = r.statePolicy)
    (accepted : fold .none h c t r o = true) :
    NoPin.mintQty o.assets (activeAsset h c registry key) =
      if registry = o.before.identity then
        activeIndicator o.after.trie key - activeIndicator o.before.trie key else 0 := by
  have conditions := accepted
  simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
  have beforeIdentity := Proofs.token_eq _ _ conditions.1.1.1.1.1.1.1.1.1.1.1.1
  have policy : o.before.identity.policy = r.statePolicy := by rw [beforeIdentity]; rfl
  have delta := Proofs.delta_at o.assets o.before.identity.policy (expectedDelta h c o)
    conditions.1.2 (activeAsset h c registry key) (by simpa [activeAsset, policy] using own)
  rw [delta, sum_filter_entries]
  simp only [expectedDelta, List.map_map]
  have entries : ∀ action ∈ o.changes,
      (if activeAsset h c o.before.identity action.key == activeAsset h c registry key
        then actionDelta action else 0) =
      if registry = o.before.identity then (if action.key = key then actionDelta action else 0) else 0 := by
    intro action member
    have inject := active_injective h c _ encoding collision o.before.identity registry action.key key
      (List.mem_append_left _ (active_in_fold_domain before after o domain action member)) (by simp)
    by_cases same : registry = o.before.identity
    · by_cases sameKey : action.key = key
      · simp [same, sameKey]
      · have different : (activeAsset h c o.before.identity action.key == activeAsset h c registry key) = false := by
          apply Bool.eq_false_iff.mpr
          intro positive
          exact sameKey (inject (Proofs.token_eq _ _ positive)).2
        rw [different]
        simp [same, sameKey]
    · have different : (activeAsset h c o.before.identity action.key == activeAsset h c registry key) = false := by
        apply Bool.eq_false_iff.mpr
        intro positive
        exact same (inject (Proofs.token_eq _ _ positive)).1.symm
      rw [different]
      simp [same]
  change (o.changes.map (fun action => if activeAsset h c o.before.identity action.key ==
    activeAsset h c registry key then actionDelta action else 0)).sum = _
  rw [List.map_congr_left entries]
  split
  · exact batch_indicator h c r o.changes o.before.trie o.after.trie o key
      (Proofs.fold_result h c t r o accepted).1
  · simp

noncomputable def worldIndicator (world : CandidateWorld) (identity : TokenId) (key : Key) : Int :=
  by
    classical
    exact if ∃ registry ∈ world.registries, registry.identity = identity ∧
      trieGet registry.trie key = .known .active then 1 else 0

theorem world_indicator_at (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (world : CandidateWorld) (reachable : CandidateReachable h c t r world)
    (registry : PublicRegistry) (member : registry ∈ world.registries) (key : Key) :
    worldIndicator world registry.identity key = activeIndicator registry.trie key := by
  classical
  have equivalence : (∃ candidate ∈ world.registries, candidate.identity = registry.identity ∧
      trieGet candidate.trie key = .known .active) ↔ trieGet registry.trie key = .known .active := by
    constructor
    · rintro ⟨candidate, present, same, active⟩
      have equal := registry_unique h c t r world reachable candidate present registry member same
      simpa [equal] using active
    · intro active
      exact ⟨registry, member, rfl, active⟩
  simp only [worldIndicator, equivalence, activeIndicator]

theorem world_indicator_fold_other (before after : CandidateWorld) (o : FoldObservation)
    (registries : after.registries = before.registries.map fun registry =>
      if registry.identity == o.before.identity then o.after else registry)
    (identity : o.after.identity = o.before.identity) (query : TokenId) (key : Key)
    (different : query ≠ o.before.identity) :
    worldIndicator after query key = worldIndicator before query key := by
  classical
  have equivalence : (∃ registry ∈ after.registries, registry.identity = query ∧
      trieGet registry.trie key = .known .active) ↔
      (∃ registry ∈ before.registries, registry.identity = query ∧
      trieGet registry.trie key = .known .active) := by
    constructor
    · rintro ⟨registry, member, same, active⟩
      rw [registries] at member
      obtain ⟨previous, previousMember, rfl⟩ := List.mem_map.mp member
      by_cases hit : previous.identity == o.before.identity
      · simp only [hit, ↓reduceIte] at same
        exact False.elim (different (same.symm.trans identity))
      · simp only [hit, Bool.false_eq_true, ↓reduceIte] at same active
        exact ⟨previous, previousMember, same, active⟩
    · rintro ⟨registry, member, same, active⟩
      have noHit : (registry.identity == o.before.identity) = false := by
        apply Bool.eq_false_iff.mpr
        intro hit
        exact different (same.symm.trans (Proofs.token_eq _ _ hit))
      refine ⟨registry, ?_, same, active⟩
      rw [registries]
      exact List.mem_map.mpr ⟨registry, member, by simp [noHit]⟩
  simp only [worldIndicator, equivalence]

theorem world_indicator_genesis (before after : CandidateWorld) (registry : PublicRegistry)
    (registries : after.registries = before.registries ++ [registry]) (emptyTrie : registry.trie = [])
    (query : TokenId) (key : Key) : worldIndicator after query key = worldIndicator before query key := by
  classical
  have equivalence : (∃ candidate ∈ after.registries, candidate.identity = query ∧
      trieGet candidate.trie key = .known .active) ↔
      (∃ candidate ∈ before.registries, candidate.identity = query ∧
      trieGet candidate.trie key = .known .active) := by
    constructor
    · rintro ⟨candidate, member, same, active⟩
      rw [registries] at member
      rcases List.mem_append.mp member with old | added
      · exact ⟨candidate, old, same, active⟩
      · have equal : candidate = registry := by simpa using added
        simp [equal, emptyTrie, trieGet] at active
    · rintro ⟨candidate, member, same, active⟩
      exact ⟨candidate, by rw [registries]; exact List.mem_append_left _ member, same, active⟩
  simp only [worldIndicator, equivalence]

theorem genesis_active_zero (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (seed : OutRef) (view : NoPin.TxView) (outputs : List ObservedOutput)
    (domain : List Preimage) (registry : TokenId) (key : Key)
    (stateMember : Preimage.state seed ∈ domain) (activeMember : Preimage.active registry key ∈ domain)
    (encoding : FiniteEncoding c domain) (collision : FiniteCollisionFree h c domain)
    (own : registry.policy = r.statePolicy)
    (accepted : genesis .none h c t r seed view outputs = true) :
    NoPin.mintQty view (activeAsset h c registry key) = 0 := by
  have different : stateAsset h c r seed ≠ activeAsset h c registry key := by
    intro same
    have names := congrArg TokenId.name same
    have impossible := encoding _ stateMember _ activeMember (collision _ stateMember _ activeMember names)
    cases impossible
  have noHit : (stateAsset h c r seed == activeAsset h c registry key) = false := by
    apply Bool.eq_false_iff.mpr
    intro hit
    exact different (Proofs.token_eq _ _ hit)
  simp only [genesis, Proofs.applyGuard_none, Bool.and_eq_true] at accepted
  have delta := Proofs.delta_at view r.statePolicy [(stateAsset h c r seed, 1)]
    accepted.1.1.2 (activeAsset h c registry key) own
  simpa [noHit] using delta

theorem encoding_mono (c : Codec) (small large : List Preimage)
    (subset : ∀ x ∈ small, x ∈ large) (encoding : FiniteEncoding c large) :
    FiniteEncoding c small := by
  intro a ha b hb same
  exact encoding a (subset a ha) b (subset b hb) same

theorem collision_mono (h : Hash) (c : Codec) (small large : List Preimage)
    (subset : ∀ x ∈ small, x ∈ large) (collision : FiniteCollisionFree h c large) :
    FiniteCollisionFree h c small := by
  intro a ha b hb same
  exact collision a (subset a ha) b (subset b hb) same

theorem world_supply (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (world : CandidateWorld) (reachable : CandidateReachable h c t r world) :
    ∀ registry key, registry.policy = r.statePolicy →
      FiniteEncoding c (world.domain ++ [.active registry key]) →
      FiniteCollisionFree h c (world.domain ++ [.active registry key]) →
      Int.ofNat (totalQuantity world.unspent (activeAsset h c registry key)) =
        worldIndicator world registry key := by
  induction reachable with
  | initial outputs unique noOwnAssets =>
    intro registry key own encoding collision
    have absent : activeAsset h c registry key ∉ assetSupport outputs := by
      intro member
      obtain ⟨output, outputMember, assetMember⟩ := List.mem_flatMap.mp member
      exact noOwnAssets output outputMember (activeAsset h c registry key)
        (by simpa [assetSupport] using assetMember) own
    simp [total_absent _ _ absent, worldIndicator]
  | @genesis before after reachable seed view inputs outputs created fee donation ledger accepted identity seedBinding
      statePresent recognized emptyTrie newRegistry registries domain ih =>
    intro registry key own encoding collision
    have subset : ∀ x ∈ before.domain ++ [.active registry key], x ∈ after.domain ++ [.active registry key] := by
      intro x member
      rcases List.mem_append.mp member with old | query
      · exact List.mem_append_left _ (by rw [domain]; exact List.mem_append_left _ old)
      · exact List.mem_append_right _ query
    have previous := ih registry key own (encoding_mono c _ _ subset encoding)
      (collision_mono h c _ _ subset collision)
    have law := conserved_at before.unspent after.unspent view ledger.assetsConserved (activeAsset h c registry key)
    have zero := genesis_active_zero h c t r seed view outputs (after.domain ++ [.active registry key])
      registry key (by rw [domain]; simp) (by simp) encoding collision own accepted
    have frame := world_indicator_genesis before after created registries emptyTrie registry key
    omega
  | @fold before after reachable o ledger present accepted registries domain ih =>
    intro registry key own encoding collision
    have subset : ∀ x ∈ before.domain ++ [.active registry key], x ∈ after.domain ++ [.active registry key] := by
      intro x member
      rcases List.mem_append.mp member with old | query
      · exact List.mem_append_left _ (by rw [domain]; exact List.mem_append_left _ old)
      · exact List.mem_append_right _ query
    have previous := ih registry key own (encoding_mono c _ _ subset encoding)
      (collision_mono h c _ _ subset collision)
    have law := conserved_at before.unspent after.unspent o.assets ledger.assetsConserved (activeAsset h c registry key)
    have delta := fold_mint_indicator h c t r before after o domain registry key encoding collision own accepted
    have conditions := accepted
    simp only [fold, Proofs.applyGuard_none, Bool.and_eq_true] at conditions
    have afterIdentity := Proofs.token_eq _ _ conditions.1.1.1.1.1.1.1.1.1.1.1.2
    by_cases same : registry = o.before.identity
    · have afterReachable := CandidateReachable.fold reachable o ledger present accepted registries domain
      have afterMember : o.after ∈ after.registries := by
        rw [registries]
        exact List.mem_map.mpr ⟨o.before, present, by simp⟩
      have beforeIndicator := world_indicator_at h c t r before reachable o.before present key
      have afterIndicator := world_indicator_at h c t r after afterReachable o.after afterMember key
      rw [afterIdentity] at afterIndicator
      simp only [same, ↓reduceIte] at delta previous law ⊢
      omega
    · have frame := world_indicator_fold_other before after o registries afterIdentity registry key same
      simp only [same, ↓reduceIte] at delta
      omega
  | @neutral before after reachable view inputs outputs fee donation ledger noOwnMint stateUntouched registries domain ih =>
    intro registry key own encoding collision
    have previous := ih registry key own (by simpa [domain] using encoding) (by simpa [domain] using collision)
    have law := conserved_at before.unspent after.unspent view ledger.assetsConserved (activeAsset h c registry key)
    have zero := Proofs.delta_at view r.statePolicy [] noOwnMint (activeAsset h c registry key) own
    simp only [List.filter_nil, List.map_nil, List.sum_nil] at zero
    have frame : worldIndicator after registry key = worldIndicator before registry key := by
      simp only [worldIndicator, registries]
    omega

end NoPin.ApplicationRequests.HistoryProofs
