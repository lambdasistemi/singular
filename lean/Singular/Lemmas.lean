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

/-- An erased key reads `unknown`: the lookup default, not a stored entry. -/
@[simp] theorem trieGet_erase_eq (t : Trie) (k : Key) :
    trieGet (trieErase t k) k = .unknown := by
  have hnone : (trieErase t k).filter (·.1 == k) = [] :=
    filter_filter_none t _ _ (by
      intro x hx
      have hx1 : x.1 = k := by simpa using hx
      simp [hx1])
  simp only [trieGet, hnone]
  rfl

theorem trieGet_erase_of_ne (t : Trie) (k k' : Key) (h : k' ≠ k) :
    trieGet (trieErase t k) k' = trieGet t k' := by
  simp only [trieGet, trieErase]
  rw [filter_filter_congr _ _ _ (by
    intro x hx
    have hx1 : x.1 = k' := by simpa using hx
    exact show (x.1 != k) = true by rw [hx1]; simpa using h)]

/-- Every pair `trieSet` stores is the written pair or was already stored. -/
theorem mem_trieSet (t : Trie) (k : Key) (l : Leaf) (p : Key × Leaf)
    (hp : p ∈ trieSet t k l) : p = (k, l) ∨ p ∈ t := by
  simp only [trieSet, List.mem_cons] at hp
  rcases hp with hp | hp
  · exact Or.inl hp
  · exact Or.inr (List.mem_filter.mp hp).1

/-- Every pair `trieErase` keeps was already stored. -/
theorem mem_trieErase (t : Trie) (k : Key) (p : Key × Leaf)
    (hp : p ∈ trieErase t k) : p ∈ t :=
  (List.mem_filter.mp hp).1

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

/-- Removing one key's active token preserves every other key's census. The
predicate differs from `countHeld_filter_out`'s: this is the filter the
`updateTerminal` and `deleteActive` rows actually apply. -/
theorem countHeld_filter_active_out (held : List Holding) (a : Key) (kk : TokenKind) (key : Key)
    (h : key ≠ a) :
    ((held.filter fun x => !(x.key == a && x.kind == .active)).filter
        fun x => x.key == key && x.kind == kk).length =
      (held.filter fun x => x.key == key && x.kind == kk).length := by
  have hcongr : (held.filter fun x => !(x.key == a && x.kind == .active)).filter
      (fun x => x.key == key && x.kind == kk) =
      held.filter (fun x => x.key == key && x.kind == kk) :=
    filter_filter_congr _ _ _ (by
      intro x hx
      have hx1 : x.key = key := by
        simpa using (Bool.and_eq_true_iff.mp hx).1
      simp [hx1, h])
  rw [hcongr]

/-- Nothing of a key survives the active-token filter at that key. -/
theorem countHeld_filter_active_zero (held : List Holding) (a : Key) :
    ((held.filter fun x => !(x.key == a && x.kind == .active)).filter
        fun x => x.key == a && x.kind == .active).length = 0 := by
  have hnone := filter_filter_none (held : List Holding)
    (fun x => !(x.key == a && x.kind == .active))
    (fun x => x.key == a && x.kind == .active)
    (by intro x hx; simpa using hx)
  rw [hnone]; simp

/-- Filtering never increases a census: the twice-filtered list is a sublist. -/
theorem countHeld_filter_active_le (held : List Holding) (a : Key) (kk : TokenKind) (key : Key) :
    ((held.filter fun x => !(x.key == a && x.kind == .active)).filter
        fun x => x.key == key && x.kind == kk).length ≤
      (held.filter fun x => x.key == key && x.kind == kk).length :=
  (List.Sublist.filter _ (List.filter_sublist)).length_le

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
    (applyEdge s a).state.config = { s.config with root := rootOf (trieSet s.trie a.key (.known .absent)) } ∧
    (applyEdge s a).state.custody =
      { key := a.key, refundAddress := a.refundAddress, value := a.deposit } :: s.custody ∧
    (applyEdge s a).state.held = s.held ∧
    (applyEdge s a).mint = [((.absent, a.key), 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta, assetDelta]

/-- Effects of an admitted `insertActive`. -/
theorem applyEdge_insertActive (s : RegistryState) (a : Action) (he : a.edge = .insertActive) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .active) ∧
    (applyEdge s a).state.config = { s.config with root := rootOf (trieSet s.trie a.key (.known .active)) } ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      { key := a.key, kind := .active, output := a.output } :: s.held ∧
    (applyEdge s a).mint = [((.active, a.key), 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta, assetDelta]

/-- Effects of an admitted `updateActive`. -/
theorem applyEdge_updateActive (s : RegistryState) (a : Action) (he : a.edge = .updateActive)
    (c : Custody) (hc : s.custody.find? (·.key == a.key) = some c) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .active) ∧
    (applyEdge s a).state.config = { s.config with root := rootOf (trieSet s.trie a.key (.known .active)) } ∧
    (applyEdge s a).state.custody = s.custody.filter (·.key != a.key) ∧
    (applyEdge s a).state.held =
      { key := a.key, kind := .active, output := a.output } :: s.held ∧
    (applyEdge s a).mint = [((.absent, a.key), -1), ((.active, a.key), 1)] ∧
    (applyEdge s a).paid = [(c.refundAddress, c.value)] := by
  simp [applyEdge, he, hc, delta, assetDelta]

