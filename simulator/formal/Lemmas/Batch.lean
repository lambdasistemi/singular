import Singular.Lemmas.Step
import Singular.Lemmas.Assets

/-! Step chains, batch inversions, created-holding guard and independent requests. -/

namespace Singular

/-- The fold as a step chain: each request applies exactly once, in order. -/
inductive Folds : RegistryState → List Request → Result → Prop where
  | done (s : RegistryState) : Folds s [] (emptyResult s)
  | cons (s : RegistryState) (b : Request) (bs : List Request) (m r : Result) :
      step s b = .ok m → Folds m.state bs r →
      Folds s (b :: bs) (combineResults m r)

/-- `foldBatch` succeeds exactly when the batch is nonempty and every request
applies in order; the mint check does not change the resulting state. -/
theorem foldBatch_inv (s : RegistryState) (batch : List Action) (t : Result)
    (h : foldBatch s batch = .ok t) :
    batch ≠ [] ∧ foldActions s batch = .ok t := by
  have hne : batch ≠ [] := by
    intro hc; subst hc
    exact nomatch (show Except.error "empty-fold" = Except.ok t from h)
  refine ⟨hne, ?_⟩
  unfold foldBatch at h
  rw [if_neg (by simpa using hne)] at h
  cases hf : foldActions s batch with
  | error e => rw [hf] at h; exact nomatch h
  | ok r =>
    rw [hf] at h
    simp only [bind, Except.bind, pure, Except.pure] at h
    split at h
    · cases hc : batchConsumesCreated batch with
      | some why => simp [hc] at h
      | none =>
        simp only [hc] at h
        have hrt : r = t := by injection h
        exact congrArg Except.ok hrt
    · exact nomatch h


/-- The scan succeeds exactly when no termination names an accumulated key
or a key inserted earlier in the remaining list. -/
theorem created_scan_none (created : List Key) (batch : List Request) :
    batchConsumesCreated.go created batch = none ↔
      (∀ r ∈ batch, r.edge = .updateTerminal → r.key ∉ created) ∧
      batch.Pairwise (fun a b => a.edge = .insertActive →
        b.edge = .updateTerminal → a.key ≠ b.key) := by
  induction batch generalizing created with
  | nil => simp [batchConsumesCreated.go]
  | cons r rs ih =>
    cases he : r.edge <;>
      simp [batchConsumesCreated.go, he, ih, List.pairwise_cons] <;> grind

/-- Every scan refusal is the existing missing-input-holding reason. -/
theorem created_scan_reason (created : List Key) (batch : List Request) :
    batchConsumesCreated.go created batch = none ∨
      batchConsumesCreated.go created batch = some "token-missing" := by
  induction batch generalizing created with
  | nil => exact Or.inl rfl
  | cons r rs ih =>
    simp only [batchConsumesCreated.go]
    split
    · exact Or.inr rfl
    · exact ih _

/-- A successful batch passes the created-holding scan as well as its steps. -/
theorem foldBatch_scan (s : RegistryState) (batch : List Request) (t : Result)
    (h : foldBatch s batch = .ok t) : batchConsumesCreated batch = none := by
  obtain ⟨hne, ha⟩ := foldBatch_inv s batch t h
  unfold foldBatch at h
  simp only [show batch.isEmpty = false by simpa using hne, Bool.false_eq_true,
    if_false, ha, bind, Except.bind, pure, Except.pure] at h
  split at h
  · cases hc : batchConsumesCreated batch <;> simp_all
  · cases h

/-- A terminal leaf survives a whole fold. -/
theorem foldActions_preserves_terminal (s : RegistryState) (batch : List Action) (t : Result)
    (key : Key) (hterm : trieGet s.trie key = .known .terminal)
    (h : foldActions s batch = .ok t) : trieGet t.state.trie key = .known .terminal := by
  induction batch generalizing s t with
  | nil =>
    unfold foldActions at h
    have : emptyResult s = t := by injection h
    rw [← this]; exact hterm
  | cons b bs ih =>
    unfold foldActions at h
    simp only [bind, Except.bind, pure, Except.pure] at h
    cases hs : step s b with
    | error e => rw [hs] at h; exact nomatch h
    | ok m =>
      rw [hs] at h
      simp only [bind, Except.bind, pure, Except.pure] at h
      cases hr : foldActions m.state bs with
      | error e => rw [hr] at h; exact nomatch h
      | ok r =>
        rw [hr] at h
        simp only [bind, Except.bind, pure, Except.pure] at h
        have hEq : combineResults m r = t := by injection h
        have h1 := step_preserves_terminal s b m key hterm hs
        rw [← hEq]
        exact ih m.state r h1 hr

/-- An edge cannot introduce an active holding at any key except its insertion key. -/
theorem active_holding_origin (s : RegistryState) (r : Request) (key : Key)
    (h : (applyEdge s r).state.held.any (fun x => x.key == key && x.kind == .active) = true) :
    (r.edge = .insertActive ∧ r.key = key) ∨
      s.held.any (fun x => x.key == key && x.kind == .active) = true := by
  cases he : r.edge <;> simp [applyEdge, he, List.any_eq_true] at h ⊢ <;> grind

