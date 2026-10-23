import NoPin.ApplicationRequests.Proofs

/-! Hypothetical holding-delivery proof helpers, not accepted law. -/
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
namespace NoPin.ApplicationRequests.Proofs
open Singular Lean

/-- Hypothesis helper: independent per-action delivery obligation. -/
def deliveryAt (h : Hash) (c : Codec) (o : FoldObservation) (action : Change) : Bool :=
  match action with
  | .register ref key index deposit => match o.outputs[index]? with
    | some output => separateHolding o ref index && oneNewToken h c o output &&
        quantity output (activeAsset h c o.before.identity key) == 1 && deposit ≤ output.lovelace
    | none => false
  | .terminate .. => true

/-- Hypothesis helper: an accepted change checks its holding and deposit. -/
theorem change_delivery (h : Hash) (c : Codec) (r : PublishedRelease)
    (trie next : Trie) (action : Change) (o : FoldObservation)
    (accepted : change .none h c r trie action o = .ok next) :
    deliveryAt h c o action = true := by
  cases action with
  | terminate => rfl
  | register ref key index deposit =>
    simp only [change, applyGuard_none, bind, Except.bind, pure, Except.pure, holdingAt] at accepted
    simp only [deliveryAt]
    repeat' first |
      (simp_all [bind, Except.bind, pure, Except.pure, throw, throwThe, Change.reference, Change.key]; done) |
      split at accepted

/-- Hypothesis helper: each action of an accepted ordered batch delivers its own holding. -/
theorem batch_delivery (h : Hash) (c : Codec) (r : PublishedRelease) (o : FoldObservation)
    (actions : List Change) (trie next : Trie)
    (accepted : actions.foldlM (fun trie action => change .none h c r trie action o) trie = .ok next) :
    actions.all (deliveryAt h c o) = true := by
  induction actions generalizing trie with
  | nil => rfl
  | cons action actions ih =>
    simp only [List.foldlM_cons, bind, Except.bind] at accepted
    cases first : change .none h c r trie action o with
    | error why => simp [first] at accepted
    | ok middle =>
      simp only [first] at accepted
      simp only [List.all_cons, Bool.and_eq_true]
      exact ⟨change_delivery h c r trie middle action o first, ih middle accepted⟩

/-- Hypothesis helper: the actual fold's full registration delivery is preserved. -/
theorem fold_delivery (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (o : FoldObservation) (accepted : fold .none h c t r o = true) :
    holdingDelivery h c o = true := by
  obtain ⟨result, _⟩ := fold_result h c t r o accepted
  exact batch_delivery h c r o o.changes o.before.trie o.after.trie result

end NoPin.ApplicationRequests.Proofs