/-- Effects of an admitted `updateTerminal`. -/
theorem applyEdge_updateTerminal (s : RegistryState) (a : Action) (he : a.edge = .updateTerminal) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .terminal) ∧
    (applyEdge s a).state.config = { s.config with root := rootOf (trieSet s.trie a.key (.known .terminal)) } ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) ∧
    (applyEdge s a).mint = [((.active, a.key), -1)] ∧ (applyEdge s a).paid = [] := by
  have h1 : (applyEdge s a).state.trie = trieSet s.trie a.key (.known .terminal) := by
    simp only [applyEdge, he]
  have h2 : (applyEdge s a).state.config =
      { s.config with root := rootOf (trieSet s.trie a.key (.known .terminal)) } := by
    simp only [applyEdge, he]
  have h3 : (applyEdge s a).state.custody = s.custody := by
    simp only [applyEdge, he]
  have h4 : (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) := by
    simp only [applyEdge, he]
  have h5 : (applyEdge s a).mint = [((.active, a.key), -1)] := by simp [applyEdge, he, delta, assetDelta]
  have h6 : (applyEdge s a).paid = [] := by simp [applyEdge, he]
  exact ⟨h1, h2, h3, h4, h5, h6⟩

/-- Effects of an admitted `deleteAbsent`. -/
theorem applyEdge_deleteAbsent (s : RegistryState) (a : Action) (he : a.edge = .deleteAbsent)
    (c : Custody) (hc : s.custody.find? (·.key == a.key) = some c) :
    (applyEdge s a).state.trie = trieErase s.trie a.key ∧
    (applyEdge s a).state.config = { s.config with root := rootOf (trieErase s.trie a.key) } ∧
    (applyEdge s a).state.custody = s.custody.filter (·.key != a.key) ∧
    (applyEdge s a).state.held = s.held ∧
    (applyEdge s a).mint = [((.absent, a.key), -1)] ∧
    (applyEdge s a).paid = [(c.refundAddress, c.value)] := by
  simp [applyEdge, he, hc, delta, assetDelta]

