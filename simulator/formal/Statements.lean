import Singular.Lemmas

/-! The public statement surface of the registry-mode model. The eleven
promises of the interface — P1, L1, S1, S2, S3, O1, T1, W1–W4 — and the seven
edge inversions, the fold inversions and the read facts. Every declaration
quantifies over states reachable from genesis by folds; over arbitrary `State`
values the supply laws are simply false. -/

namespace Singular
namespace Statements

/-- A read's verification is exactly the intermediate leaf being the claimed
terminal state, against a committed root. -/
theorem readAt_true_iff (s : RegistryState) (key : Key) :
    readAt s 0 key .terminal = true ↔
      s.config.root = rootOf s.trie ∧ trieGet s.trie key = .known .terminal := by
  unfold readAt
  simp [Bool.and_eq_true]

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
  obtain ⟨hne, hacts⟩ := foldBatch_inv s batch t hok
  have hfolds : ∀ (u : RegistryState) (bs : List Request) (r : Result),
      foldActions u bs = .ok r → Folds u bs r := by
    intro u bs
    induction bs generalizing u with
    | nil =>
      intro r hr
      unfold foldActions at hr
      have : emptyResult u = r := by injection hr
      rw [← this]; exact Folds.done u
    | cons b bs ih =>
      intro r hr
      unfold foldActions at hr
      simp only [bind, Except.bind, pure, Except.pure] at hr
      cases hs : step u b with
      | error e => rw [hs] at hr; exact Except.noConfusion hr
      | ok m =>
        rw [hs] at hr
        simp only [bind, Except.bind, pure, Except.pure] at hr
        cases hrest : foldActions m.state bs with
        | error e => rw [hrest] at hr; exact Except.noConfusion hr
        | ok rr =>
          rw [hrest] at hr
          have hEq : combineResults m rr = r := by injection hr
          rw [← hEq]
          exact Folds.cons u b bs m rr hs (ih m.state rr hrest)
  have hreach : Reachable t.state := by
    have : ∀ (u : RegistryState) (bs : List Request) (r : Result),
        Reachable u → foldActions u bs = .ok r → Reachable r.state := by
      intro u bs
      induction bs generalizing u with
      | nil =>
        intro r hu hr
        unfold foldActions at hr
        have : emptyResult u = r := by injection hr
        rw [← this]; exact hu
      | cons b bs ih =>
        intro r hu hr
        unfold foldActions at hr
        simp only [bind, Except.bind, pure, Except.pure] at hr
        cases hs : step u b with
        | error e => rw [hs] at hr; exact Except.noConfusion hr
        | ok m =>
          rw [hs] at hr
          simp only [bind, Except.bind, pure, Except.pure] at hr
          cases hrest : foldActions m.state bs with
          | error e => rw [hrest] at hr; exact Except.noConfusion hr
          | ok rr =>
            rw [hrest] at hr
            have hEq : combineResults m rr = r := by injection hr
            rw [← hEq]
            exact ih m.state rr (Reachable.next hu hs) hrest
    exact this s batch t h hacts
  refine ⟨hfolds s batch t hacts, ?_, ?_⟩
  · intro b bs hb why hstep
    subst hb
    unfold foldBatch
    rw [if_neg (by simp)]
    unfold foldActions
    simp only [bind, Except.bind, pure, Except.pure]
    rw [hstep]
  · intro key
    obtain ⟨_, _, hA2, _, hC2, _, _, _⟩ := reachable_consistent t.state hreach
    exact ⟨hA2 key, hC2 key⟩

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
  obtain ⟨href, ht⟩ := step_eq_ok s r t hok
  subst ht
  rcases (refusal_none_iff s r).mp href with ⟨he, hr⟩ | ⟨_, _, _, _, hcase⟩
  · have hrd := (readAt_true_iff s r.key).mp hr
    obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_witnessTerminal s r he
    have hkey : r.key = key := by
      rcases Decidable.em (r.key = key) with hEq | hne
      · exact hEq
      · exfalso
        simp only [kindCount, h4, countHeld_cons] at hnew
        rw [if_neg (by simpa using fun hc => hne (by simpa using hc))] at hnew
        omega
    rw [hkey] at hrd
    exact ⟨he, hrd.2, hrd.1⟩
  · exfalso
    rcases hcase with ⟨he, _⟩ | ⟨he, _⟩ | ⟨he, _, hpres⟩ | ⟨he, _, _⟩ | ⟨he, _, hpres⟩ | ⟨he, _, _⟩
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_insertAbsent s r he
      simp only [kindCount, h4] at hnew; omega
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_insertActive s r he
      simp only [kindCount, h4, countHeld_cons] at hnew
      rw [if_neg (by simp)] at hnew; omega
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s r.key hpres
      obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_updateActive s r he c hfind
      simp only [kindCount, h4, countHeld_cons] at hnew
      rw [if_neg (by simp)] at hnew; omega
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_updateTerminal s r he
      simp only [kindCount, h4] at hnew
      have := countHeld_filter_active_le s.held r.key .terminal key
      simp only [kindCount] at this
      omega
    · obtain ⟨c, hfind, _⟩ := custody_entry_of_present s r.key hpres
      obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_deleteAbsent s r he c hfind
      simp only [kindCount, h4] at hnew; omega
    · obtain ⟨_, _, _, h4, _, _⟩ := applyEdge_deleteActive s r he
      simp only [kindCount, h4] at hnew
      have := countHeld_filter_active_le s.held r.key .terminal key
      simp only [kindCount] at this
      omega

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
  have hpol : ap.policy = s.config.applicationPolicy := by
    unfold admitsFor at hmatch
    simp only at hmatch
    simp only [Bool.and_eq_true, beq_iff_eq] at hmatch
    exact hmatch.1.1.1.1.1
  have href : refusal s (Request.mk .insertActive key owner 0 0 out (some ap) []) = none :=
    (refusal_none_iff s _).mpr (Or.inr ⟨ap, rfl, hpol, hmatch, Or.inr (Or.inl ⟨rfl, hfree⟩)⟩)
  exact ⟨applyEdge s (Request.mk .insertActive key owner 0 0 out (some ap) []),
    ok_of_refusal s _ href⟩

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
    (∀ h ∈ s.held, h.kind = .terminal → trieGet s.trie h.key = .known .terminal) ∧
    (∀ n : Nat, ∃ (u : RegistryState), Reachable u ∧
      kindCount u .terminal key = kindCount s .terminal key + n ∧
      trieGet u.trie key = .known .terminal) := by
  have hroot : s.config.root = rootOf s.trie := (reachable_consistent s h).1
  have hmint : ∀ (u : RegistryState) (o : Nat), Reachable u → u.config.root = rootOf u.trie →
      trieGet u.trie key = .known .terminal →
      ∃ v, step u (Request.mk .witnessTerminal key 0 0 0 o none [(.terminal, 1)]) = .ok v ∧
        Reachable v.state ∧ v.state.config = u.config ∧ v.state.trie = u.trie ∧
        kindCount v.state .terminal key = kindCount u .terminal key + 1 := by
    intro u o hu hru htu
    have hr : readAt u 0 key .terminal = true := (readAt_true_iff u key).mpr ⟨hru, htu⟩
    have href : refusal u (Request.mk .witnessTerminal key 0 0 0 o none [(.terminal, 1)]) = none :=
      (refusal_none_iff u _).mpr (Or.inl ⟨rfl, hr⟩)
    obtain ⟨h1, h2, _, h4, _, _⟩ :=
      applyEdge_witnessTerminal u (Request.mk .witnessTerminal key 0 0 0 o none [(.terminal, 1)]) rfl
    refine ⟨applyEdge u (Request.mk .witnessTerminal key 0 0 0 o none [(.terminal, 1)]), ?_, ?_, h2, h1, ?_⟩
    · exact ok_of_refusal u _ href
    · exact Reachable.next hu (ok_of_refusal u _ href)
    · simp [kindCount, h4, countHeld_cons]
  refine ⟨?_, fun hh hmem hk => (reachable_consistent s h).2.2.2.2.2.1 _ hmem hk, ?_⟩
  · obtain ⟨v, hstep, _, _, _, hcount⟩ := hmint s out h hroot hterm
    exact ⟨v, hstep, hcount⟩
  · intro n
    induction n with
    | zero => exact ⟨s, h, by simp, hterm⟩
    | succ k ih =>
      obtain ⟨u, hu, hcount, hleaf⟩ := ih
      have hru : u.config.root = rootOf u.trie := (reachable_consistent u hu).1
      obtain ⟨v, _, hv, hcfg, htrie, hvc⟩ := hmint u out hu hru hleaf
      exact ⟨v.state, hv, by rw [hvc, hcount]; omega, by rw [htrie]; exact hleaf⟩

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
    t.state.held = s.held ∧ t.mint = [((.absent, r.key), 1)] ∧ t.paid = [] := by
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
    t.mint = [((.active, r.key), 1)] ∧ t.paid = [] := by
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
    t.mint = [((.absent, r.key), -1), ((.active, r.key), 1)] ∧
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
    t.mint = [((.active, r.key), -1)] ∧ t.paid = [] := by
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
    t.state.trie = trieErase s.trie r.key ∧
    t.state.config = { s.config with root := rootOf (trieErase s.trie r.key) } ∧
    t.state.custody = s.custody.filter (·.key != r.key) ∧
    t.state.held = s.held ∧
    t.mint = [((.absent, r.key), -1)] ∧ t.paid = [(c.refundAddress, c.value)] := by
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
    t.state.trie = trieErase s.trie r.key ∧
    t.state.config = { s.config with root := rootOf (trieErase s.trie r.key) } ∧
    t.state.custody = s.custody ∧
    t.state.held = (s.held.filter fun h => !(h.key == r.key && h.kind == .active)) ∧
    t.mint = [((.active, r.key), -1)] ∧ t.paid = [] := by
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
    t.mint = [((.terminal, r.key), 1)] ∧ t.paid = [] := by
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
    ∃ m r, step s b = .ok m ∧ foldActions m.state bs = .ok r ∧
      t = { state := r.state, mint := assetPlus m.mint r.mint, paid := m.paid ++ r.paid } ∧
      assetSame (claimedMint (b :: bs)) (actualMint (b :: bs)) := by
  constructor
  · intro hok
    have hacts := (foldBatch_inv s (b :: bs) t hok).2
    have hdelta : assetSame (claimedMint (b :: bs)) (actualMint (b :: bs)) := by
      unfold foldBatch at hok
      rw [if_neg (by simp)] at hok
      rw [hacts] at hok
      simp only [bind, Except.bind, pure, Except.pure] at hok
      split at hok
      · assumption
      · exact Except.noConfusion hok
    unfold foldActions at hacts
    simp only [bind, Except.bind, pure, Except.pure] at hacts
    cases hs : step s b with
    | error e => rw [hs] at hacts; exact Except.noConfusion hacts
    | ok m =>
      rw [hs] at hacts
      simp only [bind, Except.bind, pure, Except.pure] at hacts
      cases hr : foldActions m.state bs with
      | error e => rw [hr] at hacts; exact Except.noConfusion hacts
      | ok r =>
        rw [hr] at hacts
        have hEq : combineResults m r = t := by injection hacts
        exact ⟨m, r, rfl, hr, by rw [← hEq]; rfl, hdelta⟩
  · rintro ⟨m, r, hs, hr, hEq, hdelta⟩
    unfold foldBatch
    rw [if_neg (by simp)]
    have hacts : foldActions s (b :: bs) = .ok t := by
      unfold foldActions
      simp only [bind, Except.bind, pure, Except.pure]
      rw [hs]
      simp only [bind, Except.bind, pure, Except.pure]
      rw [hr, hEq]
      rfl
    rw [hacts]
    simp only [bind, Except.bind, pure, Except.pure]
    split
    · rfl
    · rename_i hc; exact absurd hdelta hc

