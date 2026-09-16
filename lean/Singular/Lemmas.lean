import Singular.Model

/-! Trie and counting lemmas, per-edge effects, and the statements' shared
characterizations. Nothing here is a statement about the protocol; these are
the bookkeeping lemmas. -/

namespace Singular

/-! ### Filter algebra -/

/-- A filter that every `q`-member satisfies commutes past `q`. -/
theorem filter_filter_congr {α} (l : List α) (p q : α → Bool)
    (h : ∀ x, q x = true → p x = true) :
    (l.filter p).filter q = l.filter q := by
  induction l with
  | nil => simp
  | cons x xs ih =>
    by_cases hq : q x
    · have hp : p x = true := h x hq
      simp only [List.filter_cons_of_pos hq, List.filter_cons_of_pos hp]
      exact congrArg (fun l => x :: l) ih
    · by_cases hp : p x
      · simp only [List.filter_cons_of_pos hp, List.filter_cons_of_neg hq,
          List.filter_cons_of_neg hq]
        exact ih
      · simp only [List.filter_cons_of_neg hp, List.filter_cons_of_neg hq]
        exact ih

/-- A `q`-member never survives a filter whose predicate rejects it. -/
theorem filter_filter_none {α} (l : List α) (p q : α → Bool)
    (h : ∀ x, q x = true → p x = false) :
    (l.filter p).filter q = [] := by
  induction l with
  | nil => simp
  | cons x xs ih =>
    by_cases hp : p x
    · have hq : ¬ q x := by
        intro hc
        simp [h x hc] at hp
      simp only [List.filter_cons_of_pos hp, List.filter_cons_of_neg hq]
      exact ih
    · simp only [List.filter_cons_of_neg hp]
      exact ih

/-! ### Trie reading -/

@[simp] theorem trieGet_set_eq (t : Trie) (k : Key) (l : Leaf) :
    trieGet (trieSet t k l) k = l := by
  simp [trieGet, trieSet]