/-- Effects of an admitted `deleteActive`. -/
theorem applyEdge_deleteActive (s : RegistryState) (a : Action) (he : a.edge = .deleteActive) :
    (applyEdge s a).state.trie = trieErase s.trie a.key ∧
    (applyEdge s a).state.config = { s.config with root := rootOf (trieErase s.trie a.key) } ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) ∧
    (applyEdge s a).mint = [((.active, a.key), -1)] ∧ (applyEdge s a).paid = [] := by
  have h1 : (applyEdge s a).state.trie = trieErase s.trie a.key := by
    simp only [applyEdge, he]
  have h2 : (applyEdge s a).state.config =
      { s.config with root := rootOf (trieErase s.trie a.key) } := by
    simp only [applyEdge, he]
  have h3 : (applyEdge s a).state.custody = s.custody := by
    simp only [applyEdge, he]
  have h4 : (applyEdge s a).state.held =
      (s.held.filter fun h => !(h.key == a.key && h.kind == .active)) := by
    simp only [applyEdge, he]
  have h5 : (applyEdge s a).mint = [((.active, a.key), -1)] := by simp [applyEdge, he, delta, assetDelta]
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
    (applyEdge s a).mint = [((.terminal, a.key), 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta, assetDelta]

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
  cases hb : trieGet s.trie a.key <;>
    (try (rename_i st; cases st)) <;>
    cases hE : a.edge <;> cases hap : a.approval <;>
    cases hcu : s.custody.any (·.key == a.key) <;>
    cases hac : s.held.any (fun x => x.key == a.key && x.kind == .active) <;>
    simp +decide [refusal, hE, hb, hap, admitsFor, hcu, hac] <;>
    grind

/-- Consistency survives every accepted step. -/

theorem step_ok_consistent (s : RegistryState) (a : Action) (t : Result)
    (hc : Consistent s) (h : step s a = .ok t) : Consistent t.state := by
  obtain ⟨href, ht⟩ := step_eq_ok s a t h
  subst ht
  obtain ⟨hroot, hA1, hA2, hC1, hC2, hTerm, hCleaf, hCuniq⟩ := hc
  rcases (refusal_none_iff s a).mp href with ⟨he, hr⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
  · -- witnessTerminal: only a terminal holding is added.
    obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_witnessTerminal s a he
    have hterm : trieGet s.trie a.key = .known .terminal := by
      unfold readAt at hr
      simp only [Bool.and_eq_true, beq_iff_eq] at hr
      exact hr.1.2
    refine ⟨by rw [hcfg, htrie]; exact hroot, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro key
      rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
        simp only [kindCount, hheld, countHeld_cons]; simp, htrie]
      exact hA1 key
    · intro key
      rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
        simp only [kindCount, hheld, countHeld_cons]; simp]
      exact hA2 key
    · intro key; rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
        simp [custodyCount, hcust], htrie]; exact hC1 key
    · intro key; rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
        simp [custodyCount, hcust]]; exact hC2 key
    · intro hh hmem hk
      rw [htrie]
      rw [hheld] at hmem
      rcases List.mem_cons.mp hmem with rfl | hmem'
      · exact hterm
      · exact hTerm hh hmem' hk
    · intro c hmem; rw [htrie]; rw [hcust] at hmem; exact hCleaf c hmem
    · intro c₁ h1 c₂ h2 hk; rw [hcust] at h1 h2; exact hCuniq c₁ h1 c₂ h2 hk
  · rcases hcase with ⟨he, hb⟩ | ⟨he, hb⟩ | ⟨he, hb, hcu⟩ | ⟨he, hb, hac⟩ |
        ⟨he, hb, hcu⟩ | ⟨he, hb, hac⟩
    · -- insertAbsent: Unknown → Known Absent, +1 absent token in cage custody
      obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_insertAbsent s a he
      have hcz : custodyCount s a.key = 0 := by
        have hne : custodyCount s a.key ≠ 1 := fun hEq => by
          rw [(hC1 a.key).mp hEq] at hb; exact Leaf.noConfusion hb
        have := hC2 a.key; omega
      have hnotin : ∀ c ∈ s.custody, c.key ≠ a.key := by
        intro c hmem hEq
        have := hCleaf c hmem
        rw [hEq, hb] at this; exact Leaf.noConfusion this
      refine ⟨by rw [hcfg, htrie], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro key
        rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
          simp [kindCount, hheld]]
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq]
          constructor
          · intro hEq; rw [(hA1 a.key).mp hEq] at hb; exact Leaf.noConfusion hb
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk]; exact hA1 key
      · intro key
        rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
          simp [kindCount, hheld]]
        exact hA2 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq,
            show custodyCount (applyEdge s a).state a.key = custodyCount s a.key + 1 from by
              simp [custodyCount, hcust, countCustody_cons]]
          simp [hcz]
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk,
            show custodyCount (applyEdge s a).state key = custodyCount s key from by
              simp [custodyCount, hcust, countCustody_cons,
                show (a.key == key) = false from by simpa using fun hh => hk hh.symm]]
          exact hC1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show custodyCount (applyEdge s a).state a.key = custodyCount s a.key + 1 from by
            simp [custodyCount, hcust, countCustody_cons]]
          omega
        · rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
            simp [custodyCount, hcust, countCustody_cons,
              show (a.key == key) = false from by simpa using fun hh => hk hh.symm]]
          exact hC2 key
      · intro hh hmem hk
        rw [hheld] at hmem
        have hne : hh.key ≠ a.key := by
          intro hEq
          have := hTerm hh hmem hk
          rw [hEq, hb] at this; exact Leaf.noConfusion this
        rw [htrie, trieGet_set_of_ne _ _ _ _ hne]
        exact hTerm hh hmem hk
      · intro c hmem
        rw [hcust] at hmem
        rcases List.mem_cons.mp hmem with rfl | hmem'
        · rw [htrie, trieGet_set_eq]
        · rw [htrie, trieGet_set_of_ne _ _ _ _ (hnotin c hmem')]
          exact hCleaf c hmem'
      · intro c₁ h1 c₂ h2 hk
        rw [hcust] at h1 h2
        rcases List.mem_cons.mp h1 with rfl | h1' <;> rcases List.mem_cons.mp h2 with rfl | h2'
        · rfl
        · exact absurd hk.symm (hnotin c₂ h2')
        · exact absurd hk (hnotin c₁ h1')
        · exact hCuniq c₁ h1' c₂ h2' hk
    · -- insertActive: Unknown → Known Active, +1 active token at the output
      obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_insertActive s a he
      have haz : kindCount s .active a.key = 0 := by
        have hne : kindCount s .active a.key ≠ 1 := fun hEq => by
          rw [(hA1 a.key).mp hEq] at hb; exact Leaf.noConfusion hb
        have := hA2 a.key; omega
      have hnotin : ∀ c ∈ s.custody, c.key ≠ a.key := by
        intro c hmem hEq
        have := hCleaf c hmem
        rw [hEq, hb] at this; exact Leaf.noConfusion this
      refine ⟨by rw [hcfg, htrie], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq,
            show kindCount (applyEdge s a).state .active a.key = kindCount s .active a.key + 1 from by
              simp [kindCount, hheld, countHeld_cons]]
          simp [haz]
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk,
            show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
              simp [kindCount, hheld, countHeld_cons,
                show (a.key == key) = false from by simpa using fun hh => hk hh.symm]]
          exact hA1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show kindCount (applyEdge s a).state .active a.key = kindCount s .active a.key + 1 from by
            simp [kindCount, hheld, countHeld_cons]]
          omega
        · rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
            simp [kindCount, hheld, countHeld_cons,
              show (a.key == key) = false from by simpa using fun hh => hk hh.symm]]
          exact hA2 key
      · intro key
        rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
          simp [custodyCount, hcust]]
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq]
          constructor
          · intro hEq; rw [(hC1 a.key).mp hEq] at hb; exact Leaf.noConfusion hb
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk]; exact hC1 key
      · intro key
        rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
          simp [custodyCount, hcust]]
        exact hC2 key
      · intro hh hmem hk
        rw [hheld] at hmem
        rcases List.mem_cons.mp hmem with rfl | hmem'
        · exact absurd hk (by simp)
        · have hne : hh.key ≠ a.key := by
            intro hEq
            have := hTerm hh hmem' hk
            rw [hEq, hb] at this; exact Leaf.noConfusion this
          rw [htrie, trieGet_set_of_ne _ _ _ _ hne]
          exact hTerm hh hmem' hk
      · intro c hmem
        rw [hcust] at hmem
        rw [htrie, trieGet_set_of_ne _ _ _ _ (hnotin c hmem)]
        exact hCleaf c hmem
      · intro c₁ h1 c₂ h2 hk
        rw [hcust] at h1 h2
        exact hCuniq c₁ h1 c₂ h2 hk
    · -- updateActive: Known Absent → Known Active; the absent token is consumed
      obtain ⟨c, hfind, hckey⟩ := custody_entry_of_present s a.key hcu
      obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_updateActive s a he c hfind
      have haz : kindCount s .active a.key = 0 := by
        have hne : kindCount s .active a.key ≠ 1 := fun hEq => by
          rw [(hA1 a.key).mp hEq] at hb; exact absurd hb (by decide)
        have := hA2 a.key; omega
      refine ⟨by rw [hcfg, htrie], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq,
            show kindCount (applyEdge s a).state .active a.key = kindCount s .active a.key + 1 from by
              simp [kindCount, hheld, countHeld_cons]]
          simp [haz]
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk,
            show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
              simp [kindCount, hheld, countHeld_cons,
                show (a.key == key) = false from by simpa using fun hh => hk hh.symm]]
          exact hA1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show kindCount (applyEdge s a).state .active a.key = kindCount s .active a.key + 1 from by
            simp [kindCount, hheld, countHeld_cons]]
          omega
        · rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
            simp [kindCount, hheld, countHeld_cons,
              show (a.key == key) = false from by simpa using fun hh => hk hh.symm]]
          exact hA2 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq,
            show custodyCount (applyEdge s a).state a.key = 0 from by
              simp [custodyCount, hcust, countCustody_filter_zero]]
          constructor
          · intro hEq; exact absurd hEq (by decide)
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk,
            show custodyCount (applyEdge s a).state key = custodyCount s key from by
              simpa [custodyCount, hcust] using countCustody_filter_out s.custody a.key key hk]
          exact hC1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show custodyCount (applyEdge s a).state a.key = 0 from by
            simp [custodyCount, hcust, countCustody_filter_zero]]
          omega
        · rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
            simpa [custodyCount, hcust] using countCustody_filter_out s.custody a.key key hk]
          exact hC2 key
      · intro hh hmem hk
        rw [hheld] at hmem
        rcases List.mem_cons.mp hmem with rfl | hmem'
        · exact absurd hk (by simp)
        · have hne : hh.key ≠ a.key := by
            intro hEq
            have := hTerm hh hmem' hk
            rw [hEq, hb] at this; exact absurd this (by decide)
          rw [htrie, trieGet_set_of_ne _ _ _ _ hne]
          exact hTerm hh hmem' hk
      · intro c' hmem
        rw [hcust] at hmem
        have hne : c'.key ≠ a.key := by
          intro hEq
          have := (List.mem_filter.mp hmem).2
          rw [hEq] at this; simp at this
        rw [htrie, trieGet_set_of_ne _ _ _ _ hne]
        exact hCleaf c' (List.mem_filter.mp hmem).1
      · intro c₁ h1 c₂ h2 hk
        rw [hcust] at h1 h2
        exact hCuniq c₁ (List.mem_filter.mp h1).1 c₂ (List.mem_filter.mp h2).1 hk
    · -- updateTerminal: the active token is consumed; custody is untouched
      obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_updateTerminal s a he
      refine ⟨by rw [hcfg, htrie], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq,
            show kindCount (applyEdge s a).state .active a.key = 0 from by
              simpa [kindCount, hheld] using countHeld_filter_active_zero s.held a.key]
          constructor
          · intro hEq; exact absurd hEq (by decide)
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk,
            show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
              simpa [kindCount, hheld] using
                countHeld_filter_active_out s.held a.key .active key hk]
          exact hA1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show kindCount (applyEdge s a).state .active a.key = 0 from by
            simpa [kindCount, hheld] using countHeld_filter_active_zero s.held a.key]
          omega
        · rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
            simpa [kindCount, hheld] using
              countHeld_filter_active_out s.held a.key .active key hk]
          exact hA2 key
      · intro key
        rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
          simp [custodyCount, hcust]]
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_set_eq]
          constructor
          · intro hEq; rw [(hC1 a.key).mp hEq] at hb; exact absurd hb (by decide)
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_set_of_ne _ _ _ _ hk]; exact hC1 key
      · intro key
        rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
          simp [custodyCount, hcust]]
        exact hC2 key
      · intro hh hmem hk
        rw [hheld] at hmem
        have hmem' := (List.mem_filter.mp hmem).1
        have hne : hh.key ≠ a.key := by
          intro hEq
          have := hTerm hh hmem' hk
          rw [hEq, hb] at this; exact absurd this (by decide)
        rw [htrie, trieGet_set_of_ne _ _ _ _ hne]
        exact hTerm hh hmem' hk
      · intro c hmem
        rw [hcust] at hmem
        have hne : c.key ≠ a.key := by
          intro hEq
          have := hCleaf c hmem
          rw [hEq, hb] at this; exact absurd this (by decide)
        rw [htrie, trieGet_set_of_ne _ _ _ _ hne]
        exact hCleaf c hmem
      · intro c₁ h1 c₂ h2 hk
        rw [hcust] at h1 h2
        exact hCuniq c₁ h1 c₂ h2 hk
    · -- deleteAbsent: Known Absent → Unknown; the absent token is consumed
      obtain ⟨c, hfind, hckey⟩ := custody_entry_of_present s a.key hcu
      obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_deleteAbsent s a he c hfind
      refine ⟨by rw [hcfg, htrie], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro key
        rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
          simp [kindCount, hheld]]
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_erase_eq]
          constructor
          · intro hEq; rw [(hA1 a.key).mp hEq] at hb; exact absurd hb (by decide)
          · intro hEq; exact Leaf.noConfusion hEq
        · rw [htrie, trieGet_erase_of_ne _ _ _ hk]; exact hA1 key
      · intro key
        rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
          simp [kindCount, hheld]]
        exact hA2 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_erase_eq,
            show custodyCount (applyEdge s a).state a.key = 0 from by
              simp [custodyCount, hcust, countCustody_filter_zero]]
          constructor
          · intro hEq; exact absurd hEq (by decide)
          · intro hEq; exact Leaf.noConfusion hEq
        · rw [htrie, trieGet_erase_of_ne _ _ _ hk,
            show custodyCount (applyEdge s a).state key = custodyCount s key from by
              simpa [custodyCount, hcust] using countCustody_filter_out s.custody a.key key hk]
          exact hC1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show custodyCount (applyEdge s a).state a.key = 0 from by
            simp [custodyCount, hcust, countCustody_filter_zero]]
          omega
        · rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
            simpa [custodyCount, hcust] using countCustody_filter_out s.custody a.key key hk]
          exact hC2 key
      · intro hh hmem hk
        rw [hheld] at hmem
        have hne : hh.key ≠ a.key := by
          intro hEq
          have := hTerm hh hmem hk
          rw [hEq, hb] at this; exact absurd this (by decide)
        rw [htrie, trieGet_erase_of_ne _ _ _ hne]
        exact hTerm hh hmem hk
      · intro c' hmem
        rw [hcust] at hmem
        have hne : c'.key ≠ a.key := by
          intro hEq
          have := (List.mem_filter.mp hmem).2
          rw [hEq] at this; simp at this
        rw [htrie, trieGet_erase_of_ne _ _ _ hne]
        exact hCleaf c' (List.mem_filter.mp hmem).1
      · intro c₁ h1 c₂ h2 hk
        rw [hcust] at h1 h2
        exact hCuniq c₁ (List.mem_filter.mp h1).1 c₂ (List.mem_filter.mp h2).1 hk
    · -- deleteActive: the active token is consumed; custody is untouched
      obtain ⟨htrie, hcfg, hcust, hheld, _, _⟩ := applyEdge_deleteActive s a he
      refine ⟨by rw [hcfg, htrie], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_erase_eq,
            show kindCount (applyEdge s a).state .active a.key = 0 from by
              simpa [kindCount, hheld] using countHeld_filter_active_zero s.held a.key]
          constructor
          · intro hEq; exact absurd hEq (by decide)
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_erase_of_ne _ _ _ hk,
            show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
              simpa [kindCount, hheld] using
                countHeld_filter_active_out s.held a.key .active key hk]
          exact hA1 key
      · intro key
        by_cases hk : key = a.key
        · subst hk
          rw [show kindCount (applyEdge s a).state .active a.key = 0 from by
            simpa [kindCount, hheld] using countHeld_filter_active_zero s.held a.key]
          omega
        · rw [show kindCount (applyEdge s a).state .active key = kindCount s .active key from by
            simpa [kindCount, hheld] using
              countHeld_filter_active_out s.held a.key .active key hk]
          exact hA2 key
      · intro key
        rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
          simp [custodyCount, hcust]]
        by_cases hk : key = a.key
        · subst hk
          rw [htrie, trieGet_erase_eq]
          constructor
          · intro hEq; rw [(hC1 a.key).mp hEq] at hb; exact absurd hb (by decide)
          · intro hEq; exact absurd hEq (by decide)
        · rw [htrie, trieGet_erase_of_ne _ _ _ hk]; exact hC1 key
      · intro key
        rw [show custodyCount (applyEdge s a).state key = custodyCount s key from by
          simp [custodyCount, hcust]]
        exact hC2 key
      · intro hh hmem hk
        rw [hheld] at hmem
        have hmem' := (List.mem_filter.mp hmem).1
        have hne : hh.key ≠ a.key := by
          intro hEq
          have := hTerm hh hmem' hk
          rw [hEq, hb] at this; exact absurd this (by decide)
        rw [htrie, trieGet_erase_of_ne _ _ _ hne]
        exact hTerm hh hmem' hk
      · intro c hmem
        rw [hcust] at hmem
        have hne : c.key ≠ a.key := by
          intro hEq
          have := hCleaf c hmem
          rw [hEq, hb] at this; exact absurd this (by decide)
        rw [htrie, trieGet_erase_of_ne _ _ _ hne]
        exact hCleaf c hmem
      · intro c₁ h1 c₂ h2 hk
        rw [hcust] at h1 h2
        exact hCuniq c₁ h1 c₂ h2 hk

