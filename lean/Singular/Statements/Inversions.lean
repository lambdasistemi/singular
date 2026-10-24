import Singular.Lemmas
import Singular.Driver
import Singular.Economics

/-! Exact guards and effects for the two supported edges. -/

namespace Singular.Statements

/-! ### Edge inversions — one per edge, exact guards and effects -/



/-- Inversion of an admitted `insertActive`. -/
theorem insert_active_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .insertActive) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .unknown ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .active) ∧
    t.state.config = { s.config with root := rootOf (trieSet s.trie r.key (.known .active)) } ∧
    t.state.held = { key := r.key, kind := .active, output := r.output
                     , datum := r.datum } :: s.held ∧
    t.mint = [((.active, r.key), 1)] ∧ t.paid = [] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    obtain ⟨ap, hap, hpol, hadm, hcase⟩ := (refusal_none_iff s r).mp href
    have hguard : trieGet s.trie r.key = .unknown := by simpa [he] using hcase
    obtain ⟨htrie, hcfg, hheld, hmint, hpaid⟩ := applyEdge_insertActive s r he
    unfold admitsFor at hadm
    rw [hap] at hadm
    simp only [Bool.and_eq_true, beq_iff_eq] at hadm
    obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
    refine ⟨hguard, ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
      htrie, hcfg, hheld, hmint, hpaid⟩
  · rintro ⟨hb, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr ⟨ap, hap, hpol, hadm, Or.inl ⟨he, hb⟩⟩
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hheld', hmint', hpaid'⟩ := applyEdge_insertActive s r he
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.held = y.held → x = y := by
      intro ⟨c1, t1, hh1⟩ ⟨c2, t2, hh2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))


/-- Inversion of an admitted `updateTerminal` — retirement completes here. -/
theorem update_terminal_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .updateTerminal) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .active ∧
    s.held.any (fun x => x.key == r.key && x.kind == .active) = true ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .terminal) ∧
    t.state.config = { s.config with root := rootOf (trieSet s.trie r.key (.known .terminal)) } ∧
    t.state.held = (s.held.filter fun h => !(h.key == r.key && h.kind == .active)) ∧
    t.mint = [((.active, r.key), -1)] ∧ t.paid = [] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    obtain ⟨ap, hap, hpol, hadm, hcase⟩ := (refusal_none_iff s r).mp href
    have hguard : trieGet s.trie r.key = .known .active ∧ s.held.any (fun x => x.key == r.key && x.kind == .active) = true := by simpa [he] using hcase
    obtain ⟨htrie, hcfg, hheld, hmint, hpaid⟩ := applyEdge_updateTerminal s r he
    unfold admitsFor at hadm
    rw [hap] at hadm
    simp only [Bool.and_eq_true, beq_iff_eq] at hadm
    obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
    refine ⟨hguard.1, hguard.2, ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
      htrie, hcfg, hheld, hmint, hpaid⟩
  · rintro ⟨hb, hpres, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr ⟨ap, hap, hpol, hadm, Or.inr ⟨he, hb, hpres⟩⟩
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hheld', hmint', hpaid'⟩ := applyEdge_updateTerminal s r he
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.held = y.held → x = y := by
      intro ⟨c1, t1, hh1⟩ ⟨c2, t2, hh2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))







end Singular.Statements