/-- Without an insertion before a same-key termination, sequentially admitted
terminations draw their active holding from the starting state. -/
theorem foldActions_live_burns (s : RegistryState) (batch : List Request) (t : Result)
    (h : foldActions s batch = .ok t)
    (hp : batch.Pairwise (fun a b => a.edge = .insertActive →
      b.edge = .updateTerminal → a.key ≠ b.key)) :
    ∀ r ∈ batch, r.edge = .updateTerminal →
      s.held.any (fun x => x.key == r.key && x.kind == .active) = true := by
  induction batch generalizing s t with
  | nil => simp
  | cons b bs ih =>
    obtain ⟨hhead, htail⟩ := List.pairwise_cons.mp hp
    cases hs : step s b with
    | error why => simp [foldActions, hs, bind, Except.bind] at h
    | ok m =>
      cases ht : foldActions m.state bs with
      | error why => simp [foldActions, hs, ht, bind, Except.bind, Functor.map, Except.map] at h
      | ok rest =>
        obtain ⟨href, hm⟩ := step_eq_ok s b m hs
        intro r hmem hr
        rcases List.mem_cons.mp hmem with heq | hmem
        · subst r
          obtain ⟨ap, hap, hpol, hadm, hc⟩ := (refusal_none_iff s b).mp href
          rcases hc with ⟨hi, _⟩ | ⟨_, _, held⟩
          · simp [hr] at hi
          · exact held
        · have held := ih m.state rest ht htail r hmem hr
          rw [hm] at held
          rcases active_holding_origin s b r.key held with ⟨hi, hk⟩ | old
          · exact False.elim (hhead r hmem hi hr hk)
          · exact old

/-- A distinct-key action leaves every admission input for another request unchanged. -/
theorem refusal_after_distinct (s : RegistryState) (a b : Request) (hk : a.key ≠ b.key) :
    refusal (applyEdge s a).state b = refusal s b := by
  have held : ∀ (hs : List Holding),
      (hs.filter (fun x => !(x.key == a.key && x.kind == .active))).any
          (fun x => x.key == b.key && x.kind == .active) =
        hs.any (fun x => x.key == b.key && x.kind == .active) := by
    intro hs
    apply Bool.eq_iff_iff.mpr
    simp only [List.any_eq_true, List.mem_filter, Bool.and_eq_true, beq_iff_eq]
    grind
  cases he : a.edge <;>
    simp only [applyEdge, he, refusal, admitsFor,
      trieGet_set_of_ne _ _ _ _ hk.symm, held, List.any_cons] <;> simp [hk]

/-- Individually admitted distinct-key requests also admit in sequence. -/
theorem foldActions_independent (s : RegistryState) (batch : List Request)
    (hp : batch.Pairwise (fun a b => a.key ≠ b.key))
    (ha : ∀ r ∈ batch, ∃ t, step s r = .ok t) :
    ∃ t, foldActions s batch = .ok t := by
  induction batch generalizing s with
  | nil => exact ⟨emptyResult s, rfl⟩
  | cons b bs ih =>
    obtain ⟨hhead, htail⟩ := List.pairwise_cons.mp hp
    obtain ⟨m, hm⟩ := ha b (by simp)
    obtain ⟨href, heffect⟩ := step_eq_ok s b m hm
    have hrest : ∀ r ∈ bs, ∃ t, step m.state r = .ok t := by
      intro r hr
      obtain ⟨u, hu⟩ := ha r (by simp [hr])
      obtain ⟨hrule, _⟩ := step_eq_ok s r u hu
      refine ⟨applyEdge m.state r, ?_⟩
      apply ok_of_refusal
      rw [heffect, refusal_after_distinct s b r (hhead r hr)]
      exact hrule
    obtain ⟨rest, hfold⟩ := ih m.state htail hrest
    exact ⟨combineResults m rest, by simp [foldActions, hm, hfold, bind, Except.bind, pure, Except.pure]⟩

/-- Pointwise correct edge claims sum to the actual keyed mint. -/
theorem batch_claims_agree (batch : List Request)
    (h : ∀ r ∈ batch, assetSame (requestClaim r) (assetDelta r) = true) :
    assetSame (claimedMint batch) (actualMint batch) = true := by
  apply (assetSame_iff _ _).mpr
  intro x
  have sums : ∀ (bs : List Request) (a b : List (Asset × Int)),
      (∀ r ∈ bs, assetSame (requestClaim r) (assetDelta r) = true) →
      assetKind a x = assetKind b x →
      assetKind (bs.foldl (fun acc r => assetPlus acc (requestClaim r)) a) x =
      assetKind (bs.foldl (fun acc r => assetPlus acc (assetDelta r)) b) x := by
    intro bs
    induction bs with
    | nil => intro a b _ he; exact he
    | cons r rs ih =>
      intro a b hh he
      apply ih
      · intro q hq; exact hh q (by simp [hq])
      · rw [assetKind_plus, assetKind_plus, he, ((assetSame_iff _ _).mp (hh r (by simp))) x]
  exact sums batch [] [] h rfl


end Singular