/-- A terminal leaf survives any admitted step: every edge that would move it is
refused, and the read does not touch the trie. -/
theorem step_preserves_terminal (s : RegistryState) (a : Action) (t : Result) (key : Key)
    (hterm : trieGet s.trie key = .known .terminal) (hok : step s a = .ok t) :
    trieGet t.state.trie key = .known .terminal := by
  obtain ⟨href, ht⟩ := step_eq_ok s a t hok
  subst ht
  rcases (refusal_none_iff s a).mp href with ⟨he, _⟩ | ⟨_, _, _, _, hcase⟩
  · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_witnessTerminal s a he
    rw [h1]; exact hterm
  · have hne : a.key ≠ key := by
      rcases hcase with ⟨_, hb⟩ | ⟨_, hb⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ <;>
        (intro hEq; rw [hEq, hterm] at hb; exact absurd hb (by decide))
    rcases hcase with ⟨he, _⟩ | ⟨he, _⟩ | ⟨he, _, hpres⟩ | ⟨he, _, _⟩ | ⟨he, _, hpres⟩ | ⟨he, _, _⟩
    · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_insertAbsent s a he
      rw [h1, trieGet_set_of_ne _ _ _ _ (fun hEq => hne hEq.symm)]; exact hterm
    · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_insertActive s a he
      rw [h1, trieGet_set_of_ne _ _ _ _ (fun hEq => hne hEq.symm)]; exact hterm
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s a.key hpres
      obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_updateActive s a he c hfind
      rw [h1, trieGet_set_of_ne _ _ _ _ (fun hEq => hne hEq.symm)]; exact hterm
    · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_updateTerminal s a he
      rw [h1, trieGet_set_of_ne _ _ _ _ (fun hEq => hne hEq.symm)]; exact hterm
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s a.key hpres
      obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_deleteAbsent s a he c hfind
      rw [h1, trieGet_erase_of_ne _ _ _ (fun hEq => hne hEq.symm)]; exact hterm
    · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_deleteActive s a he
      rw [h1, trieGet_erase_of_ne _ _ _ (fun hEq => hne hEq.symm)]; exact hterm

