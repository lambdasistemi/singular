import NoPin.ApplicationRequests.PublicProofs

/-! Hypothetical model statements, not accepted law. Proof status is recorded per
declaration; finite instance evidence remains separate from general proofs. -/
namespace NoPin.ApplicationRequests.Statements
open Singular Lean

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Complete public recognition inversion; all observed guards and effects are exposed. -/
theorem recognition_inversion (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_case : q.surface = .recognition ∧ caseShape q = true) :
    runWith .none hash code commit q = true ↔ expectedWith hash code commit q = true := by
  simp only [runWith, expectedWith, _case.1]
  rfl

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Complete public genesis inversion; all observed guards and effects are exposed. -/
theorem genesis_inversion (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_case : q.surface = .genesis ∧ caseShape q = true) :
    runWith .none hash code commit q = true ↔ expectedWith hash code commit q = true := by
  simp only [runWith, expectedWith, _case.1]
  rfl

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Complete public registration inversion; all observed guards and effects are exposed. -/
theorem registration_inversion (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_case : q.surface = .registration ∧ caseShape q = true) :
    runWith .none hash code commit q = true ↔ expectedWith hash code commit q = true := by
  simp only [runWith, expectedWith, _case.1]
  rw [Proofs.change_eq]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Complete public termination inversion; all observed guards and effects are exposed. -/
theorem termination_inversion (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_case : q.surface = .termination ∧ caseShape q = true) :
    runWith .none hash code commit q = true ↔ expectedWith hash code commit q = true := by
  simp only [runWith, expectedWith, _case.1]
  rw [Proofs.change_eq]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Complete public batch inversion; all observed guards and effects are exposed. -/
theorem batch_inversion (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_case : q.surface = .batch ∧ caseShape q = true) :
    runWith .none hash code commit q = true ↔ expectedWith hash code commit q = true := by
  simp only [runWith, expectedWith, _case.1]
  rfl

/-- Hypothesis under #741, not accepted law. Status: PROVED.
A genuine active asset cannot authenticate a root-only state, even with a fabricated root. -/
theorem active_role_never_state (hash : Hash) (code : Codec) (_commit : TrieCommit) (q : Query)
    (_premises : RolePremises hash code q) :
    recognizeState .none hash code q.release q.seed q.output = false := by
  exact Proofs.active_not_state hash code q _premises

/-- Hypothesis under #741, not accepted law. Status: PROVED.
An active token actually minted by an accepted fold cannot satisfy state recognition. -/
theorem minted_active_never_state (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_premises : MintedRolePremises hash code commit q) :
    recognizeState .none hash code q.release q.seed q.output = false := by
  exact Proofs.active_not_state hash code q _premises.1

/-- Hypothesis under #741, not accepted law. Status: STATED.
Anyone constructs this accepted and balanced model fold from public records alone.
Actual provider completeness, real output minimums, willingness and inclusion remain external. -/
theorem public_fold_constructed (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_premises : PublicPremises hash code commit q) :
    PublicConclusion .none hash code commit q := by
  apply Proofs.public_conclusion_of_remaining hash code commit q _premises
  · sorry
  · sorry
  · sorry

/-- Hypothesis under #741, not accepted law. Status: PROVED.
The generic public-builder surface exposes the same complete fold conditions. -/
theorem publicFold_inversion (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query)
    (_case : q.surface = .publicFold ∧ caseShape q = true) :
    runWith .none hash code commit q = true ↔ expectedWith hash code commit q = true := by
  simp only [runWith, expectedWith, _case.1]
  rfl


/-- Hypothesis under #741, not accepted law. Status: PROVED.
Registration exposes the independently active target, retaining every other key. -/
theorem registration_effects (h : Hash) (c : Codec) (_t : TrieCommit) (q : Query)
    (_case : q.surface = .registration ∧ caseShape q = true) :
    (change .none h c q.release q.trie q.action q.observation).toOption = some (targetTrie q.trie q.action) ↔
      (changeConditions h c q.release q.trie q.action q.observation).isOk = true := by
  exact Proofs.change_target h c q.release q.trie q.action q.observation
/-- Hypothesis under #741, not accepted law. Status: PROVED.
Termination exposes the independently terminal target, retaining every other key. -/
theorem termination_effects (h : Hash) (c : Codec) (_t : TrieCommit) (q : Query)
    (_case : q.surface = .termination ∧ caseShape q = true) :
    (change .none h c q.release q.trie q.action q.observation).toOption = some (targetTrie q.trie q.action) ↔
      (changeConditions h c q.release q.trie q.action q.observation).isOk = true := by
  exact Proofs.change_target h c q.release q.trie q.action q.observation
/-- Hypothesis under #741, not accepted law. Status: PROVED.
Whole-fold inversion adds the independent ordered trie and commitment effects. -/
theorem batch_effects (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (_case : q.surface = .batch ∧ caseShape q = true) :
    fold .none h c t q.release q.observation = true ↔
      foldConditions h c t q.release q.observation = true ∧ batchEffects t q.observation := by
  constructor
  · intro accepted
    exact ⟨by simpa only [fold, Proofs.applyGuard_none, foldConditions] using accepted,
      Proofs.fold_effect h c t q.release q.observation accepted⟩
  · intro conditions
    simpa only [fold, Proofs.applyGuard_none, foldConditions] using conditions.1
/-- Hypothesis under #741, not accepted law. Status: PROVED.
Each registration owns a distinct output with one new token and its own deposit floor. -/
theorem registration_separate_holdings (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (_case : q.surface = .batch ∧ caseShape q = true) :
    fold .none h c t q.release q.observation = true ↔
      foldConditions h c t q.release q.observation = true ∧ holdingDelivery h c q.observation = true := by
  constructor
  · intro accepted
    exact ⟨by simpa only [fold, Proofs.applyGuard_none, foldConditions] using accepted,
      Proofs.fold_delivery h c t q.release q.observation accepted⟩
  · intro conditions
    simpa only [fold, Proofs.applyGuard_none, foldConditions] using conditions.1
/-- Hypothesis under #741, not accepted law. Status: PROVED.
An accepted fold's actual output carrying a positively minted own-policy asset is never recognized as state. -/
theorem fold_minted_outputs (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (_premises : MintedOutputsPremises .none h c t q) :
    MintedOutputsConclusion .none h c t q := by
  exact Proofs.minted_outputs h c t q _premises


/-- Hypothesis under #741, not accepted law. Status: PROVED.
The whole fold preserves the leaf of every key outside the changed keys. -/
theorem fold_untouched_keys (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (_premises : q.surface = .batch ∧ fold .none h c t q.release q.observation = true) :
    FoldFrame q.observation := by
  obtain ⟨same, _⟩ := Proofs.fold_effect h c t q.release q.observation _premises.2
  intro key outside
  rw [same]
  exact Proofs.target_frame q.observation.changes q.observation.before.trie key outside
/-- Hypothesis under #741, not accepted law. Status: STATED.
Public construction also has independently specified trie/root effects and the untouched-key frame. -/
theorem public_fold_effects (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (_premises : PublicPremises h c t q) :
    PublicConclusion .none h c t q ∧
    batchEffects t (buildFold h c t q.release q.observation.before q.requests q.funding) ∧
    FoldFrame (buildFold h c t q.release q.observation.before q.requests q.funding) := by
  exact Proofs.public_effects_of_conclusion h c t q (public_fold_constructed h c t q _premises)

end NoPin.ApplicationRequests.Statements
