import Singular.Lemmas

/-! The public statement surface of the registry-mode model. The eleven
promises of the interface — P1, L1, S1, S2, S3, O1, T1, W1–W4 — and the seven
edge inversions, the fold inversions and the read facts. Every declaration
quantifies over states reachable from genesis by folds; over arbitrary `State`
values the supply laws are simply false. -/

namespace Singular
namespace Statements

/-- **P1** — no tree change without approval, and the pins never move. -/
theorem no_tree_change_without_approval (s : RegistryState) (r : Request) (t : Result)
    (h : Reachable s) (hok : step s r = .ok t) (htree : r.edge ≠ .witnessTerminal) :
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.config.applicationPolicy = s.config.applicationPolicy ∧
    t.state.config.activePolicy = s.config.activePolicy ∧
    t.state.config.absentPolicy = s.config.absentPolicy ∧
    t.state.config.terminalPolicy = s.config.terminalPolicy := by
  obtain ⟨href, ht⟩ := step_eq_ok s r t hok
  subst ht
  rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
  · exact absurd hw htree
  · have happroval : ∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
        ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
        ap.destination = requestDestination r ∧
        ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination := by
      unfold admitsFor at hadm
      rw [hap] at hadm
      rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ <;>
        (rw [hE] at hadm
         simp only at hadm
         simp only [Bool.and_eq_true, beq_iff_eq] at hadm
         obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
         exact ⟨ap, hap, hpol, by rw [hedge', hE], hkey', hown', hdst', hasset'⟩)
    refine ⟨happroval, ?_, ?_, ?_, ?_⟩
    all_goals (
      rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ <;>
        simp [applyEdge, hE])

/-- **L1** — each request is spent once and in order (the fold is a step
chain), a refusal anywhere refuses the whole batch, and no key ends the batch
booked twice. -/
theorem booked_at_most_once (s : RegistryState) (batch : List Request) (t : Result)
    (h : Reachable s) (hok : foldBatch s batch = .ok t) :
    Folds s batch t ∧
    (∀ b bs, batch = b :: bs → ∀ why, step s b = .error why → foldBatch s batch = .error why) ∧
    (∀ key, kindCount t.state .active key ≤ 1 ∧ custodyCount t.state key ≤ 1) := by
  sorry

/-- **S1** — every terminal attestation in a reachable state is about a leaf
that is terminal: no attestation of an Active, Absent or Unknown key exists. -/
theorem terminal_attestation_sound (s : RegistryState) (key : Key) (out : Nat)
    (h : Reachable s) (hmem : { key := key, kind := .terminal, output := out } ∈ s.held) :
    trieGet s.trie key = .known .terminal := by
  exact (reachable_consistent s h).2.2.2.2.2.1 _ hmem rfl

/-- The provenance half of S1: a terminal token enters the ledger only through
an admitted `witnessTerminal` step whose read was verified. -/
theorem terminal_mint_only_by_read (s : RegistryState) (r : Request) (t : Result)
    (hok : step s r = .ok t) (key : Key)
    (hnew : kindCount t.state .terminal key = kindCount s .terminal key + 1) :
    r.edge = .witnessTerminal ∧ trieGet s.trie key = .known .terminal ∧
      s.config.root = rootOf s.trie := by
  sorry

/-- **S2** — a terminal attestation is valid in every later state: a terminal
leaf admits no edge that moves it, and no edge burns an attestation. -/
theorem terminal_attestation_permanent (s : RegistryState) (acts : List Request) (t : Result)
    (h : Reachable s) (hok : foldBatch s acts = .ok t) (key : Key) (out : Nat)
    (hmem : { key := key, kind := .terminal, output := out } ∈ s.held) :
    { key := key, kind := .terminal, output := out } ∈ t.state.held ∧
      trieGet t.state.trie key = .known .terminal := by
  have hterm : trieGet s.trie key = .known .terminal :=
    (reachable_consistent s h).2.2.2.2.2.1 _ hmem rfl
  have hacts := (foldBatch_inv s acts t hok).2
  refine ⟨?_, foldActions_preserves_terminal s acts t key hterm hacts⟩
  clear hok
  induction acts generalizing s t with
  | nil =>
    unfold foldActions at hacts
    have : emptyResult s = t := by injection hacts
    rw [← this]; exact hmem
  | cons b bs ih =>
    unfold foldActions at hacts
    simp only [bind, Except.bind, pure, Except.pure] at hacts
    cases hs : step s b with
    | error e => rw [hs] at hacts; exact Except.noConfusion hacts
    | ok m =>
      rw [hs] at hacts
      simp only [bind, Except.bind, pure, Except.pure] at hacts
      cases hrest : foldActions m.state bs with
      | error e => rw [hrest] at hacts; exact Except.noConfusion hacts
      | ok rr =>
        rw [hrest] at hacts
        have hEq : combineResults m rr = t := by injection hacts
        rw [← hEq]
        exact ih m.state rr (Reachable.next h hs)
          (step_preserves_terminal_holding s b m key out hterm hmem hs)
          (step_preserves_terminal s b m key hterm hs) hrest

/-- **S3** — the biconditional supply law, unconditionally over reachable
states: supply is 1 iff the key is in that token's state, 0 otherwise. -/
theorem biconditional_supply_sync (s : RegistryState) (h : Reachable s) (key : Key) :
    (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) ∧
    (kindCount s .active key = 0 ↔ trieGet s.trie key ≠ .known .active) ∧
    (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) ∧
    (custodyCount s key = 0 ↔ trieGet s.trie key ≠ .known .absent) := by
  obtain ⟨_, hA1, hA2, hC1, hC2, _, _, _⟩ := reachable_consistent s h
  refine ⟨hA1 key, ?_, hC1 key, ?_⟩
  · constructor
    · intro h0 hEq
      have := (hA1 key).mpr hEq
      omega
    · intro hne
      have := hA2 key
      have hnot1 : kindCount s .active key ≠ 1 := fun hEq => hne ((hA1 key).mp hEq)
      omega
  · constructor
    · intro h0 hEq
      have := (hC1 key).mpr hEq
      omega
    · intro hne
      have := hC2 key
      have hnot1 : custodyCount s key ≠ 1 := fun hEq => hne ((hC1 key).mp hEq)
      omega

/-- **O1** — occupancy: a booking edge succeeds only on a key that is not
taken, and books it. -/
theorem occupancy (s : RegistryState) (r : Request) (t : Result) (h : Reachable s)
    (hok : step s r = .ok t)
    (hedge : r.edge = .insertActive ∨ r.edge = .updateActive) :
    ¬ (trieGet s.trie r.key = .known .active ∨ trieGet s.trie r.key = .known .terminal) ∧
    trieGet t.state.trie r.key = .known .active := by
  obtain ⟨href, ht⟩ := step_eq_ok s r t hok
  subst ht
  rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨_, _, _, _, hcase⟩
  · rcases hedge with hE | hE <;> (rw [hE] at hw; exact absurd hw (by decide))
  · rcases hcase with ⟨hE, hb⟩ | ⟨hE, hb⟩ | ⟨hE, hb, hpres⟩ | ⟨hE, hb, _⟩ | ⟨hE, hb, _⟩ |
        ⟨hE, hb, _⟩
    · rcases hedge with h2 | h2 <;> (rw [h2] at hE; exact absurd hE (by decide))
    · obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_insertActive s r hE
      exact ⟨by rw [hb]; rintro (hc | hc) <;> exact absurd hc (by decide),
        by rw [h1, trieGet_set_eq]⟩
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s r.key hpres
      obtain ⟨h1, _, _, _, _, _⟩ := applyEdge_updateActive s r hE c hfind
      exact ⟨by rw [hb]; rintro (hc | hc) <;> exact absurd hc (by decide),
        by rw [h1, trieGet_set_eq]⟩
    all_goals (rcases hedge with h2 | h2 <;> (rw [h2] at hE; exact absurd hE (by decide)))

/-- **O1**, converse: a booking edge on an untaken key, with a matching
approval, succeeds. -/
theorem occupancy_free_key_succeeds (s : RegistryState) (h : Reachable s) (key : Key)
    (owner out : Nat) (hfree : trieGet s.trie key = .unknown)
    (ap : Approval) (hmatch : admitsFor s.config
      { edge := .insertActive, key := key, owner := owner, output := out } (some ap)) :
    ∃ t, step s { edge := .insertActive, key := key, owner := owner, output := out, approval := ap } = .ok t := by
  sorry

/-- **T1** — termination: on a terminal key every leaf-moving edge is refused,
forever, so the key stays terminated and is never re-booked. Supersedes the
base `over_terminal`. -/
theorem termination (s : RegistryState) (key : Key) (h : Reachable s)
    (hterm : trieGet s.trie key = .known .terminal) :
    (∀ (r : Request), r.edge ≠ .witnessTerminal → r.key = key →
        ∃ why, step s r = .error why) ∧
    (∀ (acts : List Request) (t : Result), foldBatch s acts = .ok t →
        trieGet t.state.trie key = .known .terminal) := by
  constructor
  · intro r htree hkey
    cases hr : refusal s r with
    | some why => exact ⟨why, error_of_refusal s r why hr⟩
    | none =>
      exfalso
      rcases (refusal_none_iff s r).mp hr with ⟨hw, _⟩ | ⟨_, _, _, _, hcase⟩
      · exact htree hw
      · rcases hcase with ⟨_, hb⟩ | ⟨_, hb⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ | ⟨_, hb, _⟩ <;>
          (rw [hkey, hterm] at hb; exact absurd hb (by decide))
  · intro acts t hfold
    exact foldActions_preserves_terminal s acts t key hterm (foldBatch_inv s acts t hfold).2

/-- **W1** — at most one active token, exactly one iff the leaf is Active. -/
theorem active_witness_unique (s : RegistryState) (h : Reachable s) (key : Key) :
    kindCount s .active key ≤ 1 ∧
    (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) := by
  obtain ⟨_, hA1, hA2, _, _, _, _, _⟩ := reachable_consistent s h
  exact ⟨hA2 key, hA1 key⟩

/-- **W2** — at most one absent witness, exactly one iff the leaf is Absent. -/
theorem absent_witness_unique (s : RegistryState) (h : Reachable s) (key : Key) :
    custodyCount s key ≤ 1 ∧
    (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) := by
  obtain ⟨_, _, _, hC1, hC2, _, _, _⟩ := reachable_consistent s h
  exact ⟨hC2 key, hC1 key⟩

/-- **W3** — terminal attestations are plural, all true, and freely mintable
while the leaf is terminal; none exists otherwise. -/
theorem terminal_witness_plural (s : RegistryState) (key : Key) (h : Reachable s)
    (hterm : trieGet s.trie key = .known .terminal) (out : Nat) :
    (∃ t, step s (Request.mk .witnessTerminal key 0 0 0 out none
        [(.terminal, 1)]) = .ok t ∧
      kindCount t.state .terminal key = kindCount s .terminal key + 1) ∧
    (∀ h ∈ s.held, h.kind = .terminal → h.key = key) ∧
    (∀ n : Nat, ∃ (u : RegistryState), Reachable u ∧
      kindCount u .terminal key = n ∧ trieGet u.trie key = .known .terminal) := by
  sorry

/-- **W4** — kind exclusion: at most one kind of witness is outstanding for a
key, so a consumer that finds one kind knows the other two do not exist. -/
theorem witness_kinds_exclude (s : RegistryState) (h : Reachable s) (key : Key) :
    (kindCount s .active key > 0 → custodyCount s key = 0 ∧ kindCount s .terminal key = 0) ∧
    (custodyCount s key > 0 → kindCount s .active key = 0 ∧ kindCount s .terminal key = 0) ∧
    (kindCount s .terminal key > 0 → kindCount s .active key = 0 ∧ custodyCount s key = 0) := by
  obtain ⟨_, hA1, hA2, hC1, hC2, hTerm, _, _⟩ := reachable_consistent s h
  have hterm_leaf : kindCount s .terminal key > 0 → trieGet s.trie key = .known .terminal := by
    intro hpos
    unfold kindCount at hpos
    cases hf : (s.held.filter fun x => x.key == key && x.kind == .terminal) with
    | nil => rw [hf] at hpos; simp at hpos
    | cons x xs =>
      have hx : x ∈ s.held.filter (fun x => x.key == key && x.kind == .terminal) := by
        rw [hf]; exact List.mem_cons_self
      have hmem := (List.mem_filter.mp hx).1
      have hxp := (List.mem_filter.mp hx).2
      have hxk : x.key = key := by simpa using (Bool.and_eq_true_iff.mp hxp).1
      have hxkind : x.kind = .terminal := by simpa using (Bool.and_eq_true_iff.mp hxp).2
      have := hTerm x hmem hxkind
      rw [hxk] at this; exact this
  have hactive_leaf : kindCount s .active key > 0 → trieGet s.trie key = .known .active := by
    intro hpos
    have h1 : kindCount s .active key = 1 := by have := hA2 key; omega
    exact (hA1 key).mp h1
  have hcust_leaf : custodyCount s key > 0 → trieGet s.trie key = .known .absent := by
    intro hpos
    have h1 : custodyCount s key = 1 := by have := hC2 key; omega
    exact (hC1 key).mp h1
  refine ⟨?_, ?_, ?_⟩
  · intro hpos
    have hl := hactive_leaf hpos
    refine ⟨?_, ?_⟩
    · rcases Nat.eq_zero_or_pos (custodyCount s key) with h0 | hp
      · exact h0
      · have := hcust_leaf hp; rw [hl] at this; exact absurd this (by decide)
    · rcases Nat.eq_zero_or_pos (kindCount s .terminal key) with h0 | hp
      · exact h0
      · have := hterm_leaf hp; rw [hl] at this; exact absurd this (by decide)
  · intro hpos
    have hl := hcust_leaf hpos
    refine ⟨?_, ?_⟩
    · rcases Nat.eq_zero_or_pos (kindCount s .active key) with h0 | hp
      · exact h0
      · have := hactive_leaf hp; rw [hl] at this; exact absurd this (by decide)
    · rcases Nat.eq_zero_or_pos (kindCount s .terminal key) with h0 | hp
      · exact h0
      · have := hterm_leaf hp; rw [hl] at this; exact absurd this (by decide)
  · intro hpos
    have hl := hterm_leaf hpos
    refine ⟨?_, ?_⟩
    · rcases Nat.eq_zero_or_pos (kindCount s .active key) with h0 | hp
      · exact h0
      · have := hactive_leaf hp; rw [hl] at this; exact absurd this (by decide)
    · rcases Nat.eq_zero_or_pos (custodyCount s key) with h0 | hp
      · exact h0
      · have := hcust_leaf hp; rw [hl] at this; exact absurd this (by decide)

/-- A read's verification is exactly the intermediate leaf being the claimed
terminal state, against a committed root. -/
theorem readAt_true_iff (s : RegistryState) (key : Key) :
    readAt s 0 key .terminal = true ↔
      s.config.root = rootOf s.trie ∧ trieGet s.trie key = .known .terminal := by
  unfold readAt
  simp [Bool.and_eq_true]

/-! ### Edge inversions — one per edge, exact guards and effects -/

/-- Inversion of an admitted `insertAbsent`. -/
theorem insert_absent_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .insertAbsent) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .unknown ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .absent) ∧
    t.state.config = { s.config with root := rootOf (trieSet s.trie r.key (.known .absent)) } ∧
    t.state.custody =
      { key := r.key, refundAddress := r.refundAddress, value := r.deposit } :: s.custody ∧
    t.state.held = s.held ∧ t.mint = [(.absent, 1)] ∧ t.paid = [] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    obtain ⟨htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := applyEdge_insertAbsent s r he
    rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
    · rw [he] at hw; exact absurd hw (by decide)
    · have hb : trieGet s.trie r.key = .unknown := by
        rcases hcase with ⟨_, hb⟩ | ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _⟩
        all_goals first
          | exact hb
          | (rw [he] at hE; exact absurd hE (by decide))
      unfold admitsFor at hadm
      rw [hap] at hadm
      simp only [he] at hadm
      simp only [Bool.and_eq_true, beq_iff_eq] at hadm
      obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
      exact ⟨hb, ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
        htrie, hcfg, hcust, hheld, hmint, hpaid⟩
  · rintro ⟨hb, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust,
      hheld, hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [he]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr (Or.inr ⟨ap, hap, hpol, hadm, Or.inl ⟨he, hb⟩⟩)
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hcust', hheld', hmint', hpaid'⟩ := applyEdge_insertAbsent s r he
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, h1⟩ ⟨c2, t2, cu2, h2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie])
        (by rw [hcust', hcust]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))

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
    t.state.custody = s.custody ∧
    t.state.held = { key := r.key, kind := .active, output := r.output } :: s.held ∧
    t.mint = [(.active, 1)] ∧ t.paid = [] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
    · rw [he] at hw; exact absurd hw (by decide)
    · have hguard : trieGet s.trie r.key = .unknown := by
        rcases hcase with ⟨hE, _⟩ | ⟨_, hb⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩
        all_goals first
          | exact hb
          | (rw [he] at hE; exact absurd hE (by decide))
      obtain ⟨htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := applyEdge_insertActive s r he
      unfold admitsFor at hadm
      rw [hap] at hadm
      simp only [he] at hadm
      simp only [Bool.and_eq_true, beq_iff_eq] at hadm
      obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
      refine ⟨hguard, ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
        htrie, hcfg, hcust, hheld, hmint, hpaid⟩
  · rintro ⟨hb, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [he]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr (Or.inr ⟨ap, hap, hpol, hadm, Or.inr (Or.inl ⟨he, hb⟩)⟩)
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hcust', hheld', hmint', hpaid'⟩ := applyEdge_insertActive s r he
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, hh1⟩ ⟨c2, t2, cu2, hh2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie])
        (by rw [hcust', hcust]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))
/-- Inversion of an admitted `updateActive` — booking a witnessed name; the
consumed absent token's value is paid to the refund address its custody datum
records (R-ADA). -/
theorem update_active_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .updateActive) (c : Custody)
    (hc : s.custody.find? (·.key == r.key) = some c) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .absent ∧ c.key = r.key ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .active) ∧
    t.state.config = { s.config with root := rootOf (trieSet s.trie r.key (.known .active)) } ∧
    t.state.custody = s.custody.filter (·.key != r.key) ∧
    t.state.held = { key := r.key, kind := .active, output := r.output } :: s.held ∧
    t.mint = [(.absent, -1), (.active, 1)] ∧
    t.paid = [(c.refundAddress, c.value)] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
    · rw [he] at hw; exact absurd hw (by decide)
    · have hguard : trieGet s.trie r.key = .known .absent ∧ s.custody.any (·.key == r.key) = true := by
        rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨_, hb, hpres⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩
        all_goals first
          | exact ⟨hb, hpres⟩
          | (rw [he] at hE; exact absurd hE (by decide))
      obtain ⟨htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := applyEdge_updateActive s r he c hc
      unfold admitsFor at hadm
      rw [hap] at hadm
      simp only [he] at hadm
      simp only [Bool.and_eq_true, beq_iff_eq] at hadm
      obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
      refine ⟨hguard.1, by simpa using List.find?_some hc,
        ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
        htrie, hcfg, hcust, hheld, hmint, hpaid⟩
  · rintro ⟨hb, _, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [he]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have hpres : s.custody.any (·.key == r.key) = true := by
      refine List.any_eq_true.mpr ⟨c, List.mem_of_find?_eq_some hc, ?_⟩
      simpa using List.find?_some hc
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr (Or.inr ⟨ap, hap, hpol, hadm, Or.inr (Or.inr (Or.inl ⟨he, hb, hpres⟩))⟩)
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hcust', hheld', hmint', hpaid'⟩ := applyEdge_updateActive s r he c hc
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, hh1⟩ ⟨c2, t2, cu2, hh2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie])
        (by rw [hcust', hcust]) (by rw [hheld', hheld]))
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
    t.state.custody = s.custody ∧
    t.state.held = (s.held.filter fun h => !(h.key == r.key && h.kind == .active)) ∧
    t.mint = [(.active, -1)] ∧ t.paid = [] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
    · rw [he] at hw; exact absurd hw (by decide)
    · have hguard : trieGet s.trie r.key = .known .active ∧ s.held.any (fun x => x.key == r.key && x.kind == .active) = true := by
        rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _, _⟩ | ⟨_, hb, hpres⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩
        all_goals first
          | exact ⟨hb, hpres⟩
          | (rw [he] at hE; exact absurd hE (by decide))
      obtain ⟨htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := applyEdge_updateTerminal s r he
      unfold admitsFor at hadm
      rw [hap] at hadm
      simp only [he] at hadm
      simp only [Bool.and_eq_true, beq_iff_eq] at hadm
      obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
      refine ⟨hguard.1, hguard.2, ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
        htrie, hcfg, hcust, hheld, hmint, hpaid⟩
  · rintro ⟨hb, hpres, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [he]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr (Or.inr ⟨ap, hap, hpol, hadm, Or.inr (Or.inr (Or.inr (Or.inl ⟨he, hb, hpres⟩)))⟩)
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hcust', hheld', hmint', hpaid'⟩ := applyEdge_updateTerminal s r he
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, hh1⟩ ⟨c2, t2, cu2, hh2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie])
        (by rw [hcust', hcust]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))
/-- Inversion of an admitted `deleteAbsent` — the witness retracts, the deposit
returns to the inserter (R-ADA), and the key reads `Unknown` again. -/
theorem delete_absent_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .deleteAbsent) (c : Custody)
    (hc : s.custody.find? (·.key == r.key) = some c) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .absent ∧ c.key = r.key ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key .unknown ∧
    t.state.config = { s.config with root := rootOf (trieSet s.trie r.key .unknown) } ∧
    t.state.custody = s.custody.filter (·.key != r.key) ∧
    t.state.held = s.held ∧
    t.mint = [(.absent, -1)] ∧ t.paid = [(c.refundAddress, c.value)] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
    · rw [he] at hw; exact absurd hw (by decide)
    · have hguard : trieGet s.trie r.key = .known .absent ∧ s.custody.any (·.key == r.key) = true := by
        rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨_, hb, hpres⟩ | ⟨hE, _, _⟩
        all_goals first
          | exact ⟨hb, hpres⟩
          | (rw [he] at hE; exact absurd hE (by decide))
      obtain ⟨htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := applyEdge_deleteAbsent s r he c hc
      unfold admitsFor at hadm
      rw [hap] at hadm
      simp only [he] at hadm
      simp only [Bool.and_eq_true, beq_iff_eq] at hadm
      obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
      refine ⟨hguard.1, by simpa using List.find?_some hc,
        ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
        htrie, hcfg, hcust, hheld, hmint, hpaid⟩
  · rintro ⟨hb, _, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [he]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have hpres : s.custody.any (·.key == r.key) = true := by
      refine List.any_eq_true.mpr ⟨c, List.mem_of_find?_eq_some hc, ?_⟩
      simpa using List.find?_some hc
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr (Or.inr ⟨ap, hap, hpol, hadm, Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨he, hb, hpres⟩))))⟩)
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hcust', hheld', hmint', hpaid'⟩ := applyEdge_deleteAbsent s r he c hc
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, hh1⟩ ⟨c2, t2, cu2, hh2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie])
        (by rw [hcust', hcust]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))
/-- Inversion of an admitted `deleteActive` — the key reads `Unknown` again and
may be inserted again as the same key. -/
theorem delete_active_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .deleteActive) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .active ∧
    s.held.any (fun x => x.key == r.key && x.kind == .active) = true ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key .unknown ∧
    t.state.config = { s.config with root := rootOf (trieSet s.trie r.key .unknown) } ∧
    t.state.custody = s.custody ∧
    t.state.held = (s.held.filter fun h => !(h.key == r.key && h.kind == .active)) ∧
    t.mint = [(.active, -1)] ∧ t.paid = [] := by
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    rcases (refusal_none_iff s r).mp href with ⟨hw, _⟩ | ⟨ap, hap, hpol, hadm, hcase⟩
    · rw [he] at hw; exact absurd hw (by decide)
    · have hguard : trieGet s.trie r.key = .known .active ∧ s.held.any (fun x => x.key == r.key && x.kind == .active) = true := by
        rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨_, hb, hpres⟩
        all_goals first
          | exact ⟨hb, hpres⟩
          | (rw [he] at hE; exact absurd hE (by decide))
      obtain ⟨htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := applyEdge_deleteActive s r he
      unfold admitsFor at hadm
      rw [hap] at hadm
      simp only [he] at hadm
      simp only [Bool.and_eq_true, beq_iff_eq] at hadm
      obtain ⟨⟨⟨⟨⟨_, hedge'⟩, hkey'⟩, hown'⟩, hdst'⟩, hasset'⟩ := hadm
      refine ⟨hguard.1, hguard.2, ⟨ap, hap, hpol, by rw [hedge', he], hkey', hown', hdst', hasset'⟩,
        htrie, hcfg, hcust, hheld, hmint, hpaid⟩
  · rintro ⟨hb, hpres, ⟨ap, hap, hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust, hheld,
      hmint, hpaid⟩
    have hadm : admitsFor s.config r r.approval = true := by
      unfold admitsFor
      rw [hap]
      simp only [he]
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨⟨⟨⟨⟨hpol, ?_⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
      rw [hedge, he]
    have href : refusal s r = none :=
      (refusal_none_iff s r).mpr (Or.inr ⟨ap, hap, hpol, hadm, Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨he, hb, hpres⟩))))⟩)
    rw [ok_of_refusal s r href]
    obtain ⟨htrie', hcfg', hcust', hheld', hmint', hpaid'⟩ := applyEdge_deleteActive s r he
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, hh1⟩ ⟨c2, t2, cu2, hh2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [hcfg', hcfg]) (by rw [htrie', htrie])
        (by rw [hcust', hcust]) (by rw [hheld', hheld]))
      (by rw [hmint', hmint]) (by rw [hpaid', hpaid]))