/-- An admitted step never removes a holding it did not consume; a terminal
attestation is never consumed by any edge. -/
theorem step_preserves_terminal_holding (s : RegistryState) (a : Action) (t : Result)
    (key : Key) (out : Nat) (hterm : trieGet s.trie key = .known .terminal)
    (hmem : { key := key, kind := .terminal, output := out } ∈ s.held)
    (hok : step s a = .ok t) :
    { key := key, kind := .terminal, output := out } ∈ t.state.held := by
  obtain ⟨href, ht⟩ := step_eq_ok s a t hok
  subst ht
  rcases (refusal_none_iff s a).mp href with ⟨he, _⟩ | ⟨_, _, _, _, hcase⟩
  · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_witnessTerminal s a he
    rw [h4]; exact List.mem_cons_of_mem _ hmem
  · have hne : a.key ≠ key := by
      rcases hcase with ⟨_, hb⟩ | ⟨_, hb⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ <;>
        (intro hEq; rw [hEq, hterm] at hb; exact absurd hb (by decide))
    rcases hcase with ⟨he, _⟩ | ⟨he, _⟩ | ⟨he, _, hpres⟩ | ⟨he, _, _⟩ | ⟨he, _, hpres⟩ | ⟨he, _, _⟩
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_insertAbsent s a he
      rw [h4]; exact hmem
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_insertActive s a he
      rw [h4]; exact List.mem_cons_of_mem _ hmem
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s a.key hpres
      obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_updateActive s a he c hfind
      rw [h4]; exact List.mem_cons_of_mem _ hmem
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_updateTerminal s a he
      rw [h4]
      exact List.mem_filter.mpr ⟨hmem, by simp⟩
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s a.key hpres
      obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_deleteAbsent s a he c hfind
      rw [h4]; exact hmem
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_deleteActive s a he
      rw [h4]
      exact List.mem_filter.mpr ⟨hmem, by simp⟩