/-- A read changes nothing: the leaf, the root and custody survive an admitted
`witnessTerminal` step unchanged. -/
theorem read_changes_nothing (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .witnessTerminal) (hok : step s r = .ok t) :
    t.state.trie = s.trie ∧ t.state.config = s.config ∧ t.state.custody = s.custody := by
  obtain ⟨_, ht⟩ := step_eq_ok s r t hok
  subst ht
  obtain ⟨h1, h2, h3, _, _, _⟩ := applyEdge_witnessTerminal s r he
  exact ⟨h1, h2, h3⟩

/-- The whole transaction an admitted absent insertion builds. The custody
payload has one field, the refund address; its identity is recovered from its
sole absent asset. The deposit is held: the cage output carries it, and the
transaction's one payment is that deposit, to custody at the cage's address.
Reachability supplies witness uniqueness, not the transaction equation. -/
theorem insert_absent_transaction_row (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat) (h : Reachable s) (he : r.edge = .insertAbsent)
    (hap : r.approval = some ap) (hok : step s r = .ok t)
    (hfee : s.config.maxFee ≤ lovelace) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0 }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := [] }
              , { role := .destination, datum := .inline, address := some 0
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [] }
              , { role := .cage, datum := .inline, address := some 0
                , stateTokens := 0, config := none, commitment := none
                , assets := [((.absent, r.key), 1)]
                , custodyDatum := some [r.refundAddress], lovelace := r.deposit } ]
          , mint := [((.absent, r.key), 1)], signers := []
          , refunds := [(0, r.deposit)] } ∧
    (txCageOutputs t r).map custodyKey = [some r.key] ∧
    lovelaceCoversTip s.config lovelace = true ∧
    destinationDatumBinds r = true ∧
    trieGet s.trie r.key = .unknown ∧
    t.state.trie = trieSet s.trie r.key (.known .absent) ∧
    onlyRootChanged s.config t.state.config = true ∧
    t.state.config.root = rootOf t.state.trie ∧
    t.state.custody =
      { key := r.key, refundAddress := r.refundAddress, value := r.deposit } :: s.custody ∧
    t.state.held = s.held ∧
    custodyCount t.state r.key = 1 ∧
    kindPolicy s.config .absent = s.config.absentPolicy ∧
    tokenAssetName .absent r.key = r.key := by
  obtain ⟨hfree, ⟨ap', hap', hpol, hedge, hkey, hown, hdst, hasset⟩,
    htrie, hcfg, hcust, hheld, hmint, hpaid⟩ := (insert_absent_inversion s r t he).mp hok
  have hapeq : ap' = ap := Option.some.inj (hap'.symm.trans hap)
  rw [hapeq] at hpol hedge hkey hown hdst hasset
  have hbind : datumHash (destinationDatum r) = ap.assetName := by
    unfold datumHash destinationDatum
    rw [hasset, hedge, hkey, hown, hdst]
  have hdest : requestDestination r = 0 := by simp [requestDestination, he]
  have happrovals : approvalsIn r = 1 := by rw [approvalsIn, hap]; rfl
  have hrouted : routedPayment t r .requestOutput = [] := by
    simp +decide [routedPayment, mintRoutedTo, hmint, route]
  have hcage : txCageOutputs t r =
      [{ role := .cage, datum := .inline, address := some 0
       , stateTokens := 0, config := none, commitment := none
       , assets := [((.absent, r.key), 1)]
       , custodyDatum := some [r.refundAddress], lovelace := r.deposit }] := by
    simp +decide [txCageOutputs, routedPayment, mintRoutedTo, hmint, route, registryDatumForm]
  have hburn : txBurnInputs t r = [] := by simp [txBurnInputs, hmint]
  have htx : txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0 }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := [] }
              , { role := .destination, datum := .inline, address := some 0
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [] }
              , { role := .cage, datum := .inline, address := some 0
                , stateTokens := 0, config := none, commitment := none
                , assets := [((.absent, r.key), 1)]
                , custodyDatum := some [r.refundAddress], lovelace := r.deposit } ]
          , mint := [((.absent, r.key), 1)], signers := []
          , refunds := [(0, r.deposit)] } := by
    rw [txOf_of_step_ok s r lovelace t hok]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid, cageAddress, txStateOutput,
      txDestinationOutput, hcage, hburn, happrovals, hdest, hrouted, hbind, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
  have hcount : custodyCount t.state r.key = 1 :=
    (absent_witness_unique t.state (Reachable.next h hok) r.key).2.mpr
      (by rw [htrie, trieGet_set_eq])
  exact ⟨htx, by simp [hcage, custodyKey], by simpa [lovelaceCoversTip] using hfee,
    by simp [destinationDatumBinds, hap, hbind], hfree, htrie,
    by simp [onlyRootChanged, hcfg], by rw [hcfg, htrie], hcust, hheld, hcount, rfl, rfl⟩

