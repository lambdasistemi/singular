import Singular.Lemmas.State

/-! Step characterization, consistency, terminal preservation and reachability. -/

namespace Singular


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

/-- A successful step replaces exactly the root of the incoming configuration. -/
theorem step_config_root (s : RegistryState) (a : Action) (t : Result)
    (h : step s a = .ok t) :
    t.state.config = { s.config with root := t.state.config.root } := by
  obtain ⟨_, ht⟩ := step_eq_ok s a t h
  subst t
  cases he : a.edge <;> simp [applyEdge, he]

/-- Every successful prefix keeps all configuration fields other than its root. -/
theorem foldActions_config_root (s : RegistryState) (batch : List Action) (t : Result)
    (h : foldActions s batch = .ok t) :
    t.state.config = { s.config with root := t.state.config.root } := by
  induction batch generalizing s t with
  | nil =>
    simp [foldActions] at h
    subst t
    rfl
  | cons a rest ih =>
    cases hs : step s a with
    | error reason => simp [foldActions, hs, bind, Except.bind] at h
    | ok first =>
      cases hr : foldActions first.state rest with
      | error reason => simp [foldActions, hs, hr, bind, Except.bind] at h
      | ok last =>
        simp [foldActions, hs, hr, bind, Except.bind, pure, Except.pure] at h
        subst t
        change last.state.config = { s.config with root := last.state.config.root }
        have hf := step_config_root s a first hs
        have hl := ih first.state last hr
        rw [hl, hf]

theorem error_of_refusal (s : RegistryState) (a : Action) (why : String)
    (h : refusal s a = some why) : step s a = .error why := by
  unfold step; rw [h]



/-- Effects of an admitted `insertActive`. -/
theorem applyEdge_insertActive (s : RegistryState) (a : Action) (he : a.edge = .insertActive) :
    (applyEdge s a).state.trie = trieSet s.trie a.key (.known .active) ∧
    (applyEdge s a).state.config = { s.config with root := rootOf (trieSet s.trie a.key (.known .active)) } ∧
    (applyEdge s a).state.custody = s.custody ∧
    (applyEdge s a).state.held =
      { key := a.key, kind := .active, output := a.output, datum := a.datum } :: s.held ∧
    (applyEdge s a).mint = [((.active, a.key), 1)] ∧ (applyEdge s a).paid = [] := by
  simp [applyEdge, he, delta, assetDelta]



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







/-! ### The admitted-step characterization and the one-step invariant -/

theorem refusal_none_iff (s : RegistryState) (a : Action) : refusal s a = none ↔
    (∃ ap, a.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      admitsFor s.config a a.approval = true ∧
      ((a.edge = .insertActive ∧ trieGet s.trie a.key = .unknown) ∨
       (a.edge = .updateTerminal ∧ trieGet s.trie a.key = .known .active ∧
         s.held.any (fun x => x.key == a.key && x.kind == .active) = true))) := by
  cases hb : trieGet s.trie a.key <;>
    (try (rename_i st; cases st)) <;>
    cases hE : a.edge <;> cases hap : a.approval <;>
    cases hac : s.held.any (fun x => x.key == a.key && x.kind == .active) <;>
    simp +decide [refusal, allowed, hE, hb, hap, admitsFor, hac] <;>
    grind

/-- Consistency survives every accepted step. -/

theorem step_ok_consistent (s : RegistryState) (a : Action) (t : Result)
    (hc : Consistent s) (h : step s a = .ok t) : Consistent t.state := by
  obtain ⟨href, ht⟩ := step_eq_ok s a t h
  subst ht
  obtain ⟨hroot, hA1, hA2, hC1, hC2, hTerm, hCleaf, hCuniq⟩ := hc
  obtain ⟨ap, hap, hpol, hadm, hcase⟩ := (refusal_none_iff s a).mp href
  rcases hcase with ⟨he, hb⟩ | ⟨he, hb, hac⟩
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

theorem step_preserves_terminal (s : RegistryState) (a : Action) (t : Result) (key : Key)
    (hterm : trieGet s.trie key = .known .terminal) (hok : step s a = .ok t) :
    trieGet t.state.trie key = .known .terminal := by
  obtain ⟨href, ht⟩ := step_eq_ok s a t hok
  subst ht
  obtain ⟨_, _, _, _, hcase⟩ := (refusal_none_iff s a).mp href
  rcases hcase with ⟨he, hb⟩ | ⟨he, hb, _⟩ <;>
    have hne : key ≠ a.key := by
      intro hEq
      rw [← hEq, hterm] at hb
      exact absurd hb (by decide)
  · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_insertActive s a he
    rw [h1, trieGet_set_of_ne _ _ _ _ hne]; exact hterm
  · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_updateTerminal s a he
    rw [h1, trieGet_set_of_ne _ _ _ _ hne]; exact hterm

theorem step_preserves_terminal_holding (s : RegistryState) (a : Action) (t : Result)
    (key : Key) (out : Nat) (hterm : trieGet s.trie key = .known .terminal)
    (hmem : { key := key, kind := .terminal, output := out } ∈ s.held)
    (hok : step s a = .ok t) :
    { key := key, kind := .terminal, output := out } ∈ t.state.held := by
  obtain ⟨href, ht⟩ := step_eq_ok s a t hok
  subst ht
  obtain ⟨_, _, _, _, hcase⟩ := (refusal_none_iff s a).mp href
  rcases hcase with ⟨he, _⟩ | ⟨he, _, _⟩
  · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_insertActive s a he
    rw [h4]; exact List.mem_cons_of_mem _ hmem
  · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_updateTerminal s a he
    rw [h4]; exact List.mem_filter.mpr ⟨hmem, by simp⟩

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
  cases he : a.edge <;> simp only [applyEdge, he] at hp <;>
    first | exact h p hp | exact written _ hp

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


end Singular