theorem filter_key_ne (t : Trie) (k k' : Key) (l : Leaf) (h : k' ≠ k) :
    (trieSet t k l).filter (·.1 == k') = t.filter (·.1 == k') := by
  have hne : (k == k') = false := by simpa using h.symm
  simp only [trieSet, List.filter_cons, if_neg (show ¬((k == k') = true) from by simpa using hne)]
  exact filter_filter_congr _ _ _ (by
    intro x hx
    have hx1 : x.1 = k' := by simpa using hx
    exact show (x.1 != k) = true by rw [hx1]; simpa using h)

theorem trieGet_set_of_ne (t : Trie) (k k' : Key) (l : Leaf) (h : k' ≠ k) :
    trieGet (trieSet t k l) k' = trieGet t k' := by
  simp only [trieGet]
  rw [filter_key_ne t k k' l h]

/-! ### Counting -/

/-- Consing a holding changes a count only at the consed key and kind. -/
theorem countHeld_cons (held : List Holding) (h : Holding) (kk : TokenKind) (key : Key) :
    ((h :: held).filter fun x => x.key == key && x.kind == kk).length =
      if h.key == key && h.kind == kk
      then (held.filter fun x => x.key == key && x.kind == kk).length + 1
      else (held.filter fun x => x.key == key && x.kind == kk).length := by
  by_cases hp : h.key == key && h.kind == kk
  · simp [hp, List.filter_cons_of_pos]
  · simp [hp, List.filter_cons_of_neg]

/-- Nothing of a key and kind survives a filter that removed that exact pair. -/
theorem countHeld_filter_zero (held : List Holding) (a : Key) (kk : TokenKind) :
    ((held.filter fun x => !(x.key == a && x.kind == kk)).filter
        fun x => x.key == a && x.kind == kk).length = 0 := by
  have hnone := filter_filter_none (held : List Holding)
    (fun x => !(x.key == a && x.kind == kk)) (fun x => x.key == a && x.kind == kk)
    (by intro x hx; simpa using hx)
  rw [hnone]
  simp

/-- Filtering one key out preserves every other key's holding count. -/
theorem countHeld_filter_out (held : List Holding) (a : Key) (kk : TokenKind) (key : Key)
    (h : key ≠ a) :
    ((held.filter fun x => x.key != a).filter fun x => x.key == key && x.kind == kk).length =
      (held.filter fun x => x.key == key && x.kind == kk).length := by
  have hcongr : (held.filter fun x => x.key != a).filter
      (fun x => x.key == key && x.kind == kk) =
      held.filter (fun x => x.key == key && x.kind == kk) :=
    filter_filter_congr _ _ _ (by
      intro x hx
      have hx1 : x.key = key := by
        simpa using (Bool.and_eq_true_iff.mp hx).1
      exact show (x.key != a) = true by rw [hx1]; simpa using h)
  rw [hcongr]

/-- Consing a custody entry changes the census only at the consed key. -/
theorem countCustody_cons (custody : List Custody) (c : Custody) (key : Key) :
    ((c :: custody).filter (·.key == key)).length =
      if c.key == key then (custody.filter (·.key == key)).length + 1
      else (custody.filter (·.key == key)).length := by
  by_cases hp : c.key == key
  · simp [hp, List.filter_cons_of_pos]
  · simp [hp, List.filter_cons_of_neg]

/-- Filtering one key out preserves every other key's custody census. -/
theorem countCustody_filter_out (custody : List Custody) (a : Key) (key : Key)
    (h : key ≠ a) :
    ((custody.filter (·.key != a)).filter (·.key == key)).length =
      (custody.filter (·.key == key)).length := by
  have hcongr : (custody.filter (·.key != a)).filter (·.key == key) =
      custody.filter (·.key == key) :=
    filter_filter_congr _ _ _ (by
      intro x hx
      have hx1 : x.key = key := by simpa using hx
      exact show (x.key != a) = true by rw [hx1]; simpa using h)
  rw [hcongr]

theorem countCustody_filter_zero (custody : List Custody) (a : Key) :
    ((custody.filter (·.key != a)).filter (·.key == a)).length = 0 := by
  have hnone := filter_filter_none (custody : List Custody)
    (fun x => x.key != a) (fun x => x.key == a)
    (by intro x hx; simpa using hx)
  rw [hnone]
  simp

/-! ### Step and effects -/

theorem step_eq_ok (s : RegistryState) (a : Action) (t : Result)
    (h : step s a = .ok t) : refusal s a = none ∧ t = applyEdge s a := by
  unfold step at h
  cases hr : refusal s a with
  | some why => rw [hr] at h; simp at h
  | none =>
    rw [hr] at h
    simp at h
    exact ⟨rfl, h.symm⟩

theorem ok_of_refusal (s : RegistryState) (a : Action) (h : refusal s a = none) :
    step s a = .ok (applyEdge s a) := by
  unfold step; rw [h]

theorem error_of_refusal (s : RegistryState) (a : Action) (why : String)
    (h : refusal s a = some why) : step s a = .error why := by
  unfold step; rw [h]

/-- Effects of an admitted `insertAbsent`. -/
theorem applyEdge_insertAbsent (s : RegistryState) (a : Action) (he : a.edge = .insertAbsent) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .absent) ∧
    (applyEdge s a).state.config.root = rootOf (trieSet s.trie a.key (.known .absent)) ∧
    (applyEdge s a).state.custody =
      { key := a.key, refundAddress := a.refundAddress, value := a.deposit } :: s.custody ∧
    (applyEdge s a).state.held = s.held ∧
    (applyEdge s a).mint = [(.absent, 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta]

/-- Effects of an admitted `insertActive`. -/
theorem applyEdge_insertActive (s : RegistryState) (a : Action) (he : a.edge = .insertActive) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .active) ∧
    (applyEdge s a).state.config.root = rootOf (trieSet s.trie a.key (.known .active)) ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      { key := a.key, kind := .active, output := a.output } :: s.held ∧
    (applyEdge s a).mint = [(.active, 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta]

/-- Effects of an admitted `updateActive`. -/
theorem applyEdge_updateActive (s : RegistryState) (a : Action) (he : a.edge = .updateActive)
    (c : Custody) (hc : s.custody.find? (·.key == a.key) = some c) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .active) ∧
    (applyEdge s a).state.config.root = rootOf (trieSet s.trie a.key (.known .active)) ∧
    (applyEdge s a).state.custody = s.custody.filter (·.key != a.key) ∧
    (applyEdge s a).state.held =
      { key := a.key, kind := .active, output := a.output } :: s.held ∧
    (applyEdge s a).mint = [(.absent, -1), (.active, 1)] ∧
    (applyEdge s a).paid = [(c.refundAddress, c.value)] := by
  simp [applyEdge, he, hc, delta]

/-- Effects of an admitted `updateTerminal`. -/
theorem applyEdge_updateTerminal (s : RegistryState) (a : Action) (he : a.edge = .updateTerminal) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .terminal) ∧
    (applyEdge s a).state.config.root = rootOf (trieSet s.trie a.key (.known .terminal)) ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) ∧
    (applyEdge s a).mint = [(.active, -1)] ∧ (applyEdge s a).paid = [] := by
  have h1 : (applyEdge s a).state.trie = trieSet s.trie a.key (.known .terminal) := by
    simp only [applyEdge, he]
  have h2 : (applyEdge s a).state.config.root =
      rootOf (trieSet s.trie a.key (.known .terminal)) := by
    simp only [applyEdge, he]
  have h3 : (applyEdge s a).state.custody = s.custody := by
    simp only [applyEdge, he]
  have h4 : (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) := by
    simp only [applyEdge, he]
  have h5 : (applyEdge s a).mint = [(.active, -1)] := by simp [applyEdge, he, delta]
  have h6 : (applyEdge s a).paid = [] := by simp [applyEdge, he]
  exact ⟨h1, h2, h3, h4, h5, h6⟩

/-- Effects of an admitted `deleteAbsent`. -/
theorem applyEdge_deleteAbsent (s : RegistryState) (a : Action) (he : a.edge = .deleteAbsent)
    (c : Custody) (hc : s.custody.find? (·.key == a.key) = some c) :
    (applyEdge s a).state.trie = trieSet s.trie a.key .unknown ∧
    (applyEdge s a).state.config.root = rootOf (trieSet s.trie a.key .unknown) ∧
    (applyEdge s a).state.custody = s.custody.filter (·.key != a.key) ∧
    (applyEdge s a).state.held = s.held ∧
    (applyEdge s a).mint = [(.absent, -1)] ∧
    (applyEdge s a).paid = [(c.refundAddress, c.value)] := by
  simp [applyEdge, he, hc, delta]

/-- Effects of an admitted `deleteActive`. -/
theorem applyEdge_deleteActive (s : RegistryState) (a : Action) (he : a.edge = .deleteActive) :
    (applyEdge s a).state.trie = trieSet s.trie a.key .unknown ∧
    (applyEdge s a).state.config.root = rootOf (trieSet s.trie a.key .unknown) ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) ∧
    (applyEdge s a).mint = [(.active, -1)] ∧ (applyEdge s a).paid = [] := by
  have h1 : (applyEdge s a).state.trie = trieSet s.trie a.key .unknown := by
    simp only [applyEdge, he]
  have h2 : (applyEdge s a).state.config.root =
      rootOf (trieSet s.trie a.key .unknown) := by
    simp only [applyEdge, he]
  have h3 : (applyEdge s a).state.custody = s.custody := by
    simp only [applyEdge, he]
  have h4 : (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) := by
    simp only [applyEdge, he]
  have h5 : (applyEdge s a).mint = [(.active, -1)] := by simp [applyEdge, he, delta]
  have h6 : (applyEdge s a).paid = [] := by simp [applyEdge, he]
  exact ⟨h1, h2, h3, h4, h5, h6⟩

/-- Effects of an admitted `witnessTerminal`: the leaf, the root and custody do
not move. -/
theorem applyEdge_witnessTerminal (s : RegistryState) (a : Action)
    (he : a.edge = .witnessTerminal) :
    (applyEdge s a).state.trie = s.trie ∧
    (applyEdge s a).state.config = s.config ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      { key := a.key, kind := .terminal, output := a.output } :: s.held ∧
    (applyEdge s a).mint = [(.terminal, 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta]

/-- A present-key flag yields a findable custody entry with that key. -/
theorem custody_entry_of_present_aux (key : Key) (custody : List Custody)
    (hp : custody.any (·.key == key) = true) :
    ∃ c, custody.find? (·.key == key) = some c ∧ c.key = key := by
  induction custody with
  | nil => exfalso; simp at hp
  | cons x xs ih =>
    by_cases hx : x.key = key
    · refine ⟨x, ?_, hx⟩
      simp [List.find?, show (x.key == key) = true from by simpa using hx]
    · have hb : (x.key == key) = false := by simpa using hx
      simp only [List.any_cons, Bool.or_eq_true, hb, Bool.false_or] at hp
      obtain ⟨c, hc, hkey⟩ := ih hp
      refine ⟨c, ?_, hkey⟩
      simp only [List.find?]
      rw [hb]
      exact hc

theorem custody_entry_of_present (s : RegistryState) (key : Key)
    (hp : s.custody.any (·.key == key) = true) :
    ∃ c, s.custody.find? (·.key == key) = some c ∧ c.key = key :=
  custody_entry_of_present_aux key s.custody hp

/-- A present-flag for an active token yields a findable holding entry. -/
theorem holding_entry_of_present_aux (key : Key) (held : List Holding)
    (hp : held.any (fun x => x.key == key && x.kind == .active) = true) :
    ∃ h, held.find? (fun x => x.key == key && x.kind == .active) = some h ∧
      h.key = key ∧ h.kind = .active := by
  induction held with
  | nil => exfalso; simp at hp
  | cons x xs ih =>
    by_cases hx : x.key = key ∧ x.kind = .active
    · have hcond : (x.key == key && x.kind == .active) = true := by
        have h1 : (x.key == key) = true := by simpa using hx.1
        have h2 : (x.kind == .active) = true := by rw [hx.2]; rfl
        rw [h1, h2]
        rfl
      refine ⟨x, ?_, hx.1, hx.2⟩
      simp only [List.find?]
      rw [hcond]
    · have hb : (x.key == key && x.kind == .active) = false := by
        by_cases h1 : x.key = key
        · have h2 : x.kind ≠ .active := fun e => hx ⟨h1, e⟩
          have h2f : (x.kind == .active) = false := by
            cases hc : x.kind with
            | active => exact absurd hc h2
            | _ => rfl
          rw [show (x.key == key) = true from by simpa using h1, h2f]
          rfl
        · rw [show (x.key == key) = false from by simpa using h1]
          rfl
      simp only [List.any_cons, Bool.or_eq_true, hb, Bool.false_or] at hp
      obtain ⟨h, hh, h1, h2⟩ := ih hp
      refine ⟨h, ?_, h1, h2⟩
      simp only [List.find?]
      rw [hb]
      exact hh

theorem holding_entry_of_present (s : RegistryState) (key : Key)
    (hp : s.held.any (fun x => x.key == key && x.kind == .active) = true) :
    ∃ h, s.held.find? (fun x => x.key == key && x.kind == .active) = some h ∧
      h.key = key ∧ h.kind = .active :=
  holding_entry_of_present_aux key s.held hp

/-- The fold as a step chain: each request applies exactly once, in order. -/
inductive Folds : RegistryState → List Request → Result → Prop where
  | done (s : RegistryState) : Folds s [] (emptyResult s)
  | cons (s : RegistryState) (b : Request) (bs : List Request) (m r : Result) :
      step s b = .ok m → Folds m.state bs r →
      Folds s (b :: bs) (combineResults m r)

/-! ### The admitted-step characterization and the one-step invariant -/

/-- A step is admitted iff either it is a verified read, or it is a tree edge
whose approval has the right policy and a tuple matching the request
(D-APPROVAL), whose R2 row matches the before-leaf, and whose custody or active
token is present when the row consumes one. This is the complement of the R2
table, stated once, for every proof to draw on. -/

theorem refusal_none_iff (s : RegistryState) (a : Action) : refusal s a = none ↔
    (a.edge = .witnessTerminal ∧ readAt s 0 a.key .terminal = true) ∨
    (∃ ap, a.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      admitsFor s.config a a.approval = true ∧
      ((a.edge = .insertAbsent ∧ trieGet s.trie a.key = .unknown) ∨
       (a.edge = .insertActive ∧ trieGet s.trie a.key = .unknown) ∨
       (a.edge = .updateActive ∧ trieGet s.trie a.key = .known .absent ∧
         s.custody.any (·.key == a.key) = true) ∨
       (a.edge = .updateTerminal ∧ trieGet s.trie a.key = .known .active ∧
         s.held.any (fun x => x.key == a.key && x.kind == .active) = true) ∨
       (a.edge = .deleteAbsent ∧ trieGet s.trie a.key = .known .absent ∧
         s.custody.any (·.key == a.key) = true) ∨
       (a.edge = .deleteActive ∧ trieGet s.trie a.key = .known .active ∧
         s.held.any (fun x => x.key == a.key && x.kind == .active) = true))) := by
  sorry

/-- Consistency survives every accepted step. -/

theorem step_ok_consistent (s : RegistryState) (a : Action) (t : Result)
    (hc : Consistent s) (h : step s a = .ok t) : Consistent t.state := by
  sorry

theorem reachable_consistent (s : RegistryState) (h : Reachable s) : Consistent s := by
  induction h with
  | initial c =>
    exact ⟨rfl,
      fun key => by simp [kindCount, trieGet],
      fun key => by simp [kindCount, trieGet],
      fun key => by simp [custodyCount, trieGet],
      fun key => by simp [custodyCount, trieGet],
      fun h0 hm _ => absurd hm (by simp),
      fun c hm => absurd hm (by simp),
      fun c₁ h1 _ _ => absurd h1 (by simp)⟩
  | next _ hok ih => exact step_ok_consistent _ _ _ ih hok

end Singular