/-- **#173 T1** — the transaction an admitted `insertActive` builds.

The conclusion is one equation on the transaction `txOf` constructs from the
executed step, so every clause quantifies over a built value rather than over a
nullary constant. It spends two inputs — the registry's single state UTxO under
an inline datum, and a request UTxO carrying exactly one approval and the
lovelace that covers the tip — and produces exactly two outputs: the state UTxO
moved, still carrying one state token under an inline datum, whose eight-field
configuration differs from the input's in the root alone and whose root commits
the map the fold produced; and a destination output routed to the address the
request named, whose inline datum presents the very commitment the approval the
fold verified carries, holding exactly one active token and the deposit. The
mint is `+1` at `(activePolicy, key)` and nothing else, the transaction's one
payment is that deposit, to the destination, and the signer set is empty.

No signature is required, stated as invariance of the whole transaction under
the approval's signature set. A second `insertActive` at the same key builds no
transaction at all: it is refused `key-exists`. The open application is
unparameterised and admits every tuple, and cross-registry separation is a named
non-goal — registries pinning the same open policy reach the same verdict on the
same approval. -/
theorem insert_active_transaction_row (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat) (h : Reachable s) (he : r.edge = .insertActive)
    (hap : r.approval = some ap) (hok : step s r = .ok t)
    (hfee : s.config.maxFee ≤ lovelace) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0 }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := [] }
              , { role := .destination, datum := .inline, address := some r.output
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [((.active, r.key), 1)], lovelace := r.deposit } ]
          , mint := [((.active, r.key), 1)]
          , signers := []
          , refunds := [(r.output, r.deposit)] } ∧
    lovelaceCoversTip s.config lovelace = true ∧
    destinationDatumBinds r = true ∧
    onlyRootChanged s.config t.state.config = true ∧
    t.state.config.root = rootOf t.state.trie ∧
    t.state.custody = s.custody ∧
    kindCount t.state .active r.key = 1 ∧
    ({ key := r.key, kind := .active, output := r.output } : Holding) ∈ t.state.held ∧
    kindPolicy s.config .active = s.config.activePolicy ∧
    tokenAssetName .active r.key = r.key ∧
    openPolicyParameters = [] ∧
    (∀ sigs : List (List Nat),
        txOf s { r with approval := some { ap with signatures := sigs } } lovelace
          = txOf s r lovelace) ∧
    (∀ r₂ : Request, r₂.edge = .insertActive → r₂.key = r.key →
        admitsFor t.state.config r₂ r₂.approval = true →
        txOf t.state r₂ lovelace = .error "key-exists") ∧
    (∀ (c : Config) (q : Request), admitsFor c q (some (openApproval c q)) = true) ∧
    (∀ (c₁ c₂ : Config) (q : Request) (a : Option Approval),
        c₁.applicationPolicy = c₂.applicationPolicy →
        admitsFor c₁ q a = admitsFor c₂ q a) := by
  obtain ⟨hfree, ⟨ap', hap', hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust,
    hheld, hmint, hpaid⟩ := (insert_active_inversion s r t he).mp hok
  have hapeq : ap' = ap := Option.some.inj (hap'.symm.trans hap)
  rw [hapeq] at hpol hedge hkey hown hdst hasset
  have hadmits : ∀ (c : Config) (q : Request), admitsFor c q (some (openApproval c q)) = true := by
    intro c q
    unfold admitsFor openApproval
    cases hq : q.edge <;> simp [hq, requestDestination, approvalAssetName]
  have hcross : ∀ (c₁ c₂ : Config) (q : Request) (a : Option Approval),
      c₁.applicationPolicy = c₂.applicationPolicy → admitsFor c₁ q a = admitsFor c₂ q a := by
    intro c₁ c₂ q a hc
    unfold admitsFor
    cases q.edge <;> cases a <;> simp [hc]
  have hbind : datumHash (destinationDatum r) = ap.assetName := by
    unfold datumHash destinationDatum
    rw [hasset, hedge, hkey, hown, hdst]
  have hzero : kindCount s .active r.key = 0 := by
    obtain ⟨hle, hiff⟩ := active_witness_unique s h r.key
    rcases Nat.lt_or_ge (kindCount s .active r.key) 1 with hlt | hge
    · omega
    · exfalso
      have h1 : kindCount s .active r.key = 1 := by omega
      rw [hfree] at hiff
      exact Leaf.noConfusion (hiff.mp h1)
  have hcount : kindCount t.state .active r.key = 1 := by
    unfold kindCount
    rw [hheld, countHeld_cons]
    simp only [beq_self_eq_true, Bool.and_self, if_pos]
    have hz : (s.held.filter fun x => x.key == r.key && x.kind == TokenKind.active).length = 0 := hzero
    omega
  have hstep : ∀ sigs : List (List Nat),
      step s { r with approval := some { ap with signatures := sigs } } = .ok t := by
    intro sigs
    refine (insert_active_inversion s _ t (by simpa using he)).mpr ?_
    refine ⟨by simpa using hfree,
      ⟨{ ap with signatures := sigs }, rfl, by simpa using hpol, by simpa using hedge,
        by simpa using hkey, by simpa using hown, by simpa using hdst, by simpa using hasset⟩,
      by simpa using htrie, by simpa using hcfg, hcust, by simpa using hheld,
      by simpa using hmint, hpaid⟩
  have hsecond : ∀ r₂ : Request, r₂.edge = .insertActive → r₂.key = r.key →
      admitsFor t.state.config r₂ r₂.approval = true →
      step t.state r₂ = .error "key-exists" := by
    intro r₂ he₂ hk₂ hadm₂
    have hbefore : trieGet t.state.trie r₂.key = .known .active := by
      rw [hk₂, htrie, trieGet_set_eq]
    cases hopt : r₂.approval with
    | none =>
      rw [hopt] at hadm₂
      unfold admitsFor at hadm₂
      simp [he₂] at hadm₂
    | some a₂ =>
      have hadm₂' : admitsFor t.state.config r₂ (some a₂) = true := by rw [← hopt]; exact hadm₂
      have hpol₂ : a₂.policy = t.state.config.applicationPolicy := by
        unfold admitsFor at hadm₂'
        simp only [he₂, Bool.and_eq_true, beq_iff_eq] at hadm₂'
        exact hadm₂'.1.1.1.1.1
      refine error_of_refusal _ _ _ ?_
      unfold refusal
      simp only [he₂, hopt, hbefore, hadm₂', hpol₂, bne_self_eq_false, Bool.not_true,
        Bool.false_eq_true, if_false, reduceIte]
      simp
  -- the transaction itself
  have hdest : requestDestination r = r.output := by
    unfold requestDestination; simp [he]
  have happrovals : approvalsIn r = 1 := by rw [approvalsIn, hap]; rfl
  have hrouted : routedPayment t r .requestOutput = [((TokenKind.active, r.key), 1)] := by
    unfold routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
  have hcage : txCageOutputs t r = [] := by
    unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
  have hburn : txBurnInputs t r = [] := by
    unfold txBurnInputs; rw [hmint]; simp
  have htx : txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0 }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := [] }
              , { role := .destination, datum := .inline, address := some r.output
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [((.active, r.key), 1)], lovelace := r.deposit } ]
          , mint := [((.active, r.key), 1)]
          , signers := []
          , refunds := [(r.output, r.deposit)] } := by
    rw [txOf_of_step_ok s r lovelace t hok]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid, txStateOutput,
      txDestinationOutput, hcage, hburn, happrovals, hdest, hrouted, hbind, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
  have hsigtx : ∀ sigs : List (List Nat),
      txOf s { r with approval := some { ap with signatures := sigs } } lovelace
        = txOf s r lovelace := by
    intro sigs
    rw [htx, txOf_of_step_ok _ _ lovelace t (hstep sigs)]
    have ha : approvalsIn { r with approval := some { ap with signatures := sigs } } = 1 := by
      rw [approvalsIn]; rfl
    have hd : requestDestination { r with approval := some { ap with signatures := sigs } }
        = r.output := by unfold requestDestination; simp [he]
    have hr : routedPayment t { r with approval := some { ap with signatures := sigs } }
        .requestOutput = [((TokenKind.active, r.key), 1)] := by
      unfold routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
    have hc : txCageOutputs t { r with approval := some { ap with signatures := sigs } } = [] := by
      unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
    have hbi : txBurnInputs t { r with approval := some { ap with signatures := sigs } } = [] := by
      unfold txBurnInputs; rw [hmint]; simp
    have hb : datumHash (destinationDatum
        { r with approval := some { ap with signatures := sigs } }) = ap.assetName := by
      unfold datumHash destinationDatum
      simp only [hd]
      rw [hasset, hedge, hkey, hown, hdst, hdest]
    simp only [txStateOutput, txDestinationOutput, hc, hbi, ha, hd, hr, hb, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid, requestDestination]
  have hsecondtx : ∀ r₂ : Request, r₂.edge = .insertActive → r₂.key = r.key →
      admitsFor t.state.config r₂ r₂.approval = true →
      txOf t.state r₂ lovelace = .error "key-exists" := by
    intro r₂ he₂ hk₂ hadm₂
    exact txOf_of_step_error _ _ _ _ (hsecond r₂ he₂ hk₂ hadm₂)
  exact ⟨htx, by simpa [lovelaceCoversTip] using hfee,
    by simp [destinationDatumBinds, hap, hbind],
    by simp [onlyRootChanged, hcfg], by rw [hcfg, htrie], hcust, hcount,
    by rw [hheld]; exact List.mem_cons_self,
    rfl, rfl, rfl, hsigtx, hsecondtx, hadmits, hcross⟩