/-- Inversion of an admitted `witnessTerminal` — the read: the leaf, the root
and custody are unchanged, one attestation is minted to the named output. -/
theorem witness_terminal_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .witnessTerminal) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .terminal ∧ s.config.root = rootOf s.trie ∧
    t.state.trie = s.trie ∧ t.state.config = s.config ∧ t.state.custody = s.custody ∧
    t.state.held = { key := r.key, kind := .terminal, output := r.output } :: s.held ∧
    t.mint = [(.terminal, 1)] ∧ t.paid = [] := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := applyEdge_witnessTerminal s r he
  constructor
  · intro hok
    obtain ⟨href, ht⟩ := step_eq_ok s r t hok
    subst ht
    rcases (refusal_none_iff s r).mp href with ⟨_, hr⟩ | ⟨_, _, _, _, hcase⟩
    · have := (readAt_true_iff s r.key).mp hr
      exact ⟨this.2, this.1, h1, h2, h3, h4, h5, h6⟩
    · rcases hcase with ⟨hE, _⟩ | ⟨hE, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩ | ⟨hE, _, _⟩
      all_goals (rw [he] at hE; exact absurd hE (by decide))
  · rintro ⟨hterm, hroot, htrie, hcfg, hcust, hheld, hmint, hpaid⟩
    have hr : readAt s 0 r.key .terminal = true :=
      (readAt_true_iff s r.key).mpr ⟨hroot, hterm⟩
    have href : refusal s r = none := (refusal_none_iff s r).mpr (Or.inl ⟨he, hr⟩)
    rw [ok_of_refusal s r href]
    have hSt : ∀ (x y : RegistryState), x.config = y.config → x.trie = y.trie →
        x.custody = y.custody → x.held = y.held → x = y := by
      intro ⟨c1, t1, cu1, hh1⟩ ⟨c2, t2, cu2, hh2⟩ e1 e2 e3 e4
      simp only at e1 e2 e3 e4
      subst e1; subst e2; subst e3; subst e4; rfl
    have hRes : ∀ (x y : Result), x.state = y.state → x.mint = y.mint → x.paid = y.paid →
        x = y := by
      intro ⟨s1, m1, p1⟩ ⟨s2, m2, p2⟩ e1 e2 e3
      simp only at e1 e2 e3
      subst e1; subst e2; subst e3; rfl
    exact congrArg Except.ok (hRes _ _
      (hSt _ _ (by rw [h2, hcfg]) (by rw [h1, htrie]) (by rw [h3, hcust]) (by rw [h4, hheld]))
      (by rw [h5, hmint]) (by rw [h6, hpaid]))

