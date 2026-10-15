import Singular.Lemmas
import Singular.Driver
import Singular.Economics

/-! Configuration, approvals, reachability, supply, occupancy and witness laws. -/

namespace Singular.Statements

/-- Every successful fold step preserves the one minimum tip, registration
cost, maximum booking width, registry identity, windows and policy pins. -/
theorem parameters_preserved_by_fold (s : RegistryState) (r : Request) (t : Result)
    (h : step s r = .ok t) : onlyRootChanged s.config t.state.config = true ∧
    t.state.config.minimumTip = s.config.minimumTip := by
  rw [step_config_root s r t h]
  simp [onlyRootChanged]

/-- Every successful atomic batch preserves every parameter, including when a
later request reads a state produced by an earlier request in that batch. -/
theorem parameters_preserved_by_batch (s : RegistryState) (batch : List Action) (t : Result)
    (h : foldBatch s batch = .ok t) : onlyRootChanged s.config t.state.config = true ∧
    t.state.config.minimumTip = s.config.minimumTip := by
  have hf := (foldBatch_inv s batch t h).2
  rw [foldActions_config_root s batch t hf]
  simp [onlyRootChanged]



/-- Every admitted operation carries the exact application approval and preserves all pins. -/
theorem no_tree_change_without_approval (s : RegistryState) (r : Request) (t : Result)
    (h : Reachable s) (hok : step s r = .ok t) :
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
  obtain ⟨ap, hap, hpol, hadm, hcase⟩ := (refusal_none_iff s r).mp href
  rcases hcase with ⟨he, _⟩ | ⟨he, _, _⟩ <;>
    unfold admitsFor at hadm <;>
    rw [hap] at hadm <;>
    simp only [Bool.and_eq_true, beq_iff_eq] at hadm <;>
    obtain ⟨⟨⟨⟨⟨_, hedge⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩ := hadm <;>
    exact ⟨⟨ap, hap, hpol, by rw [hedge, he], hkey, hown, hdst, hasset⟩,
      by simp [applyEdge, he], by simp [applyEdge, he],
      by simp [applyEdge, he], by simp [applyEdge, he]⟩