/-- **#177 T1** — the transaction an admitted `updateTerminal` builds.

Retirement is the first edge whose mint is negative, so it is the first whose
tokens have to come from somewhere. The conclusion is one equation on the value
`txOf` constructs from the executed step. It spends three inputs — the
registry's single state UTxO under an inline datum; a request UTxO carrying
exactly one approval and the lovelace that covers the tip; and the witness UTxO
holding this key's one active token, spent so the burn has a source — and
produces two outputs: the state UTxO moved, still carrying one state token under
an inline datum, whose eight-field configuration differs from the input's in the
root alone and whose root commits a map where the key now reads `Terminal`; and
a destination output routed to the address the request named, whose inline datum
presents the very commitment the approval the fold verified carries, holding no
token at all, because a burn pays nobody; and an output paying the request's
owner the deposit back, since a retirement delivers nothing, with no datum and
naming the approval it returns. The mint is `-1` at
`(activePolicy, key)` and nothing else, the transaction's one payment is that
deposit, to the owner, and the signer set is empty.

The burned token is this key's own: before the fold the key has exactly one
active witness and after it has none, and the asset the witness input carries is
the `(active, key)` the mint destroys — not another key's token, and not a burn
with nothing to burn.

No signature is required, stated as invariance of the whole transaction under
the approval's signature set. Retirement completes: a second `updateTerminal` at
the same key builds no transaction, it is refused `terminal-immutable`. None
exists for a key that reads `Unknown` (`key-unknown`) or one only witnessed
absent (`not-booked`); each refusal is stated over an arbitrary state and
exhibited at the very state of this fold with that key's leaf moved, so no arm
is vacuous. The `token-missing` guard is exhibited the same way, at this state
with its held witnesses removed. That last one is a guard against an unreachable
state rather than a story: under `Reachable`, `biconditional_supply_sync` makes
a `Known Active` leaf and exactly one outstanding active token the same fact. -/
theorem update_terminal_transaction_row (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat) (h : Reachable s) (he : r.edge = .updateTerminal)
    (hap : r.approval = some ap) (hok : step s r = .ok t)
    (hfee : s.config.maxFee ≤ lovelace) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0, assets := [] }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace, assets := [] }
              , { role := .witness, datum := .inline, stateTokens := 0
                , approvals := 0, lovelace := 0
                , assets := [((.active, r.key), 1)] } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := [] }
              , { role := .destination, datum := .inline, address := some r.output
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [] }
              , { role := .owner, datum := .none, address := some r.owner
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [], lovelace := r.deposit } ]
          , mint := [((.active, r.key), -1)]
          , signers := []
          , refunds := [(r.owner, r.deposit)] } ∧
    kindCount s .active r.key = 1 ∧
    (∃ w ∈ s.held, w.key = r.key ∧ w.kind = .active) ∧
    kindCount t.state .active r.key = 0 ∧
    lovelaceCoversTip s.config lovelace = true ∧
    destinationDatumBinds r = true ∧
    onlyRootChanged s.config t.state.config = true ∧
    t.state.config.root = rootOf t.state.trie ∧
    trieGet t.state.trie r.key = .known .terminal ∧
    t.state.custody = s.custody ∧
    kindPolicy s.config .active = s.config.activePolicy ∧
    tokenAssetName .active r.key = r.key ∧
    (∀ sigs : List (List Nat),
        txOf s { r with approval := some { ap with signatures := sigs } } lovelace
          = txOf s r lovelace) ∧
    (∀ r₂ : Request, r₂.edge = .updateTerminal → r₂.key = r.key →
        admitsFor t.state.config r₂ r₂.approval = true →
        txOf t.state r₂ lovelace = .error "terminal-immutable") ∧
    (∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
        trieGet s'.trie r'.key = .unknown →
        admitsFor s'.config r' r'.approval = true →
        txOf s' r' lovelace = .error "key-unknown") ∧
    (∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
        trieGet s'.trie r'.key = .known .absent →
        admitsFor s'.config r' r'.approval = true →
        txOf s' r' lovelace = .error "not-booked") ∧
    (∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
        trieGet s'.trie r'.key = .known .active →
        s'.held.any (fun x => x.key == r'.key && x.kind == .active) = false →
        admitsFor s'.config r' r'.approval = true →
        txOf s' r' lovelace = .error "token-missing") ∧
    txOf { s with trie := trieErase s.trie r.key } r lovelace
      = .error "key-unknown" ∧
    txOf { s with trie := trieSet s.trie r.key (.known .absent) } r lovelace
      = .error "not-booked" ∧
    txOf { s with held := [] } r lovelace = .error "token-missing" := by
  obtain ⟨hbefore, hpres, ⟨ap', hap', hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg,
    hcust, hheld, hmint, hpaid⟩ := (update_terminal_inversion s r t he).mp hok
  have hapeq : ap' = ap := Option.some.inj (hap'.symm.trans hap)
  rw [hapeq] at hpol hedge hkey hown hdst hasset
  -- admission, reassembled so the refusal rows can be stated at other states
  have hadm : admitsFor s.config r r.approval = true := by
    unfold admitsFor
    rw [hap]
    simp only [he]
    simp only [Bool.and_eq_true, beq_iff_eq]
    exact ⟨⟨⟨⟨⟨hpol, by rw [hedge, he]⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
  -- the complement of the updateTerminal row, computed once
  have hrefusalOf : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      admitsFor s'.config r' r'.approval = true →
      refusal s' r' =
        (match trieGet s'.trie r'.key with
         | .unknown => some "key-unknown"
         | .known .absent => some "not-booked"
         | .known .terminal => some "terminal-immutable"
         | .known .active =>
             if s'.held.any (fun x => x.key == r'.key && x.kind == .active) then none
             else some "token-missing") := by
    intro s' r' he' hadm'
    cases hb : trieGet s'.trie r'.key <;>
      (try (rename_i st; cases st)) <;>
      cases hap₂ : r'.approval <;>
      cases hac : s'.held.any (fun x => x.key == r'.key && x.kind == .active) <;>
      simp +decide [refusal, he', hb, hap₂, hac, admitsFor] at hadm' ⊢ <;>
      grind
  have hrefuseTx : ∀ (s' : RegistryState) (r' : Request) (why : String),
      refusal s' r' = some why → txOf s' r' lovelace = .error why := by
    intro s' r' why hr
    exact txOf_of_step_error _ _ _ _ (error_of_refusal _ _ _ hr)
  -- the source of the burn: the key's unique active witness
  have hone : kindCount s .active r.key = 1 := (active_witness_unique s h r.key).2.mpr hbefore
  have hwitness : ∃ w ∈ s.held, w.key = r.key ∧ w.kind = .active := by
    obtain ⟨w, hw, hcond⟩ := List.any_eq_true.mp hpres
    obtain ⟨h1, h2⟩ := Bool.and_eq_true_iff.mp hcond
    exact ⟨w, hw, by simpa using h1, by simpa using h2⟩
  have hgone : kindCount t.state .active r.key = 0 := by
    unfold kindCount
    rw [hheld]
    exact countHeld_filter_active_zero s.held r.key
  have hterminal : trieGet t.state.trie r.key = .known .terminal := by
    rw [htrie, trieGet_set_eq]
  -- the transaction itself
  have hdest : requestDestination r = r.output := by
    unfold requestDestination; simp [he]
  have happrovals : approvalsIn r = 1 := by rw [approvalsIn, hap]; rfl
  have hbind : datumHash (destinationDatum r) = ap.assetName := by
    unfold datumHash destinationDatum
    rw [hasset, hedge, hkey, hown, hdst]
  have hrouted : routedPayment t r .requestOutput = [] := by
    unfold routedPayment mintRoutedTo; rw [hmint]; simp [route]
  have hcage : txCageOutputs t r = [] := by
    unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route]
  have hburn : txBurnInputs t r =
      [ { role := .witness, datum := registryDatumForm, stateTokens := 0
        , approvals := 0, lovelace := 0
        , assets := [((TokenKind.active, r.key), 1)] } ] := by
    unfold txBurnInputs; rw [hmint]; simp [route, burnSourceRole]
  have htx : txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0, assets := [] }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace, assets := [] }
              , { role := .witness, datum := .inline, stateTokens := 0
                , approvals := 0, lovelace := 0
                , assets := [((.active, r.key), 1)] } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := [] }
              , { role := .destination, datum := .inline, address := some r.output
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [] }
              , { role := .owner, datum := .none, address := some r.owner
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [], lovelace := r.deposit } ]
          , mint := [((.active, r.key), -1)]
          , signers := []
          , refunds := [(r.owner, r.deposit)] } := by
    rw [txOf_of_step_ok s r lovelace t hok]
    simp [he, hap, obligations, owedTo, ownerOutputs, paymentPaid, txStateOutput,
      txDestinationOutput, hcage, hburn, happrovals, hdest, hrouted, hbind, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
  -- no signature is read
  have hstep : ∀ sigs : List (List Nat),
      step s { r with approval := some { ap with signatures := sigs } } = .ok t := by
    intro sigs
    refine (update_terminal_inversion s _ t (by simpa using he)).mpr ?_
    refine ⟨by simpa using hbefore, by simpa using hpres,
      ⟨{ ap with signatures := sigs }, rfl, by simpa using hpol, by simpa using hedge,
        by simpa using hkey, by simpa using hown, by simpa using hdst, by simpa using hasset⟩,
      by simpa using htrie, by simpa using hcfg, hcust, by simpa using hheld,
      by simpa using hmint, hpaid⟩
  have hsigtx : ∀ sigs : List (List Nat),
      txOf s { r with approval := some { ap with signatures := sigs } } lovelace
        = txOf s r lovelace := by
    intro sigs
    rw [htx, txOf_of_step_ok _ _ lovelace t (hstep sigs)]
    have ha : approvalsIn { r with approval := some { ap with signatures := sigs } } = 1 := by
      rw [approvalsIn]; rfl
    have hd : requestDestination { r with approval := some { ap with signatures := sigs } }
        = r.output := by unfold requestDestination; simp [he]
    have hr : routedPayment t { r with approval := some { ap with signatures := sigs } }
        .requestOutput = [] := by
      unfold routedPayment mintRoutedTo; rw [hmint]; simp [route]
    have hc : txCageOutputs t { r with approval := some { ap with signatures := sigs } } = [] := by
      unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route]
    have hbi : txBurnInputs t { r with approval := some { ap with signatures := sigs } } =
        [ { role := .witness, datum := registryDatumForm, stateTokens := 0
          , approvals := 0, lovelace := 0
          , assets := [((TokenKind.active, r.key), 1)] } ] := by
      unfold txBurnInputs; rw [hmint]; simp [route, burnSourceRole]
    have hb : datumHash (destinationDatum
        { r with approval := some { ap with signatures := sigs } }) = ap.assetName := by
      unfold datumHash destinationDatum
      simp only [hd]
      rw [hasset, hedge, hkey, hown, hdst, hdest]
    simp only [txStateOutput, txDestinationOutput, hc, hbi, ha, hd, hr, hb, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid]
  -- retirement completes, and the two leaves that never admit it
  have himmutable : ∀ r₂ : Request, r₂.edge = .updateTerminal → r₂.key = r.key →
      admitsFor t.state.config r₂ r₂.approval = true →
      txOf t.state r₂ lovelace = .error "terminal-immutable" := by
    intro r₂ he₂ hk₂ hadm₂
    refine hrefuseTx _ _ _ ?_
    rw [hrefusalOf t.state r₂ he₂ hadm₂, hk₂, hterminal]
  have hunknown : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      trieGet s'.trie r'.key = .unknown →
      admitsFor s'.config r' r'.approval = true →
      txOf s' r' lovelace = .error "key-unknown" := by
    intro s' r' he' hl hadm'
    exact hrefuseTx _ _ _ (by rw [hrefusalOf s' r' he' hadm', hl])
  have hnotbooked : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      trieGet s'.trie r'.key = .known .absent →
      admitsFor s'.config r' r'.approval = true →
      txOf s' r' lovelace = .error "not-booked" := by
    intro s' r' he' hl hadm'
    exact hrefuseTx _ _ _ (by rw [hrefusalOf s' r' he' hadm', hl])
  have hmissing : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      trieGet s'.trie r'.key = .known .active →
      s'.held.any (fun x => x.key == r'.key && x.kind == .active) = false →
      admitsFor s'.config r' r'.approval = true →
      txOf s' r' lovelace = .error "token-missing" := by
    intro s' r' he' hl hno hadm'
    refine hrefuseTx _ _ _ ?_
    rw [hrefusalOf s' r' he' hadm', hl]
    simp [hno]
  exact ⟨htx, hone, hwitness, hgone, by simpa [lovelaceCoversTip] using hfee,
    by simp [destinationDatumBinds, hap, hbind],
    by simp [onlyRootChanged, hcfg], by rw [hcfg, htrie], hterminal, hcust, rfl, rfl,
    hsigtx, himmutable, hunknown, hnotbooked, hmissing,
    hunknown _ r he (by simp) hadm,
    hnotbooked _ r he (by simp) hadm,
    hmissing _ r he (by simpa using hbefore) (by simp) (by simpa using hadm)⟩

