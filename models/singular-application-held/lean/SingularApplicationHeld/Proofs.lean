import SingularApplicationHeld.Effects
import Singular.Lemmas.State

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
namespace SingularApplicationHeld.Proofs
open Singular Lean

@[simp] theorem applyGuard_none (site : Guard) (b : Bool) :
    applyGuard .none site b = b := by rfl

/-- Proof helper: guards at the candidate selector match the conditions. -/
theorem change_eq (h : Hash) (c : Codec) (r : PublishedRelease)
    (trie : Trie) (action : Change) (o : FoldObservation) :
    change .none h c r trie action o = changeConditions h c r trie action o := by
  simp [change, changeConditions, bind, Except.bind, pure, Except.pure, throw] <;> rfl


/-- Proof helper: successful change returns its literal target trie. -/
theorem change_target (h : Hash) (c : Codec) (r : PublishedRelease)
    (trie : Trie) (action : Change) (o : FoldObservation) :
    (change .none h c r trie action o).toOption = some (targetTrie trie action) ↔
      (changeConditions h c r trie action o).isOk = true := by
  rw [change_eq]
  cases action <;>
    simp only [changeConditions, targetTrie, bind, Except.bind, pure, Except.pure, Functor.map, Except.map]
  all_goals repeat' first | (simp_all [bind, Except.bind, pure, Except.pure, Functor.map, Except.map, Except.toOption, Except.isOk, Except.toBool, throw, throwThe]; done) | rfl | split

/-- Proof helper: finite structural and hash separation distinguish roles. -/
theorem active_not_state (h : Hash) (c : Codec) (q : Query) (p : RolePremises h c q) :
    recognizeState .none h c q.release q.seed q.output = false := by
  rcases p with ⟨encoding, collision, output⟩
  have different : h (c (.active q.observation.before.identity q.action.key)) ≠ h (c (.state q.seed)) := by
    intro same
    have encoded := collision (.active q.observation.before.identity q.action.key)
      (by simp [roleDomain]) (.state q.seed) (by simp [roleDomain]) same
    have impossible := encoding (.active q.observation.before.identity q.action.key)
      (by simp [roleDomain]) (.state q.seed) (by simp [roleDomain]) encoded
    cases impossible
  simp [recognizeState, output, activeAsset, stateAsset, different]

/-- Proof helper: each accepted operation has its specified trie effect. -/
theorem change_success (h : Hash) (c : Codec) (r : PublishedRelease)
    (trie next : Trie) (action : Change) (o : FoldObservation)
    (accepted : change .none h c r trie action o = .ok next) :
    next = targetTrie trie action := by
  have success : (changeConditions h c r trie action o).isOk = true := by
    rw [← change_eq, accepted]
    rfl
  have target := (change_target h c r trie action o).2 success
  simpa [accepted, Except.toOption] using target

/-- Proof helper: successful ordered batches compute the independent fold. -/
theorem batch_success (h : Hash) (c : Codec) (r : PublishedRelease) (o : FoldObservation)
    (actions : List Change) (trie next : Trie)
    (accepted : actions.foldlM (fun trie action => change .none h c r trie action o) trie = .ok next) :
    next = actions.foldl targetTrie trie := by
  induction actions generalizing trie with
  | nil => simpa [pure, Except.pure] using accepted.symm
  | cons action actions ih =>
    simp only [List.foldlM_cons, bind, Except.bind] at accepted
    cases first : change .none h c r trie action o with
    | error why => simp [first] at accepted
    | ok middle =>
      simp only [first] at accepted
      have same := change_success h c r trie middle action o first
      simpa [List.foldl_cons, same] using ih middle accepted

/-- Proof helper: acceptance exposes the result and continuing root. -/
theorem fold_result (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (o : FoldObservation) (accepted : fold .none h c t r o = true) :
    changeBatch .none h c r o = .ok o.after.trie ∧
    o.after.state.datum = .root (t o.after.trie) := by
  have conditions := accepted
  simp only [fold, applyGuard_none, Bool.and_eq_true] at conditions
  have result := conditions.1.1.1.1.1.2
  cases actual : changeBatch .none h c r o with
  | error why => simp [actual] at result
  | ok trie =>
    simp [actual] at result
    have datum : o.after.state.datum = .root (t o.after.trie) := by
      cases shape : o.after.state.datum <;> simp_all [BEq.beq, instBEqOutputDatum.beq]
    exact ⟨by simpa [result.1] using actual, datum⟩

/-- Proof helper: an accepted fold has independent trie/root effects. -/
theorem fold_effect (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (o : FoldObservation) (accepted : fold .none h c t r o = true) : batchEffects t o := by
  obtain ⟨result, root⟩ := fold_result h c t r o accepted
  have same := batch_success h c r o o.changes o.before.trie o.after.trie result
  exact ⟨same, by simpa [same] using root⟩

/-- Proof helper: independent updates retain keys outside the batch. -/
theorem target_frame (actions : List Change) (trie : Trie) (key : Key)
    (outside : key ∉ actions.map Change.key) :
    trieGet (actions.foldl targetTrie trie) key = trieGet trie key := by
  induction actions generalizing trie with
  | nil => rfl
  | cons action actions ih =>
    simp only [List.map_cons, List.mem_cons, not_or] at outside
    have distinct : key ≠ action.key := outside.1
    have rest : key ∉ actions.map Change.key := outside.2
    rw [List.foldl_cons, ih _ rest]
    cases action <;> apply Singular.trieGet_set_of_ne <;> exact distinct

end SingularApplicationHeld.Proofs