/-- `foldBatch` succeeds exactly when the batch is nonempty and every request
applies in order; the mint check does not change the resulting state. -/
theorem foldBatch_inv (s : RegistryState) (batch : List Action) (t : Result)
    (h : foldBatch s batch = .ok t) :
    batch ≠ [] ∧ foldActions s batch = .ok t := by
  have hne : batch ≠ [] := by
    intro hc; subst hc
    exact Except.noConfusion (show Except.error "empty-fold" = Except.ok t from h)
  refine ⟨hne, ?_⟩
  unfold foldBatch at h
  rw [if_neg (by simpa using hne)] at h
  cases hf : foldActions s batch with
  | error e => rw [hf] at h; exact Except.noConfusion h
  | ok r =>
    rw [hf] at h
    simp only [bind, Except.bind, pure, Except.pure] at h
    split at h
    · have hrt : r = t := by injection h
      exact congrArg Except.ok hrt
    · exact Except.noConfusion h

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
    | error e => rw [hs] at h; exact Except.noConfusion h
    | ok m =>
      rw [hs] at h
      simp only [bind, Except.bind, pure, Except.pure] at h
      cases hr : foldActions m.state bs with
      | error e => rw [hr] at h; exact Except.noConfusion h
      | ok r =>
        rw [hr] at h
        simp only [bind, Except.bind, pure, Except.pure] at h
        have hEq : combineResults m r = t := by injection h
        have h1 := step_preserves_terminal s b m key hterm hs
        rw [← hEq]
        exact ih m.state r h1 hr

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