/-- **#173 T1** — the fold's mint guard is per `(TokenKind, Key)`.

An accepted fold's claimed and actual keyed sums agree; a nonempty batch whose
every request applies but whose keyed sums differ is refused
`net-mint-mismatch`; and the guard is strictly finer than a per-kind one. The
third clause is not a bare existential mismatch: it exhibits a reachable state
and two booking requests that both apply there, whose per-kind totals agree at
every kind, whose keyed sums differ, and whose fold is *observed* to be
`.error "net-mint-mismatch"` from that state. The bridge from "the sums differ"
to "the batch is refused" is inside the statement, not left to the reader. -/
theorem fold_batch_claimed_mint_by_kind_key :
    (∀ (s : RegistryState) (batch : List Request) (t : Result),
        foldBatch s batch = .ok t → assetSame (claimedMint batch) (actualMint batch) = true) ∧
    (∀ (s : RegistryState) (batch : List Request) (m : Result),
        batch ≠ [] → foldActions s batch = .ok m →
        assetSame (claimedMint batch) (actualMint batch) = false →
        foldBatch s batch = .error "net-mint-mismatch") ∧
    (∃ (s : RegistryState) (b₁ b₂ : Request) (m : Result),
        Reachable s ∧
        b₁.edge = .insertActive ∧ b₂.edge = .insertActive ∧ b₁.key ≠ b₂.key ∧
        foldActions s [b₁, b₂] = .ok m ∧
        (∀ k : TokenKind, assetKindTotal (claimedMint [b₁, b₂]) k
                        = assetKindTotal (actualMint [b₁, b₂]) k) ∧
        assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false ∧
        foldBatch s [b₁, b₂] = .error "net-mint-mismatch") := by
  refine ⟨?_, ?_, ?_⟩
  · intro s batch t hok
    obtain ⟨hne, hacts⟩ := foldBatch_inv s batch t hok
    unfold foldBatch at hok
    rw [if_neg (by simpa using hne)] at hok
    rw [hacts] at hok
    simp only [bind, Except.bind, pure, Except.pure] at hok
    split at hok
    · assumption
    · exact Except.noConfusion hok
  · intro s batch m hne hacts hfalse
    unfold foldBatch
    rw [if_neg (by simpa using hne)]
    rw [hacts]
    simp only [bind, Except.bind, pure, Except.pure]
    rw [if_neg (by simp [hfalse])]
    rfl
  · refine ⟨{ config := { Oracle.referenceConfig with root := rootOf [] }
            , trie := [], custody := [], held := [] },
      { edge := .insertActive, key := 5, owner := 0, output := 555
      , approval := some { policy := 7, edge := .insertActive, key := 5, owner := 0
                         , destination := 555
                         , assetName := approvalAssetName .insertActive 5 0 555 }
      , claimed := [(.active, 2)] },
      { edge := .insertActive, key := 6, owner := 0, output := 555
      , approval := some { policy := 7, edge := .insertActive, key := 6, owner := 0
                         , destination := 555
                         , assetName := approvalAssetName .insertActive 6 0 555 }
      , claimed := [] },
      _, Reachable.initial _, rfl, rfl, by decide, rfl, ?_, by decide, rfl⟩
    intro k
    cases k <;> rfl

