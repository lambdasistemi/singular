import SingularApplicationHeld.DeliveryProofs

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/
namespace SingularApplicationHeld.Proofs
open Singular Lean

/-- Proof helper: the derived complete-asset comparison is sound. -/
theorem token_eq (a b : TokenId) (same : (a == b) = true) : a = b := by
  cases a
  cases b
  simp_all [BEq.beq, instBEqTokenId.beq]

/-- Proof helper: recognition exposes the one actual state asset. -/
theorem recognized_assets (h : Hash) (c : Codec) (r : PublishedRelease) (seed : OutRef)
    (output : ObservedOutput) (recognized : recognizeState .none h c r seed output = true) :
    output.assets = [(stateAsset h c r seed, 1)] := by
  simp only [recognizeState, applyGuard_none, Bool.and_eq_true] at recognized
  have length : output.assets.length = 1 := by simpa using recognized.2
  obtain ⟨entry, entries⟩ := List.length_eq_one_iff.mp length
  simp only [entries, List.head?_cons, Option.getD_some] at recognized
  have policy : entry.1.policy = (stateAsset h c r seed).policy := by
    simpa using recognized.1.1.1.1.2
  have name : entry.1.name = (stateAsset h c r seed).name := by
    simpa using recognized.1.1.1.2
  have quantity : entry.2 = 1 := by simpa using recognized.1.1.2
  rcases entry with ⟨⟨policyValue, nameValue⟩, amount⟩
  simp_all [stateAsset]

/-- Proof helper: each actual active role is distinct from the state role. -/
theorem fold_active_not_state (h : Hash) (c : Codec) (o : FoldObservation)
    (encoding : FiniteEncoding c (foldRoleDomain o))
    (collision : FiniteCollisionFree h c (foldRoleDomain o))
    (action : Change) (member : action ∈ o.changes) :
    activeAsset h c o.before.identity action.key ≠
      ⟨o.before.identity.policy, h (c (.state o.before.seed))⟩ := by
  intro same
  have activeMember : Preimage.active o.before.identity action.key ∈ foldRoleDomain o := by
    simp only [foldRoleDomain, List.mem_cons]
    exact Or.inr (List.mem_map.mpr ⟨action, member, rfl⟩)
  have stateMember : Preimage.state o.before.seed ∈ foldRoleDomain o := by simp [foldRoleDomain]
  have names := congrArg TokenId.name same
  have encoded := collision _ activeMember _ stateMember names
  have impossible := encoding _ activeMember _ stateMember encoded
  cases impossible

/-- Proof helper: an absent asset has no entries in a filtered census. -/
theorem filter_absent (entries : List (TokenId × Int)) (asset : TokenId)
    (absent : asset ∉ entries.map (·.1)) :
    entries.filter (fun entry => entry.1 == asset) = [] := by
  apply List.filter_eq_nil_iff.mpr
  intro entry member same
  exact absent (List.mem_map.mpr ⟨entry, member, token_eq _ _ same⟩)

/-- Proof helper: the complete-support policy comparison covers every asset. -/
theorem delta_at (tx : SingularApplicationHeld.Assets.TxView) (policy : Nat) (expected : List (TokenId × Int))
    (accepted : policyDelta tx policy expected = true) (asset : TokenId)
    (own : asset.policy = policy) :
    SingularApplicationHeld.Assets.mintQty tx asset = ((expected.filter fun entry => entry.1 == asset).map (·.2)).sum := by
  by_cases present : asset ∈ (tx.mint ++ expected).map (·.1)
  · have atAsset := List.all_eq_true.mp accepted asset present
    simpa [own] using atAsset
  · have missingActual : asset ∉ tx.mint.map (·.1) := by
      intro member
      exact present (by simp [List.map_append, member])
    have missingExpected : asset ∉ expected.map (·.1) := by
      intro member
      exact present (by simp [List.map_append, member])
    simp [SingularApplicationHeld.Assets.mintQty, filter_absent _ _ missingActual, filter_absent _ _ missingExpected]

/-- Proof helper: a fold mints no state-role asset. -/
theorem fold_state_mint_zero (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (o : FoldObservation) (encoding : FiniteEncoding c (foldRoleDomain o))
    (collision : FiniteCollisionFree h c (foldRoleDomain o))
    (accepted : fold .none h c t r o = true) :
    SingularApplicationHeld.Assets.mintQty o.assets (stateAsset h c r o.before.seed) = 0 := by
  have full := accepted
  simp only [fold, applyGuard_none, Bool.and_eq_true] at full
  have identityBool : (o.before.identity == stateAsset h c r o.before.seed) = true :=
    full.1.1.1.1.1.1.1.1.1.1.1.1
  have identity := token_eq _ _ identityBool
  have absent : stateAsset h c r o.before.seed ∉ (expectedDelta h c o).map (·.1) := by
    intro member
    obtain ⟨entry, entryMember, same⟩ := List.mem_map.mp member
    obtain ⟨action, actionMember, actionEntry⟩ := List.mem_map.mp entryMember
    subst entry
    have different := fold_active_not_state h c o encoding collision action actionMember
    apply different
    have policy : o.before.identity.policy = r.statePolicy := by rw [identity]; rfl
    simpa [stateAsset, policy] using same
  have own : (stateAsset h c r o.before.seed).policy = o.before.identity.policy := by
    rw [identity]
  have law := delta_at o.assets o.before.identity.policy (expectedDelta h c o)
    full.1.2 (stateAsset h c r o.before.seed) own
  simpa [filter_absent _ _ absent] using law

/-- Proof helper: actual positively minted assets cannot occupy a recognized state. -/
theorem minted_outputs (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (premises : MintedOutputsPremises .none h c t q) :
    MintedOutputsConclusion .none h c t q := by
  rcases premises with ⟨encoding, collision, accepted⟩
  refine ⟨accepted, ?_⟩
  intro output _ entry member _ _ minted
  cases recognized : recognizeState .none h c q.release q.observation.before.seed output with
  | false => rfl
  | true =>
    have assets := recognized_assets h c q.release q.observation.before.seed output recognized
    have same : entry = (stateAsset h c q.release q.observation.before.seed, 1) := by
      simpa [assets] using member
    have zero := fold_state_mint_zero h c t q.release q.observation encoding collision accepted
    rw [same] at minted
    simp only [zero] at minted
    omega

end SingularApplicationHeld.Proofs