/-- No edge stores an `unknown` leaf: the writing edges store a known state and
the deleting edges only remove pairs. -/
theorem applyEdge_no_stored_unknown (s : RegistryState) (a : Action)
    (h : ∀ p ∈ s.trie, p.2 ≠ .unknown) :
    ∀ p ∈ (applyEdge s a).state.trie, p.2 ≠ .unknown := by
  intro p hp
  have written : ∀ st : State, p ∈ trieSet s.trie a.key (.known st) → p.2 ≠ .unknown := by
    intro st hmem
    rcases mem_trieSet _ _ _ _ hmem with rfl | hold
    · exact Leaf.noConfusion
    · exact h p hold
  cases he : a.edge <;> simp only [applyEdge, he] at hp
  · exact written _ hp
  · exact written _ hp
  · exact written _ hp
  · exact written _ hp
  · exact h p (mem_trieErase _ _ _ hp)
  · exact h p (mem_trieErase _ _ _ hp)
  · exact h p hp

/-- A reachable registry stores no `unknown` leaf. `unknown` is only ever the
lookup answer for a key the trie does not hold. -/
theorem reachable_no_stored_unknown (s : RegistryState) (h : Reachable s) :
    ∀ p ∈ s.trie, p.2 ≠ .unknown := by
  induction h with
  | initial c => intro p hp; simp at hp
  | next _ hok ih =>
    obtain ⟨_, ht⟩ := step_eq_ok _ _ _ hok
    subst ht
    exact applyEdge_no_stored_unknown _ _ ih