/-- Nobody must sign a fold, at any of the seven edges.

For every state, every request of every edge and every lovelace: a transaction
the model builds requires no signer, and neither the step nor the transaction
changes when the request's approval carries a different signature set. The
empty signer list is therefore a consequence of the law — no refusal and no
edge reads a signature — rather than a default the transaction happens to
carry. -/
theorem fold_requires_no_signer (s : RegistryState) (r : Request) (lovelace : Nat)
    (sigs : List (List Nat)) :
    (∀ tx : Tx, txOf s r lovelace = .ok tx → tx.signers = []) ∧
    step s (withSignatures r sigs) = step s r ∧
    txOf s (withSignatures r sigs) lovelace = txOf s r lovelace := by
  obtain ⟨edge, key, owner, refundAddress, deposit, output, approval, claimed, tip⟩ := r
  refine ⟨?_, ?_, ?_⟩
  · intro tx h
    cases hs : step s ⟨edge, key, owner, refundAddress, deposit, output, approval, claimed, tip⟩ with
    | error why => rw [txOf_of_step_error _ _ _ _ hs] at h; exact Except.noConfusion h
    | ok t =>
      rw [txOf_of_step_ok _ _ _ _ hs] at h
      injection h with h
      rw [← h]
      rfl
  -- Every field the step and the transaction read is the same field of the
  -- same request: only the signature set moved, and nothing reads it.
  · cases approval <;> rfl
  · cases approval <;> rfl