/-- **request-spent-once-in-order** — each request is spent once and in order (the fold is a step
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
      | error e => rw [hs] at hr; exact nomatch hr
      | ok m =>
        rw [hs] at hr
        simp only [bind, Except.bind, pure, Except.pure] at hr
        cases hrest : foldActions m.state bs with
        | error e => rw [hrest] at hr; exact nomatch hr
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
        | error e => rw [hs] at hr; exact nomatch hr
        | ok m =>
          rw [hs] at hr
          simp only [bind, Except.bind, pure, Except.pure] at hr
          cases hrest : foldActions m.state bs with
          | error e => rw [hrest] at hr; exact nomatch hr
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

/-- **terminal-attestation-sound** — every terminal attestation in a reachable state is about a leaf
that is terminal: no attestation of an Active, Absent or Unknown key exists. -/
theorem terminal_attestation_sound (s : RegistryState) (key : Key) (out : Nat)
    (h : Reachable s) (hmem : { key := key, kind := .terminal, output := out } ∈ s.held) :
    trieGet s.trie key = .known .terminal := by
  exact (reachable_consistent s h).2.2.2.2.2.1 _ hmem rfl



/-- **terminal-attestation-permanent** — a terminal attestation is valid in every later state: a terminal
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
    | error e => rw [hs] at hacts; exact nomatch hacts
    | ok m =>
      rw [hs] at hacts
      simp only [bind, Except.bind, pure, Except.pure] at hacts
      cases hrest : foldActions m.state bs with
      | error e => rw [hrest] at hacts; exact nomatch hacts
      | ok rr =>
        rw [hrest] at hacts
        have hEq : combineResults m rr = t := by injection hacts
        rw [← hEq]
        exact ih m.state rr (Reachable.next h hs)
          (step_preserves_terminal_holding s b m key out hterm hmem hs)
          (step_preserves_terminal s b m key hterm hs) hrest

/-- **supply-matches-leaf-state** — the biconditional supply law, unconditionally over reachable
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

/-- Registration requires an untaken key and leaves exactly an Active leaf. -/
theorem occupancy (s : RegistryState) (r : Request) (t : Result) (h : Reachable s)
    (hok : step s r = .ok t) (hedge : r.edge = .insertActive) :
    trieGet s.trie r.key = .unknown ∧ trieGet t.state.trie r.key = .known .active := by
  obtain ⟨href, ht⟩ := step_eq_ok s r t hok
  subst ht
  obtain ⟨_, _, _, _, hcase⟩ := (refusal_none_iff s r).mp href
  have hb : trieGet s.trie r.key = .unknown := by simpa [hedge] using hcase
  exact ⟨hb, by simp [applyEdge, hedge, trieGet_set_eq]⟩

/-- **booking-requires-untaken-key**, converse: a booking edge on an untaken key, with a matching
approval, succeeds. -/
theorem occupancy_free_key_succeeds (s : RegistryState) (h : Reachable s) (key : Key)
    (owner out : Nat) (hfree : trieGet s.trie key = .unknown)
    (ap : Approval) (hmatch : admitsFor s.config
      { edge := .insertActive, key := key, owner := owner, output := out } (some ap)) :
    ∃ t, step s { edge := .insertActive, key := key, owner := owner, output := out, approval := ap } = .ok t := by
  have hpol : ap.policy = s.config.applicationPolicy := by
    unfold admitsFor at hmatch
    simp only [Bool.and_eq_true, beq_iff_eq] at hmatch
    exact hmatch.1.1.1.1.1
  have href : refusal s (Request.mk .insertActive key owner 0 0 out (some ap) []) = none :=
    (refusal_none_iff s _).mpr ⟨ap, rfl, hpol, hmatch, Or.inl ⟨rfl, hfree⟩⟩
  exact ⟨applyEdge s (Request.mk .insertActive key owner 0 0 out (some ap) []),
    ok_of_refusal s _ href⟩

/-- **terminal-key-cannot-change** — termination: on a terminal key every leaf-moving edge is refused,
forever, so the key stays terminated and is never re-booked. Supersedes the
base `over_terminal`. -/
theorem termination (s : RegistryState) (key : Key) (h : Reachable s)
    (hterm : trieGet s.trie key = .known .terminal) :
    (∀ (r : Request), r.key = key →
        ∃ why, step s r = .error why) ∧
    (∀ (acts : List Request) (t : Result), foldBatch s acts = .ok t →
        trieGet t.state.trie key = .known .terminal) := by
  constructor
  · intro r hkey
    cases hr : refusal s r with
    | some why => exact ⟨why, error_of_refusal s r why hr⟩
    | none =>
      exfalso
      obtain ⟨_, _, _, _, hcase⟩ := (refusal_none_iff s r).mp hr
      rcases hcase with ⟨_, hb⟩ | ⟨_, hb, _⟩ <;>
        (rw [hkey, hterm] at hb; exact absurd hb (by decide))
  · intro acts t hfold
    exact foldActions_preserves_terminal s acts t key hterm (foldBatch_inv s acts t hfold).2

/-- **active-witness-unique** — at most one active token, exactly one iff the leaf is Active. -/
theorem active_witness_unique (s : RegistryState) (h : Reachable s) (key : Key) :
    kindCount s .active key ≤ 1 ∧
    (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) := by
  obtain ⟨_, hA1, hA2, _, _, _, _, _⟩ := reachable_consistent s h
  exact ⟨hA2 key, hA1 key⟩

/-- **absent-witness-unique** — at most one absent witness, exactly one iff the leaf is Absent. -/
theorem absent_witness_unique (s : RegistryState) (h : Reachable s) (key : Key) :
    custodyCount s key ≤ 1 ∧
    (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) := by
  obtain ⟨_, _, _, hC1, hC2, _, _, _⟩ := reachable_consistent s h
  exact ⟨hC2 key, hC1 key⟩



/-- **witness-kinds-exclude** — kind exclusion: at most one kind of witness is outstanding for a
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


end Singular.Statements
