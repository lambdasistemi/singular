import Singular.Model.LedgerBoundary
import Singular.Lemmas.Batch

/-! A positive net active mint is an unknown-to-active transition of the
existing batch law, including when other keys are folded in the same batch. -/

namespace Singular.LedgerBoundary

def activeIndicator (leaf : Leaf) : Int := if leaf = .known .active then 1 else 0

theorem step_active_balance (s : RegistryState) (a : Request) (result : Result)
    (accepted : step s a = .ok result) (key : Key) :
    assetKind result.mint (.active, key) =
      activeIndicator (trieGet result.state.trie key) - activeIndicator (trieGet s.trie key) := by
  obtain ⟨refused, effect⟩ := step_eq_ok s a result accepted
  obtain ⟨_, _, _, _, cases⟩ := (refusal_none_iff s a).mp refused
  subst result
  rcases cases with ⟨edge, before⟩ | ⟨edge, before, _⟩ <;>
    by_cases same : key = a.key
  · subst key
    simp [assetKind, assetDelta, delta, edge, applyEdge, activeIndicator, trieGet_set_eq, before]
  · simp [assetKind, assetDelta, delta, edge, applyEdge, activeIndicator,
      same, Ne.symm same, trieGet_set_of_ne, before]
  · subst key
    simp [assetKind, assetDelta, delta, edge, applyEdge, activeIndicator, trieGet_set_eq, before]
  · simp [assetKind, assetDelta, delta, edge, applyEdge, activeIndicator,
      same, Ne.symm same, trieGet_set_of_ne, before]

theorem step_inert_leaf (s : RegistryState) (a : Request) (result : Result)
    (accepted : step s a = .ok result) (key : Key)
    (inert : trieGet s.trie key = .known .absent ∨ trieGet s.trie key = .known .terminal) :
    trieGet result.state.trie key = trieGet s.trie key := by
  obtain ⟨refused, effect⟩ := step_eq_ok s a result accepted
  obtain ⟨_, _, _, _, cases⟩ := (refusal_none_iff s a).mp refused
  subst result
  rcases cases with ⟨edge, before⟩ | ⟨edge, before, _⟩
  all_goals
    have different : key ≠ a.key := by
      intro same
      rcases inert with absent | terminal <;> simp_all
    simp [applyEdge, edge, trieGet_set_of_ne _ _ _ _ different]

theorem foldActions_active_balance (s : RegistryState) (batch : List Request) (result : Result)
    (accepted : foldActions s batch = .ok result) (key : Key) :
    assetKind result.mint (.active, key) =
      activeIndicator (trieGet result.state.trie key) - activeIndicator (trieGet s.trie key) := by
  induction batch generalizing s result with
  | nil => simp [foldActions] at accepted; subst result; simp [emptyResult, assetKind]
  | cons a rest ih =>
    cases first : step s a with
    | error why => simp [foldActions, first, bind, Except.bind] at accepted
    | ok next =>
      cases later : foldActions next.state rest with
      | error why => simp [foldActions, first, later, bind, Except.bind] at accepted
      | ok last =>
        simp [foldActions, first, later, bind, Except.bind, pure, Except.pure] at accepted
        subst result
        have head := step_active_balance s a next first key
        have tail := ih next.state last later
        simp only [combineResults, assetKind_plus]
        omega

theorem foldActions_inert_leaf (s : RegistryState) (batch : List Request) (result : Result)
    (accepted : foldActions s batch = .ok result) (key : Key)
    (inert : trieGet s.trie key = .known .absent ∨ trieGet s.trie key = .known .terminal) :
    trieGet result.state.trie key = trieGet s.trie key := by
  induction batch generalizing s result with
  | nil => simp [foldActions] at accepted; subst result; rfl
  | cons a rest ih =>
    cases first : step s a with
    | error why => simp [foldActions, first, bind, Except.bind] at accepted
    | ok next =>
      cases later : foldActions next.state rest with
      | error why => simp [foldActions, first, later, bind, Except.bind] at accepted
      | ok last =>
        simp [foldActions, first, later, bind, Except.bind, pure, Except.pure] at accepted
        subst result
        have head := step_inert_leaf s a next first key inert
        have tail := ih next.state last later (by rw [head]; exact inert)
        exact tail.trans head

theorem foldActions_reachable (s : RegistryState) (batch : List Request) (result : Result)
    (accepted : foldActions s batch = .ok result) (reachable : Reachable s) :
    Reachable result.state := by
  induction batch generalizing s result with
  | nil => simp [foldActions] at accepted; subst result; exact reachable
  | cons a rest ih =>
    cases first : step s a with
    | error why => simp [foldActions, first, bind, Except.bind] at accepted
    | ok next =>
      cases later : foldActions next.state rest with
      | error why => simp [foldActions, first, later, bind, Except.bind] at accepted
      | ok last =>
        simp [foldActions, first, later, bind, Except.bind, pure, Except.pure] at accepted
        subst result
        exact ih next.state last later (Reachable.next reachable first)

theorem admitted_positive_active (s : RegistryState) (batch : List Request) (witness : FoldWitness)
    (result : Result) (accepted : admittedFoldBatch s batch witness = .ok result)
    (key : Key) (positive : 0 < assetKind result.mint (.active, key)) :
    trieGet s.trie key = .unknown ∧ trieGet result.state.trie key = .known .active ∧
    (Reachable s → kindCount result.state .active key = 1) := by
  have folded : foldBatch s batch = .ok result := by
    unfold admittedFoldBatch at accepted
    split at accepted
    · cases accepted
    · exact accepted
  have actions := (foldBatch_inv s batch result folded).2
  have balance := foldActions_active_balance s batch result actions key
  have after : trieGet result.state.trie key = .known .active := by
    unfold activeIndicator at balance
    split at balance <;> split at balance <;> omega
  have before : trieGet s.trie key = .unknown := by
    cases leaf : trieGet s.trie key with
    | unknown => rfl
    | known value =>
      cases value with
      | active => simp [activeIndicator, leaf, after] at balance; omega
      | absent =>
        have same := foldActions_inert_leaf s batch result actions key (Or.inl leaf)
        simp [leaf, after] at same
      | terminal =>
        have same := foldActions_inert_leaf s batch result actions key (Or.inr leaf)
        simp [leaf, after] at same
  refine ⟨before, after, ?_⟩
  intro reachable
  exact ((reachable_consistent result.state
    (foldActions_reachable s batch result actions reachable)).2.1 key).mpr after

end Singular.LedgerBoundary