/-- Value an exit does not owe is unconstrained, for every exit alike.

For every exit, every request and any two lists of transaction outputs: when each
recipient the exit owes receives, through the outputs that pay it by role and
address, at least as much lovelace from the second list as from the first, the
second list settles whenever the first does. Adding outputs, or adding lovelace to
an output, therefore never turns a settled transaction into an unsettled one, and
whether a transaction settles depends only on the lovelace reaching the recipients
the exit owes: fees, the folder's tip and every output that pays none of them play
no part. -/
theorem exit_settles_on_lovelace_received (exit : Exit) (request : Request)
    (outputs more : List TxOutput)
    (received : ∀ payment ∈ obligations exit request,
      (outputs.filter (paysRecipient payment.recipient)).foldl (· + ·.lovelace) 0 ≤
        (more.filter (paysRecipient payment.recipient)).foldl (· + ·.lovelace) 0) :
    settle (obligations exit request) outputs = none →
    settle (obligations exit request) more = none := by
  -- `settle` judges each recipient the payments name once; a recipient is judged
  -- on the lovelace of the outputs paying it, which `received` says only grows.
  have named : ∀ (l acc : List Recipient) (recipient : Recipient),
      recipient ∈ List.eraseDupsBy.loop (· == ·) l acc → recipient ∈ l ∨ recipient ∈ acc := by
    intro l
    induction l with
    | nil => intro acc recipient h; exact .inr (by simpa [List.eraseDupsBy.loop] using h)
    | cons head tail ih =>
      intro acc recipient h
      simp only [List.eraseDupsBy.loop] at h
      split at h
      · rcases ih _ _ h with h | h
        · exact .inl (List.mem_cons_of_mem _ h)
        · exact .inr h
      · rcases ih _ _ h with h | h
        · exact .inl (List.mem_cons_of_mem _ h)
        · rcases List.mem_cons.mp h with h | h
          · exact .inl (h ▸ List.mem_cons_self)
          · exact .inr h
  intro settled
  unfold settle at settled ⊢
  rw [List.findSome?_eq_none_iff] at settled ⊢
  intro recipient judged
  have owed := (named _ [] recipient judged).resolve_right (by simp)
  obtain ⟨payment, owedPayment, rfl⟩ := List.mem_map.mp owed
  have before := settled _ judged
  dsimp only at before ⊢
  split at before
  · next paid => rw [if_pos (Nat.le_trans paid (received payment owedPayment))]
  · cases before

