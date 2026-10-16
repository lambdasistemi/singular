import Singular.Model

/-! Trie, custody and holding facts reused by transition proofs. -/

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


end Singular