/-! ### Fold and read facts -/

/-- A zero-request batch is always refused. -/
theorem empty_fold_error (s : RegistryState) (batch : List Request)
    (h : batch = []) : foldBatch s batch = .error "empty-fold" := by
  subst h
  rfl

/-- A fold succeeds iff every request applies in order and the claimed mint
matches the summed delta of the folded edges. -/
theorem fold_batch_cons (s : RegistryState) (b : Request) (bs : List Request) (t : Result) :
    foldBatch s (b :: bs) = .ok t ↔
    ∃ m r, step s b = .ok m ∧ foldBatch m.state bs = .ok r ∧
      t = { state := r.state, mint := deltaPlus m.mint r.mint, paid := m.paid ++ r.paid } ∧
      deltaSame (deltaPlus b.claimed (bs.foldl (fun acc b => deltaPlus acc b.claimed) []))
        (deltaPlus (delta b.edge) (bs.foldl (fun acc b => deltaPlus acc (delta b.edge)) [])) := by
  sorry

/-- A read changes nothing: the leaf, the root and custody survive an admitted
`witnessTerminal` step unchanged. -/
theorem read_changes_nothing (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .witnessTerminal) (hok : step s r = .ok t) :
    t.state.trie = s.trie ∧ t.state.config = s.config ∧ t.state.custody = s.custody := by
  obtain ⟨_, ht⟩ := step_eq_ok s r t hok
  subst ht
  obtain ⟨h1, h2, h3, _, _, _⟩ := applyEdge_witnessTerminal s r he
  exact ⟨h1, h2, h3⟩

end Statements
end Singular