/-- No exit strands a deposit.

For every exit and every request, some payment the exit owes is at least the
request's deposit: however a request ends, its deposit is owed to somebody. -/
theorem no_exit_strands_the_deposit (exit : Exit) (request : Request) :
    ∃ payment ∈ obligations exit request, request.deposit ≤ payment.atLeast := by
  cases exit with
  | fold edge => cases edge <;> simp [obligations]
  | reject => simp [obligations]
  | retract => simp [obligations]

/-- Only a retract owes the tip.

For every exit: what the exit owes is the same for every request whatever tip the
request holds exactly when the exit is not a retract. Every other exit leaves the
tip to the folder, and a retract's obligations change with it. -/
theorem only_retract_owes_the_tip (exit : Exit) :
    (∀ (request : Request) (tip : Nat),
      obligations exit { request with tip := tip } = obligations exit request) ↔
    exit ≠ .retract := by
  constructor
  · intro unchanged retract
    subst retract
    have tipped := unchanged { edge := .insertAbsent, key := 0 } 1
    simp [obligations] at tipped
  · intro notRetract request tip
    cases exit with
    | fold edge => cases edge <;> rfl
    | reject => rfl
    | retract => exact absurd rfl notRetract

/-- What an exit owes is read off the request alone.

For every exit and any two requests with the same owner, deposit, tip and
destination, the exit owes the same payments. The obligations read no registry
state, and nothing else of the request: not its edge beyond the destination it
names, its key, its refund address, its approval or its claimed mint. -/
theorem obligations_read_only_the_request (exit : Exit) (request other : Request)
    (sameOwner : other.owner = request.owner) (sameDeposit : other.deposit = request.deposit)
    (sameTip : other.tip = request.tip)
    (sameDestination : requestDestination other = requestDestination request) :
    obligations exit other = obligations exit request := by
  cases exit with
  | fold edge => cases edge <;> simp [obligations, *]
  | reject | retract => simp [obligations, *]

/-- Every transaction an exit builds pays what the exit owes.

For every registry state, every exit, every request and every lovelace: a
transaction the model builds for the exit settles the exit's obligations — the
deposit reaches the cage for an absent insertion, the named destination for a
fold delivering a token, and the owner for a fold delivering nothing, a reject
and a retract, which also returns the tip. -/
theorem built_transaction_settles (state : RegistryState) (exit : Exit) (request : Request)
    (lovelace : Nat) (tx : Tx) (built : txOfExit state exit request lovelace = .ok tx) :
    settle (obligations exit request) tx.outputs = none := by
  cases hstep : exitStep state exit request with
  | error why => simp [txOfExit, hstep] at built
  | ok t =>
    cases exit with
    | reject =>
      simp only [txOfExit, hstep, Except.ok.injEq] at built
      subst built
      apply settle_one
      simp +decide [obligations, ownerOutputs, paysRecipient]
    | retract =>
      simp only [txOfExit, hstep, Except.ok.injEq] at built
      subst built
      apply settle_one
      simp +decide [obligations, ownerOutputs, paysRecipient]
    | fold e =>
      simp only [exitStep] at hstep
      by_cases he : request.edge = e
      · subst he
        cases hs : step state request with
        | error why => simp [hs] at hstep
        | ok s' =>
          obtain ⟨_, happ⟩ := step_eq_ok _ _ _ hs
          simp only [txOfExit, exitStep, beq_self_eq_true, if_true, hs, Except.ok.injEq] at built
          subst built
          cases hedge : request.edge <;> simp only [hedge, obligations] <;> apply settle_one <;>
            simp +decide [paysRecipient, txDestinationOutput, owedTo, ownerOutputs, txCageOutputs,
              routedPayment, mintRoutedTo, happ, applyEdge, assetDelta, hedge, delta, route,
              requestDestination]
      · simp [he] at hstep

/-- What an executed retract pays is exactly what it owes.

For every registry state and every request: the retract exit executes, leaves the
state as it was, mints nothing, and pays exactly its obligations — the deposit and
the tip, to the owner — each recorded at the address `settle` reads for its
recipient. Nothing the state holds enters what a retract pays. -/
theorem retract_pays_exactly_its_obligations (state : RegistryState) (request : Request) :
    exitStep state .retract request =
      .ok { state := state, mint := [], paid := (obligations .retract request).map paymentPaid } := by
  simp [exitStep, emptyResult]

end Statements
end Singular