/-! ### The fold's transaction -/

/-- A fold the step refuses builds no transaction, for the step's reason. -/
theorem txOf_of_step_error (s : RegistryState) (r : Request) (lovelace : Nat) (why : String)
    (h : step s r = .error why) : txOf s r lovelace = .error why := by
  simp [txOf, txOfExit, exitStep, h]

/-- The transaction of an admitted fold, spelled from its step: every field is the
step's answer or a definition applied to the request, and the payments the fold
exit owes are carried by the outputs that pay them and listed first among its
refunds. -/
theorem txOf_of_step_ok (s : RegistryState) (r : Request) (lovelace : Nat) (t : Result)
    (h : step s r = .ok t) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := registryDatumForm
                , stateTokens := registryStateTokens, approvals := 0, lovelace := 0 }
              , { role := .request, datum := registryDatumForm
                , stateTokens := 0, approvals := approvalsIn r, lovelace := lovelace } ]
              ++ txBurnInputs t r
          , outputs := txStateOutput t
              :: { txDestinationOutput t r with
                   lovelace := owedTo (.destination (requestDestination r))
                     (obligations (.fold r.edge) r) }
              :: txCageOutputs t r
              ++ ownerOutputs .none (r.approval.map (·.assetName)) (obligations (.fold r.edge) r)
          , mint := t.mint
          , signers := requiredSigners r
          , refunds := (obligations (.fold r.edge) r).map paymentPaid ++ t.paid } := by
  simp [txOf, txOfExit, exitStep, h, txStateOutput, txBurnInputs, txCageOutputs,
    routedPayment, mintRoutedTo, txDestinationOutput]

/-! ### Settling one payment -/

/-- Summing lovelace never loses the accumulator. -/
theorem le_foldl_lovelace (l : List TxOutput) (acc : Nat) :
    acc ≤ l.foldl (· + ·.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp
  | cons o rest ih => exact Nat.le_trans (Nat.le_add_right _ _) (ih _)

/-- An output's lovelace is part of any sum over a list holding it. -/
theorem lovelace_le_foldl (l : List TxOutput) (acc : Nat) (o : TxOutput) (h : o ∈ l) :
    o.lovelace ≤ l.foldl (· + ·.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp at h
  | cons x rest ih =>
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.le_trans (Nat.le_add_left _ _) (le_foldl_lovelace rest _)
    · exact ih _ h

/-- A running maximum never falls below where it started. -/
theorem le_foldl_max_lovelace (l : List TxOutput) (acc : Nat) :
    acc ≤ l.foldl (fun most o => max most o.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp
  | cons o rest ih => exact Nat.le_trans (Nat.le_max_left _ _) (ih _)

/-- An output's lovelace is at most the largest over a list holding it. -/
theorem lovelace_le_foldl_max (l : List TxOutput) (acc : Nat) (o : TxOutput) (h : o ∈ l) :
    o.lovelace ≤ l.foldl (fun most o => max most o.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp at h
  | cons x rest ih =>
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.le_trans (Nat.le_max_right _ _) (le_foldl_max_lovelace rest _)
    · exact ih _ h

/-- An output paying a recipient gives it at least its own lovelace. -/
theorem lovelace_le_receivedBy (recipient : Recipient) (outputs : List TxOutput)
    (o : TxOutput) (h : o ∈ outputs) (pays : paysRecipient recipient o = true) :
    o.lovelace ≤ receivedBy recipient outputs := by
  have mem : o ∈ outputs.filter (paysRecipient recipient) := List.mem_filter.mpr ⟨h, pays⟩
  cases recipient <;> simp only [receivedBy]
  · exact lovelace_le_foldl _ 0 o mem
  · exact lovelace_le_foldl _ 0 o mem
  · exact lovelace_le_foldl _ 0 o mem
  · exact lovelace_le_foldl_max _ 0 o mem

/-- One payment is settled by any output list holding an output that pays its
recipient at least its floor. -/
theorem settle_one (p : Payment) (outputs : List TxOutput)
    (paid : ∃ o ∈ outputs, paysRecipient p.recipient o = true ∧ p.atLeast ≤ o.lovelace) :
    settle [p] outputs = none := by
  obtain ⟨o, h, pays, enough⟩ := paid
  unfold settle
  rw [List.findSome?_eq_none_iff]
  intro recipient judged
  have named : recipient = p.recipient := by
    simpa [List.eraseDups, List.eraseDupsBy, List.eraseDupsBy.loop] using judged
  subst named
  simp [owedTo, Nat.le_trans enough (lovelace_le_receivedBy _ outputs o h pays)]

end Singular
