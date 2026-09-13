import Singular.Model

/-! Lawful equality for the derived `BEq` instances and small facts about the model's
helpers. Nothing here is a statement about the protocol; these are the bookkeeping
lemmas the proofs in `Singular.Statements` rely on. -/
namespace Singular

instance : LawfulBEq Value where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> simp_all [BEq.beq, instBEqValue.beq, Value.ctorIdx]
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq Operation where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> simp_all [BEq.beq, instBEqOperation.beq, Operation.ctorIdx]
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq Representative where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqRepresentative.beq _ _ = true at h
    simp only [instBEqRepresentative.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqRepresentative.beq _ _ = true
    simp [instBEqRepresentative.beq]

instance : LawfulBEq Output where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqOutput.beq _ _ = true at h
    simp only [instBEqOutput.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqOutput.beq _ _ = true
    simp [instBEqOutput.beq]

instance : LawfulBEq Proposal where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqProposal.beq _ _ = true at h
    simp only [instBEqProposal.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqProposal.beq _ _ = true
    simp [instBEqProposal.beq]

instance : LawfulBEq Refund where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqRefund.beq _ _ = true at h
    simp only [instBEqRefund.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqRefund.beq _ _ = true
    simp [instBEqRefund.beq]

instance : LawfulBEq Commitment where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> change instBEqCommitment.beq _ _ = true at h <;>
      simp only [instBEqCommitment.beq, Bool.and_eq_true, beq_iff_eq] at h <;> simp_all
  rfl {a} := by
    cases a <;> change instBEqCommitment.beq _ _ = true <;> simp [instBEqCommitment.beq]

instance : LawfulBEq Asset where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqAsset.beq _ _ = true at h
    simp only [instBEqAsset.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqAsset.beq _ _ = true
    simp [instBEqAsset.beq]

instance : LawfulBEq Request where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqRequest.beq _ _ = true at h
    simp only [instBEqRequest.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqRequest.beq _ _ = true
    simp [instBEqRequest.beq]

instance : LawfulBEq ApplicationUTxO where
  eq_of_beq {a b} h := by
    cases a; cases b
    change instBEqApplicationUTxO.beq _ _ = true at h
    simp only [instBEqApplicationUTxO.beq, Bool.and_eq_true, beq_iff_eq] at h
    simp_all
  rfl {a} := by
    cases a; change instBEqApplicationUTxO.beq _ _ = true
    simp [instBEqApplicationUTxO.beq]

@[simp] theorem requireSome_none {α} (reason : String) :
    requireSome (none : Option α) reason = .error reason := rfl

@[simp] theorem requireSome_some {α} (a : α) (reason : String) :
    requireSome (some a) reason = .ok a := rfl

@[simp] theorem entry_key (s : State) (key : Nat) : (entry s key).key = key := by
  unfold entry
  cases h : s.entries.find? (·.key == key) with
  | none => rfl
  | some e => simpa using List.find?_some h

end Singular

namespace Singular

/-! ## Projections through the state combinators -/

@[simp] theorem consume_config (s : State) (id : Nat) : (consume s id).config = s.config := rfl
@[simp] theorem consume_entries (s : State) (id : Nat) : (consume s id).entries = s.entries := rfl
@[simp] theorem consume_used (s : State) (id : Nat) : (consume s id).used = s.used := rfl
@[simp] theorem consume_applications (s : State) (id : Nat) :
    (consume s id).applications = s.applications.filter (·.id != id) := rfl
@[simp] theorem consume_requests (s : State) (id : Nat) :
    (consume s id).requests = s.requests.filter (·.id != id) := rfl
@[simp] theorem setEntry_config (s : State) (e : Entry) : (setEntry s e).config = s.config := rfl
@[simp] theorem setEntry_applications (s : State) (e : Entry) :
    (setEntry s e).applications = s.applications := rfl
@[simp] theorem setEntry_requests (s : State) (e : Entry) : (setEntry s e).requests = s.requests := rfl
@[simp] theorem setEntry_used (s : State) (e : Entry) : (setEntry s e).used = s.used := rfl
theorem setEntry_entries (s : State) (e : Entry) :
    (setEntry s e).entries = e :: s.entries.filter (·.key != e.key) := rfl

theorem entry_of_entries {s s' : State} (h : s.entries = s'.entries) (key : Nat) :
    entry s key = entry s' key := by
  unfold entry; rw [h]

theorem find?_filter_key_ne (l : List Entry) (k k' : Nat) (h : k ≠ k') :
    (l.filter (·.key != k')).find? (·.key == k) = l.find? (·.key == k) := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    by_cases ha : a.key = k
    · rw [List.filter_cons_of_pos (by simp [ha, h]), List.find?_cons_of_pos (by simp [ha]),
        List.find?_cons_of_pos (by simp [ha])]
    · by_cases ha' : a.key = k'
      · rw [List.filter_cons_of_neg (by simp [ha']), List.find?_cons_of_neg (by simp [ha]), ih]
      · rw [List.filter_cons_of_pos (by simp [ha']), List.find?_cons_of_neg (by simp [ha]),
          List.find?_cons_of_neg (by simp [ha]), ih]

theorem entry_setEntry (s : State) (e : Entry) (key : Nat) :
    entry (setEntry s e) key = if e.key = key then e else entry s key := by
  unfold entry
  rw [setEntry_entries]
  by_cases h : e.key = key
  · rw [List.find?_cons_of_pos (by simp [h])]; simp [h]
  · rw [List.find?_cons_of_neg (by simp [h]), find?_filter_key_ne _ _ _ (Ne.symm h)]; simp [h]

theorem representative_of {s s' : State} (key : Nat) (hc : s.config = s'.config)
    (hi : (entry s key).incarnation = (entry s' key).incarnation) :
    representative s key = representative s' key := by
  unfold representative; rw [hc, hi]

@[simp] theorem representative_key (s : State) (key : Nat) : (representative s key).key = key := rfl

theorem representative_key_eq {s s' : State} {k k' : Nat}
    (h : representative s k = representative s' k') : k = k' := by
  simpa using congrArg Representative.key h

theorem supply_eq (s : State) (key : Nat) : supply s key =
    s.applications.countP (fun u => u.output.representative == representative s key) +
    s.requests.countP (fun r => r.held == some (representative s key)) := by
  simp [supply, List.countP_eq_length_filter]

/-! ## Counting through filters on unique identifiers -/

theorem filter_ne_of_forall {α} (id : α → Nat) (l : List α) (k : Nat) (h : ∀ a ∈ l, id a ≠ k) :
    l.filter (fun a => id a != k) = l := by
  rw [List.filter_eq_self]; intro a ha; simpa using h a ha

theorem countP_filter_ne_of_nodup {α} (id : α → Nat) (p : α → Bool) (l : List α) (k : Nat)
    (hn : (l.map id).Nodup) (u : α) (hu : u ∈ l) (hk : id u = k) :
    (l.filter (fun a => id a != k)).countP p + (if p u then 1 else 0) = l.countP p := by
  induction l with
  | nil => simp at hu
  | cons a l ih =>
    rw [List.map_cons, List.nodup_cons] at hn
    obtain ⟨ha, hn⟩ := hn
    rw [List.mem_cons] at hu
    by_cases hak : id a = k
    · have hua : u = a := by
        rcases hu with rfl | hu
        · rfl
        · exact absurd (List.mem_map.mpr ⟨u, hu, hk.trans hak.symm⟩) ha
      subst hua
      rw [List.filter_cons_of_neg (by simp [hak]),
        filter_ne_of_forall id l k (fun x hx hxk => ha (List.mem_map.mpr ⟨x, hx, hxk.trans hak.symm⟩)),
        List.countP_cons]
    · have hul : u ∈ l := by
        rcases hu with rfl | hu
        · exact absurd hk hak
        · exact hu
      rw [List.filter_cons_of_pos (by simp [hak]), List.countP_cons, List.countP_cons, ← ih hn hul]
      omega

theorem countP_filter_le {α} (p q : α → Bool) (l : List α) :
    (l.filter q).countP p ≤ l.countP p := by
  rw [List.countP_filter]
  exact List.countP_mono_left fun a _ h => by simpa using (Bool.and_eq_true _ _ |>.mp h).1

theorem not_mem_of_nodup_append {α} {l₁ l₂ : List α} (hn : (l₁ ++ l₂).Nodup) {x : α}
    (h₁ : x ∈ l₁) : x ∉ l₂ := by
  rw [List.nodup_append] at hn
  exact fun h₂ => hn.2.2 x h₁ x h₂ rfl

theorem not_mem_of_nodup_append' {α} {l₁ l₂ : List α} (hn : (l₁ ++ l₂).Nodup) {x : α}
    (h₂ : x ∈ l₂) : x ∉ l₁ := by
  rw [List.nodup_append] at hn
  exact fun h₁ => hn.2.2 x h₁ x h₂ rfl

end Singular

namespace Singular

/-! ## Exact inversions of the transition function -/

theorem createInsert_ok (s : State) (r : Request) (a : Approval) (w : Witnesses) (t : Result) :
    step s (.createInsert r a w) = .ok t ↔
    insertNative s r = true ∧ r.authenticatedOrigin = true ∧
    a.asset = insertAsset r.proposal ∧ approved s a w = true ∧ fresh s r.id = true ∧
    t = { state := { s with requests := r :: s.requests,       approvals := a :: s.approvals, used := r.id :: s.used } } := by
  unfold step
  simp only [bind, Except.bind, pure, Except.pure]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem mintWithdraw_ok (s : State) (a : Approval) (w : Witnesses) (t : Result) :
    step s (.mintWithdraw a w) = .ok t ↔ approved s a w = true ∧
    (∃ id refund, a.asset.name = .withdraw s.config.registry id refund) ∧
    t = { state := { s with approvals := a :: s.approvals } } := by
  unfold step
  simp only [bind, Except.bind, pure, Except.pure, throw, throwThe, MonadExcept.throw,
    MonadExceptOf.throw]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem release_ok (s : State) (id : Nat) (r : Request) (e : ReleaseEvidence)
    (w : Witnesses) (t : Result) :
    step s (.release id r e w) = .ok t ↔
    ∃ u, s.applications.find? (·.id == id) = some u ∧
    w.applicationSpend = true ∧ e.accepted = true ∧ e.source = id ∧ e.request = r ∧
    releaseNative s r = true ∧ r.authenticatedOrigin = true ∧
    r.held = some u.output.representative ∧ u.key = r.proposal.key ∧ fresh s r.id = true ∧
    t = { state := { (consume s id) with requests := r :: (consume s id).requests,       used := r.id :: (consume s id).used } } := by
  unfold step
  rcases hfind : s.applications.find? (·.id == id) with _ | u
  all_goals simp only [hfind, requireSome_none, requireSome_some, bind, Except.bind, pure,
    Except.pure]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem evolve_ok (s : State) (id : Nat) (u : ApplicationUTxO) (e : EvolutionEvidence)
    (w : Witnesses) (t : Result) :
    step s (.evolve id u e w) = .ok t ↔
    ∃ old, s.applications.find? (·.id == id) = some old ∧
    w.applicationSpend = true ∧ e.accepted = true ∧ e.source = id ∧ e.successor = u ∧
    u.output.representative = old.output.representative ∧ u.output.quantity = 1 ∧
    u.key = old.key ∧ fresh s u.id = true ∧
    t = { state := { (consume s id) with applications := u :: (consume s id).applications,       used := u.id :: (consume s id).used } } := by
  unfold step
  rcases hfind : s.applications.find? (·.id == id) with _ | old
  all_goals simp only [hfind, requireSome_none, requireSome_some, bind, Except.bind, pure,
    Except.pure]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem outsider_ok (s : State) (r : Request) (t : Result) :
    step s (.outsider r) = .ok t ↔ fresh s r.id = true ∧ r.held = none ∧
    t = { state := { s with requests := { r with authenticatedOrigin := false } :: s.requests,       used := r.id :: s.used } } := by
  unfold step
  simp only [bind, Except.bind, pure, Except.pure]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem withdraw_ok (s : State) (id : Nat) (a : Asset) (refund : Refund)
    (w : Witnesses) (t : Result) :
    step s (.withdraw id a refund w) = .ok t ↔
    ∃ r, s.requests.find? (·.id == id) = some r ∧ w.nativeSpend = true ∧
    r.authenticatedOrigin = true ∧ insertNative s r = true ∧
    refund.destination = r.proposal.refundAddress ∧ recognized s a = true ∧
    a.name = .withdraw s.config.registry id refund ∧ t = { state := consume s id } := by
  unfold step
  rcases hfind : s.requests.find? (·.id == id) with _ | r
  all_goals simp only [hfind, requireSome_none, requireSome_some, bind, Except.bind, pure,
    Except.pure]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem fold_ok (s : State) (items : List FoldItem) (mint : List Delta) (net : List ActionDelta)
    (w : Witnesses) (t : Result) :
    step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧
    foldItems s items = .ok t ∧ sameNet t.logical mint = true ∧
    (nonzero mint = true → w.representativeMint = true) ∧
    (actionNonzero net = true → w.applicationMint = true) ∧
    w.consumerWithdraw = true ∧
    items ≠ [] := by
  unfold step
  rcases hempty : items with _ | ⟨i, rest⟩
  · subst hempty
    simp only [bind, Except.bind, pure, Except.pure]
    repeat' split
    all_goals (intros; simp_all)
    all_goals first | exact eq_comm | (intros; simp_all)
  · simp only [hempty, bind, Except.bind, pure, Except.pure]
    repeat' split
    all_goals (intros; simp_all)
    all_goals first | exact eq_comm | (intros; simp_all)

theorem moveAction_ok (s : State) (a : Asset) (n : Int) (w : Witnesses) (t : Result) :
    step s (.moveAction a n w) = .ok t ↔ recognized s a = true ∧ n = 0 ∧
    t = { state := s } := by
  unfold step
  simp only [bind, Except.bind, pure, Except.pure]
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem escape_error (s : State) (id : Nat) :
    step s (.escape id) = .error "completion-only-custody" := rfl

theorem foldOne_insert_ok (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation = .insert) :
    foldOne s i = .ok t ↔ r.authenticatedOrigin = true ∧ insertNative s r = true ∧
    r.token.any (recognized s) = true ∧ (entry s r.proposal.key).value = none ∧
    r.proposal.scope.contains (entry s r.proposal.key).incarnation = true ∧
    r.proposal.initial.representative = representative s r.proposal.key ∧
    i.output = some r.proposal.initial ∧ fresh s i.outputId = true ∧
    t = { state := { (setEntry (consume s r.id) { (entry s r.proposal.key) with value := some .active }) with       applications := { id := i.outputId, key := r.proposal.key, output := r.proposal.initial } ::         (consume s r.id).applications, used := i.outputId :: s.used },       logical := [{ asset := representative s r.proposal.key, quantity := 1 }] } := by
  unfold foldOne
  simp only [hr, hop, requireSome_some, bind, Except.bind, pure, Except.pure]
  repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem foldOne_terminal_ok (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation ≠ .insert) :
    foldOne s i = .ok t ↔ r.authenticatedOrigin = true ∧ releaseNative s r = true ∧
    r.held = some (representative s r.proposal.key) ∧
    (entry s r.proposal.key).value = some .active ∧ i.output = none ∧
    t = { state := setEntry (consume s r.id) { (entry s r.proposal.key) with
      value := if r.operation == .update then some .over else none,       incarnation := if r.operation == .delete then (entry s r.proposal.key).incarnation + 1
        else (entry s r.proposal.key).incarnation },       logical := [{ asset := representative s r.proposal.key, quantity := -1 }] } := by
  unfold foldOne
  simp only [hr, requireSome_some, bind, Except.bind, pure, Except.pure]
  cases hop' : r.operation
  · exact absurd hop' hop
  all_goals repeat' split
  all_goals (intros; simp_all)
  all_goals first | exact eq_comm | (intros; simp_all)

theorem foldOne_ok_find {s : State} {i : FoldItem} {t : Result} (h : foldOne s i = .ok t) :
    ∃ r, s.requests.find? (·.id == i.request) = some r := by
  rcases hr : s.requests.find? (·.id == i.request) with _ | r
  · simp [foldOne, hr, bind, Except.bind] at h
  · exact ⟨r, hr⟩

theorem foldItems_cons_ok (s : State) (i : FoldItem) (is : List FoldItem) (t : Result) :
    foldItems s (i :: is) = .ok t ↔ ∃ first rest,
    foldOne s i = .ok first ∧ foldItems first.state is = .ok rest ∧
    t = { state := rest.state, logical := first.logical ++ rest.logical } := by
  simp only [foldItems, bind, Except.bind, pure, Except.pure]
  rcases h1 : foldOne s i with _ | first
  · simp
  rcases h2 : foldItems first.state is with _ | rest
  · simp [h2]
  simp [h2]
  exact eq_comm

/-! ## Entries after a fold -/

theorem foldOne_entry_over {s : State} {i : FoldItem} {t : Result} {key : Nat}
    (over : (entry s key).value = some .over) (h : foldOne s i = .ok t) :
    (entry t.state key).value = some .over := by
  obtain ⟨r, hr⟩ := foldOne_ok_find h
  by_cases hop : r.operation = .insert
  · rw [foldOne_insert_ok s i r t hr hop] at h
    obtain ⟨-, -, -, hnone, -, -, -, -, rfl⟩ := h
    show (entry (setEntry (consume s r.id) { entry s r.proposal.key with value := some .active }) key).value = some .over
    rw [entry_setEntry]
    by_cases hk : r.proposal.key = key
    · rw [hk] at hnone; rw [hnone] at over; cases over
    · rw [if_neg (by simpa using hk)]; exact over
  · rw [foldOne_terminal_ok s i r t hr hop] at h
    obtain ⟨-, -, -, hactive, -, rfl⟩ := h
    show (entry (setEntry (consume s r.id) _) key).value = some .over
    rw [entry_setEntry]
    by_cases hk : r.proposal.key = key
    · rw [hk] at hactive; rw [hactive] at over; cases over
    · rw [if_neg (by simpa using hk)]; exact over

theorem foldItems_entry_over {s : State} {items : List FoldItem} {t : Result} {key : Nat}
    (over : (entry s key).value = some .over) (h : foldItems s items = .ok t) :
    (entry t.state key).value = some .over := by
  induction items generalizing s t with
  | nil => simp [foldItems] at h; subst h; exact over
  | cons i is ih =>
    rw [foldItems_cons_ok] at h
    obtain ⟨first, rest, h1, h2, rfl⟩ := h
    have hrest := ih (foldOne_entry_over over h1) h2
    exact hrest

end Singular

namespace Singular

/-! ## The bookkeeping invariant of reachable states

`WellFormed` alone is not inductive: it counts the holders of the current
representative of each key, so it says nothing about custody records that carry a
stale or foreign representative, nor about duplicated identifiers. `Inv` adds what
the transition function actually maintains: every custody record carries the
current representative of its key, and every identifier in custody is recorded in
`used` and unique. -/

structure Inv (s : State) : Prop where
  wf : WellFormed s
  app_rep : ∀ u ∈ s.applications, u.output.representative = representative s u.key
  req_rep : ∀ r ∈ s.requests, ∀ nft, r.held = some nft → nft = representative s r.proposal.key
  app_used : ∀ u ∈ s.applications, u.id ∈ s.used
  req_used : ∀ r ∈ s.requests, r.id ∈ s.used
  nodup : (s.applications.map (·.id) ++ s.requests.map (·.id)).Nodup

theorem inv_initial (c : Config) : Inv { config := c } where
  wf key := by simp [supply, entry]
  app_rep u hu := by simp at hu
  req_rep r hr := by simp at hr
  app_used u hu := by simp at hu
  req_used r hr := by simp at hr
  nodup := by simp

theorem Inv.nodup_applications {s : State} (hs : Inv s) : (s.applications.map (·.id)).Nodup :=
  (List.nodup_append.mp hs.nodup).1

theorem Inv.nodup_requests {s : State} (hs : Inv s) : (s.requests.map (·.id)).Nodup :=
  (List.nodup_append.mp hs.nodup).2.1

/-- A request identifier never names an application. -/
theorem Inv.filter_applications {s : State} (hs : Inv s) {r : Request} (hr : r ∈ s.requests) :
    s.applications.filter (·.id != r.id) = s.applications := by
  apply filter_ne_of_forall (fun u : ApplicationUTxO => u.id)
  intro u hu h
  exact not_mem_of_nodup_append' hs.nodup (List.mem_map.mpr ⟨r, hr, rfl⟩)
    (List.mem_map.mpr ⟨u, hu, h⟩)

/-- An application identifier never names a request. -/
theorem Inv.filter_requests {s : State} (hs : Inv s) {u : ApplicationUTxO}
    (hu : u ∈ s.applications) : s.requests.filter (·.id != u.id) = s.requests := by
  apply filter_ne_of_forall (fun r : Request => r.id)
  intro r hr h
  exact not_mem_of_nodup_append hs.nodup (List.mem_map.mpr ⟨u, hu, rfl⟩)
    (List.mem_map.mpr ⟨r, hr, h⟩)

theorem Inv.fresh_id {s : State} (hs : Inv s) {id : Nat} (h : id ∉ s.used) :
    id ∉ s.applications.map (·.id) ++ s.requests.map (·.id) := by
  rw [List.mem_append, List.mem_map, List.mem_map]
  rintro (⟨u, hu, hid⟩ | ⟨r, hr, hid⟩)
  · exact h (hid ▸ hs.app_used u hu)
  · exact h (hid ▸ hs.req_used r hr)

theorem sublist_ids {α} (f : α → Nat) (l : List α) (p : α → Bool) :
    List.Sublist ((l.filter p).map f) (l.map f) :=
  List.Sublist.map f List.filter_sublist

theorem nodup_middle_of {α} {a : α} {l₁ l₂ : List α} (h : a ∉ l₁ ++ l₂)
    (hn : (l₁ ++ l₂).Nodup) : (l₁ ++ a :: l₂).Nodup := by
  rw [List.perm_middle.nodup_iff, List.nodup_cons]
  exact ⟨h, hn⟩

theorem inv_of_eq {s s' : State} (hs : Inv s) (hc : s'.config = s.config)
    (he : s'.entries = s.entries) (ha : s'.applications = s.applications)
    (hr : s'.requests = s.requests) (hu : s'.used = s.used) : Inv s' := by
  have hrep : ∀ k, representative s' k = representative s k :=
    fun k => representative_of k hc (by rw [entry_of_entries he])
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    rw [supply_eq, ha, hr, hrep, entry_of_entries he, ← supply_eq]
    exact hs.wf key
  · intro u hu'; rw [ha] at hu'; rw [hrep]; exact hs.app_rep u hu'
  · intro r hr' nft h; rw [hr] at hr'; rw [hrep]; exact hs.req_rep r hr' nft h
  · intro u hu'; rw [ha] at hu'; rw [hu]; exact hs.app_used u hu'
  · intro r hr'; rw [hr] at hr'; rw [hu]; exact hs.req_used r hr'
  · rw [ha, hr]; exact hs.nodup

/-- Staging a request that holds nothing under a fresh identifier. -/
theorem inv_add_request {s s' : State} (hs : Inv s) {r : Request}
    (hc : s'.config = s.config) (he : s'.entries = s.entries)
    (ha : s'.applications = s.applications) (hr : s'.requests = r :: s.requests)
    (hu : s'.used = r.id :: s.used) (hheld : r.held = none) (hfresh : r.id ∉ s.used) :
    Inv s' := by
  have hrep : ∀ k, representative s' k = representative s k :=
    fun k => representative_of k hc (by rw [entry_of_entries he])
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    have hw := hs.wf key
    rw [supply_eq] at hw
    rw [supply_eq, ha, hr, hrep, entry_of_entries he, List.countP_cons]
    simp only [hheld]
    simpa using hw
  · intro u hu'; rw [ha] at hu'; rw [hrep]; exact hs.app_rep u hu'
  · intro r' hr' nft h
    rw [hr, List.mem_cons] at hr'
    rw [hrep]
    rcases hr' with rfl | hr'
    · rw [hheld] at h; cases h
    · exact hs.req_rep r' hr' nft h
  · intro u hu'; rw [ha] at hu'; rw [hu]; exact List.mem_cons_of_mem _ (hs.app_used u hu')
  · intro r' hr'
    rw [hr, List.mem_cons] at hr'
    rw [hu, List.mem_cons]
    rcases hr' with rfl | hr'
    · exact Or.inl rfl
    · exact Or.inr (hs.req_used r' hr')
  · rw [ha, hr, List.map_cons]
    exact nodup_middle_of (hs.fresh_id hfresh) hs.nodup

/-- Releasing an application into a terminal request that holds its representative. -/
theorem inv_release {s s' : State} (hs : Inv s) {u : ApplicationUTxO} {r : Request}
    (hu : u ∈ s.applications) (hc : s'.config = s.config) (he : s'.entries = s.entries)
    (ha : s'.applications = s.applications.filter (·.id != u.id))
    (hr : s'.requests = r :: s.requests.filter (·.id != u.id))
    (hused : s'.used = r.id :: s.used)
    (hheld : r.held = some u.output.representative) (hkey : u.key = r.proposal.key)
    (hfresh : r.id ∉ s.used) : Inv s' := by
  have hrep : ∀ k, representative s' k = representative s k :=
    fun k => representative_of k hc (by rw [entry_of_entries he])
  rw [hs.filter_requests hu] at hr
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    have hw := hs.wf key
    rw [supply_eq] at hw
    have hcount : (s.applications.filter (·.id != u.id)).countP
        (fun v => v.output.representative == representative s key) +
        (if u.output.representative == representative s key then 1 else 0) =
        s.applications.countP (fun v => v.output.representative == representative s key) :=
      countP_filter_ne_of_nodup (·.id) _ s.applications u.id hs.nodup_applications u hu rfl
    rw [supply_eq, ha, hr, hrep, entry_of_entries he, List.countP_cons]
    simp only [hheld, Option.some_beq_some]
    omega
  · intro v hv; rw [ha, List.mem_filter] at hv; rw [hrep]; exact hs.app_rep v hv.1
  · intro r' hr' nft h
    rw [hr, List.mem_cons] at hr'
    rw [hrep]
    rcases hr' with rfl | hr'
    · rw [hheld] at h
      cases h
      rw [← hkey]
      exact hs.app_rep u hu
    · exact hs.req_rep r' hr' nft h
  · intro v hv; rw [ha, List.mem_filter] at hv; rw [hused]
    exact List.mem_cons_of_mem _ (hs.app_used v hv.1)
  · intro r' hr'
    rw [hr, List.mem_cons] at hr'
    rw [hused, List.mem_cons]
    rcases hr' with rfl | hr'
    · exact Or.inl rfl
    · exact Or.inr (hs.req_used r' hr')
  · rw [ha, hr, List.map_cons]
    refine nodup_middle_of (fun h => hs.fresh_id hfresh ?_) ?_
    · rw [List.mem_append] at h ⊢
      rcases h with h | h
      · exact Or.inl ((sublist_ids _ _ _).subset h)
      · exact Or.inr h
    · exact hs.nodup.sublist ((sublist_ids _ _ _).append (List.Sublist.refl _))

/-- Replacing an application by a successor with the same representative and key. -/
theorem inv_evolve {s s' : State} (hs : Inv s) {u v : ApplicationUTxO}
    (hu : u ∈ s.applications) (hc : s'.config = s.config) (he : s'.entries = s.entries)
    (ha : s'.applications = v :: s.applications.filter (·.id != u.id))
    (hr : s'.requests = s.requests.filter (·.id != u.id))
    (hused : s'.used = v.id :: s.used)
    (hvrep : v.output.representative = u.output.representative) (hkey : v.key = u.key)
    (hfresh : v.id ∉ s.used) : Inv s' := by
  have hrep : ∀ k, representative s' k = representative s k :=
    fun k => representative_of k hc (by rw [entry_of_entries he])
  rw [hs.filter_requests hu] at hr
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    have hw := hs.wf key
    rw [supply_eq] at hw
    have hcount : (s.applications.filter (·.id != u.id)).countP
        (fun v => v.output.representative == representative s key) +
        (if u.output.representative == representative s key then 1 else 0) =
        s.applications.countP (fun v => v.output.representative == representative s key) :=
      countP_filter_ne_of_nodup (·.id) _ s.applications u.id hs.nodup_applications u hu rfl
    rw [supply_eq, ha, hr, hrep, entry_of_entries he, List.countP_cons]
    simp only [hvrep]
    omega
  · intro v' hv
    rw [ha, List.mem_cons] at hv
    rw [hrep]
    rcases hv with rfl | hv
    · rw [hvrep, hkey]; exact hs.app_rep u hu
    · exact hs.app_rep v' (List.mem_filter.mp hv).1
  · intro r' hr' nft h; rw [hr] at hr'; rw [hrep]; exact hs.req_rep r' hr' nft h
  · intro v' hv
    rw [ha, List.mem_cons] at hv
    rw [hused, List.mem_cons]
    rcases hv with rfl | hv
    · exact Or.inl rfl
    · exact Or.inr (hs.app_used v' (List.mem_filter.mp hv).1)
  · intro r' hr'; rw [hr] at hr'; rw [hused]; exact List.mem_cons_of_mem _ (hs.req_used r' hr')
  · rw [ha, hr, List.map_cons, List.cons_append, List.nodup_cons]
    refine ⟨fun h => hs.fresh_id hfresh ?_, ?_⟩
    · rw [List.mem_append] at h ⊢
      rcases h with h | h
      · exact Or.inl ((sublist_ids _ _ _).subset h)
      · exact Or.inr h
    · exact hs.nodup.sublist ((sublist_ids _ _ _).append (List.Sublist.refl _))

/-- Removing a request that holds nothing. -/
theorem inv_remove_request {s s' : State} (hs : Inv s) {r : Request} (hr : r ∈ s.requests)
    (hc : s'.config = s.config) (he : s'.entries = s.entries)
    (ha : s'.applications = s.applications.filter (·.id != r.id))
    (hreq : s'.requests = s.requests.filter (·.id != r.id)) (hused : s'.used = s.used)
    (hheld : r.held = none) : Inv s' := by
  have hrep : ∀ k, representative s' k = representative s k :=
    fun k => representative_of k hc (by rw [entry_of_entries he])
  rw [hs.filter_applications hr] at ha
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    have hw := hs.wf key
    rw [supply_eq] at hw
    have hcount : (s.requests.filter (·.id != r.id)).countP
        (fun r' => r'.held == some (representative s key)) +
        (if r.held == some (representative s key) then 1 else 0) =
        s.requests.countP (fun r' => r'.held == some (representative s key)) :=
      countP_filter_ne_of_nodup (·.id) _ s.requests r.id hs.nodup_requests r hr rfl
    rw [supply_eq, ha, hreq, hrep, entry_of_entries he]
    simp only [hheld] at hcount
    simp at hcount
    omega
  · intro u hu; rw [ha] at hu; rw [hrep]; exact hs.app_rep u hu
  · intro r' hr' nft h; rw [hreq, List.mem_filter] at hr'; rw [hrep]; exact hs.req_rep r' hr'.1 nft h
  · intro u hu; rw [ha] at hu; rw [hused]; exact hs.app_used u hu
  · intro r' hr'; rw [hreq, List.mem_filter] at hr'; rw [hused]; exact hs.req_used r' hr'.1
  · rw [ha, hreq]
    exact hs.nodup.sublist ((List.Sublist.refl _).append (sublist_ids _ _ _))

/-- Completing an Insert: the staged request is consumed, its key becomes Active and a
certified application holding the key's representative appears. -/
theorem inv_fold_insert {s s' : State} (hs : Inv s) {r : Request} (hr : r ∈ s.requests)
    {n : ApplicationUTxO} (hc : s'.config = s.config)
    (he : ∀ k, r.proposal.key ≠ k → entry s' k = entry s k)
    (hval' : (entry s' r.proposal.key).value = some .active)
    (hinc : (entry s' r.proposal.key).incarnation = (entry s r.proposal.key).incarnation)
    (ha : s'.applications = n :: s.applications.filter (·.id != r.id))
    (hreq : s'.requests = s.requests.filter (·.id != r.id)) (hused : s'.used = n.id :: s.used)
    (hheld : r.held = none) (hval : (entry s r.proposal.key).value = none)
    (hnkey : n.key = r.proposal.key)
    (hnrep : n.output.representative = representative s r.proposal.key)
    (hfresh : n.id ∉ s.used) : Inv s' := by
  have hrep : ∀ k, representative s' k = representative s k := by
    intro k
    apply representative_of k hc
    by_cases hk : r.proposal.key = k
    · subst hk; exact hinc
    · rw [he k hk]
  rw [hs.filter_applications hr] at ha
  have hreqcount : ∀ key, (s.requests.filter (·.id != r.id)).countP
      (fun r' => r'.held == some (representative s key)) =
      s.requests.countP (fun r' => r'.held == some (representative s key)) := by
    intro key
    have := countP_filter_ne_of_nodup (fun r : Request => r.id)
      (fun r' => r'.held == some (representative s key)) s.requests r.id hs.nodup_requests r hr rfl
    simpa [hheld] using this
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    have hw := hs.wf key
    rw [supply_eq] at hw
    rw [supply_eq, ha, hreq, hrep, List.countP_cons, hreqcount]
    by_cases hk : r.proposal.key = key
    · subst hk
      rw [hval] at hw
      rw [hval', hnrep, beq_self_eq_true, if_pos rfl, if_pos rfl]
      simp only [reduceCtorEq, ↓reduceIte] at hw
      omega
    · rw [he key hk]
      have : (n.output.representative == representative s key) = false := by
        rw [hnrep]
        exact beq_eq_false_iff_ne.mpr fun h => hk (representative_key_eq h)
      rw [this]
      simpa using hw
  · intro u hu
    rw [ha, List.mem_cons] at hu
    rw [hrep]
    rcases hu with rfl | hu
    · rw [hnrep, hnkey]
    · exact hs.app_rep u hu
  · intro r' hr' nft h
    rw [hreq, List.mem_filter] at hr'
    rw [hrep]
    exact hs.req_rep r' hr'.1 nft h
  · intro u hu
    rw [ha, List.mem_cons] at hu
    rw [hused, List.mem_cons]
    rcases hu with rfl | hu
    · exact Or.inl rfl
    · exact Or.inr (hs.app_used u hu)
  · intro r' hr'
    rw [hreq, List.mem_filter] at hr'
    rw [hused]
    exact List.mem_cons_of_mem _ (hs.req_used r' hr'.1)
  · rw [ha, hreq, List.map_cons, List.cons_append, List.nodup_cons]
    refine ⟨fun h => hs.fresh_id hfresh ?_, ?_⟩
    · rw [List.mem_append] at h ⊢
      rcases h with h | h
      · exact Or.inl h
      · exact Or.inr ((sublist_ids _ _ _).subset h)
    · exact hs.nodup.sublist ((List.Sublist.refl _).append (sublist_ids _ _ _))

/-- Completing an Update or Delete: the terminal request holding the representative is
consumed and its key stops being Active, so nothing holds the key any more. -/
theorem inv_fold_terminal {s s' : State} (hs : Inv s) {r : Request} (hr : r ∈ s.requests)
    (hc : s'.config = s.config)
    (he : ∀ k, r.proposal.key ≠ k → entry s' k = entry s k)
    (hval : (entry s' r.proposal.key).value ≠ some .active)
    (ha : s'.applications = s.applications.filter (·.id != r.id))
    (hreq : s'.requests = s.requests.filter (·.id != r.id)) (hused : s'.used = s.used)
    (hheld : r.held = some (representative s r.proposal.key))
    (hactive : (entry s r.proposal.key).value = some .active) : Inv s' := by
  rw [hs.filter_applications hr] at ha
  have hrep : ∀ k, r.proposal.key ≠ k → representative s' k = representative s k := by
    intro k hk
    apply representative_of k hc
    rw [he k hk]
  -- Nothing but `r` holds the key.
  have hw0 := hs.wf r.proposal.key
  rw [supply_eq, hactive, if_pos rfl] at hw0
  have hrcount := countP_filter_ne_of_nodup (fun r : Request => r.id)
    (fun r' => r'.held == some (representative s r.proposal.key)) s.requests r.id
    hs.nodup_requests r hr rfl
  dsimp only at hrcount
  rw [hheld, beq_self_eq_true, if_pos rfl] at hrcount
  have happs0 : s.applications.countP
      (fun u => u.output.representative == representative s r.proposal.key) = 0 := by omega
  have hreqs0 : (s.requests.filter (·.id != r.id)).countP
      (fun r' => r'.held == some (representative s r.proposal.key)) = 0 := by omega
  rw [List.countP_eq_zero] at happs0 hreqs0
  have happ_key : ∀ u ∈ s.applications, u.key ≠ r.proposal.key := by
    intro u hu hk
    apply happs0 u hu
    rw [hs.app_rep u hu, hk]
    exact beq_self_eq_true _
  have hreq_key : ∀ r' ∈ s.requests.filter (·.id != r.id), ∀ nft, r'.held = some nft →
      r'.proposal.key ≠ r.proposal.key := by
    intro r' hr' nft h hk
    apply hreqs0 r' hr'
    rw [h, hs.req_rep r' (List.mem_filter.mp hr').1 nft h, hk]
    exact beq_self_eq_true _
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro key
    by_cases hk : r.proposal.key = key
    · subst hk
      rw [supply_eq, ha, hreq, if_neg hval]
      rw [List.countP_eq_zero.mpr, List.countP_eq_zero.mpr]
      · intro r' hr' h
        rw [beq_iff_eq] at h
        have := hs.req_rep r' (List.mem_filter.mp hr').1 _ h
        exact hreq_key r' hr' _ h (representative_key_eq this).symm
      · intro u hu h
        rw [beq_iff_eq, hs.app_rep u hu] at h
        exact happ_key u hu (representative_key_eq h)
    · have hw := hs.wf key
      rw [supply_eq] at hw
      have hcount := countP_filter_ne_of_nodup (fun r : Request => r.id)
        (fun r' => r'.held == some (representative s key)) s.requests r.id
        hs.nodup_requests r hr rfl
      dsimp only at hcount
      have : (r.held == some (representative s key)) = false := by
        rw [hheld, Option.some_beq_some]
        exact beq_eq_false_iff_ne.mpr fun h => hk (representative_key_eq h)
      rw [this, if_neg (by simp)] at hcount
      rw [supply_eq, ha, hreq, hrep key hk, he key hk]
      omega
  · intro u hu
    rw [ha] at hu
    rw [hrep u.key (Ne.symm (happ_key u hu))]
    exact hs.app_rep u hu
  · intro r' hr' nft h
    rw [hreq] at hr'
    rw [hrep _ (Ne.symm (hreq_key r' hr' nft h))]
    exact hs.req_rep r' (List.mem_filter.mp hr').1 nft h
  · intro u hu; rw [ha] at hu; rw [hused]; exact hs.app_used u hu
  · intro r' hr'; rw [hreq, List.mem_filter] at hr'; rw [hused]; exact hs.req_used r' hr'.1
  · rw [ha, hreq]
    exact hs.nodup.sublist ((List.Sublist.refl _).append (sublist_ids _ _ _))

theorem inv_foldOne {s : State} {i : FoldItem} {t : Result} (hs : Inv s)
    (h : foldOne s i = .ok t) : Inv t.state := by
  obtain ⟨r, hr⟩ := foldOne_ok_find h
  have hmem : r ∈ s.requests := List.mem_of_find?_eq_some hr
  by_cases hop : r.operation = .insert
  · rw [foldOne_insert_ok s i r t hr hop] at h
    obtain ⟨-, hnative, -, hnone, -, hnrep, -, hfresh, rfl⟩ := h
    have hheld : r.held = none := by
      simp only [insertNative, Bool.and_eq_true, Option.isNone_iff_eq_none] at hnative
      exact hnative.1.1.2
    refine inv_fold_insert hs hmem rfl ?_ ?_ ?_ rfl rfl rfl hheld hnone rfl hnrep
      (by simpa [fresh] using hfresh)
    · intro k hk
      show entry (setEntry (consume s r.id) _) k = _
      rw [entry_setEntry, if_neg (by simpa using hk)]
      rfl
    · show (entry (setEntry (consume s r.id) _) _).value = _
      rw [entry_setEntry, if_pos (by simp)]
    · show (entry (setEntry (consume s r.id) _) _).incarnation = _
      rw [entry_setEntry, if_pos (by simp)]
  · rw [foldOne_terminal_ok s i r t hr hop] at h
    obtain ⟨-, -, hheld, hactive, -, rfl⟩ := h
    refine inv_fold_terminal hs hmem rfl ?_ ?_ rfl rfl rfl hheld hactive
    · intro k hk
      show entry (setEntry (consume s r.id) _) k = _
      rw [entry_setEntry, if_neg (by simpa using hk)]
      rfl
    · show (entry (setEntry (consume s r.id) _) _).value ≠ _
      rw [entry_setEntry, if_pos (by simp)]
      cases hop' : r.operation <;> simp [hop'] at hop ⊢

theorem inv_foldItems {s : State} {items : List FoldItem} {t : Result} (hs : Inv s)
    (h : foldItems s items = .ok t) : Inv t.state := by
  induction items generalizing s t with
  | nil => simp [foldItems] at h; subst h; exact hs
  | cons i is ih =>
    rw [foldItems_cons_ok] at h
    obtain ⟨first, rest, h1, h2, rfl⟩ := h
    have hrest := ih (inv_foldOne hs h1) h2
    exact hrest

theorem inv_step {s : State} {a : Action} {t : Result} (hs : Inv s) (h : step s a = .ok t) :
    Inv t.state := by
  cases a with
  | createInsert r c w =>
    rw [createInsert_ok] at h
    obtain ⟨hnative, -, -, -, hfresh, rfl⟩ := h
    have hheld : r.held = none := by
      simp only [insertNative, Bool.and_eq_true, Option.isNone_iff_eq_none] at hnative
      exact hnative.1.1.2
    exact inv_add_request hs rfl rfl rfl rfl rfl hheld (by simpa [fresh] using hfresh)
  | mintWithdraw c w =>
    rw [mintWithdraw_ok] at h
    obtain ⟨-, -, rfl⟩ := h
    exact inv_of_eq hs rfl rfl rfl rfl rfl
  | release id r e w =>
    rw [release_ok] at h
    obtain ⟨u, hu, -, -, -, -, -, -, hheld, hkey, hfresh, rfl⟩ := h
    have hid : u.id = id := by simpa using List.find?_some hu
    subst hid
    exact inv_release hs (List.mem_of_find?_eq_some hu) rfl rfl rfl rfl rfl hheld hkey
      (by simpa [fresh] using hfresh)
  | evolve id v e w =>
    rw [evolve_ok] at h
    obtain ⟨u, hu, -, -, -, -, hvrep, -, hkey, hfresh, rfl⟩ := h
    have hid : u.id = id := by simpa using List.find?_some hu
    subst hid
    exact inv_evolve hs (List.mem_of_find?_eq_some hu) rfl rfl rfl rfl rfl hvrep hkey
      (by simpa [fresh] using hfresh)
  | outsider r =>
    rw [outsider_ok] at h
    obtain ⟨hfresh, hheld, rfl⟩ := h
    exact inv_add_request hs rfl rfl rfl rfl rfl hheld (by simpa [fresh] using hfresh)
  | withdraw id a refund w =>
    rw [withdraw_ok] at h
    obtain ⟨r, hr, -, -, hnative, -, -, -, rfl⟩ := h
    have hid : r.id = id := by simpa using List.find?_some hr
    subst hid
    have hheld : r.held = none := by
      simp only [insertNative, Bool.and_eq_true, Option.isNone_iff_eq_none] at hnative
      exact hnative.1.1.2
    exact inv_remove_request hs (List.mem_of_find?_eq_some hr) rfl rfl rfl rfl rfl hheld
  | fold items mint net w =>
    rw [fold_ok] at h
    exact inv_foldItems hs h.2.1
  | moveAction a n w =>
    rw [moveAction_ok] at h
    obtain ⟨-, -, rfl⟩ := h
    exact hs
  | escape id => cases h

theorem reachable_inv {s : State} (h : Reachable s) : Inv s := by
  induction h with
  | initial c => exact inv_initial c
  | next _ hstep ih => exact inv_step ih hstep

end Singular

namespace Singular

/-! ## Registry independence of insert creation and release

Both transitions read the configuration, the custody records and the used
identifiers, never the registry entries. Changing the entries therefore changes
only the entries of the produced state. -/

@[simp] theorem insertNative_entries (s : State) (entries : List Entry) (r : Request) :
    insertNative { s with entries := entries } r = insertNative s r := rfl
@[simp] theorem releaseNative_entries (s : State) (entries : List Entry) (r : Request) :
    releaseNative { s with entries := entries } r = releaseNative s r := rfl
@[simp] theorem approved_entries (s : State) (entries : List Entry) (a : Approval) (w : Witnesses) :
    approved { s with entries := entries } a w = approved s a w := rfl
@[simp] theorem fresh_entries (s : State) (entries : List Entry) (id : Nat) :
    fresh { s with entries := entries } id = fresh s id := rfl

theorem step_createInsert_entries (s : State) (entries : List Entry) (r : Request)
    (a : Approval) (w : Witnesses) :
    step { s with entries := entries } (.createInsert r a w) =
      (step s (.createInsert r a w)).map
        fun t => { t with state := { t.state with entries := entries } } := by
  unfold step
  simp only [bind, Except.bind, pure, Except.pure, Except.map, insertNative_entries,
    approved_entries, fresh_entries]
  repeat' split
  all_goals (try (rename_i heq; cases heq))
  all_goals simp_all

theorem step_release_entries (s : State) (entries : List Entry) (id : Nat) (r : Request)
    (e : ReleaseEvidence) (w : Witnesses) :
    step { s with entries := entries } (.release id r e w) =
      (step s (.release id r e w)).map
        fun t => { t with state := { t.state with entries := entries } } := by
  unfold step
  rcases hfind : s.applications.find? (·.id == id) with _ | u
  all_goals simp only [hfind, requireSome_none, requireSome_some, bind, Except.bind, pure,
    Except.pure, Except.map, releaseNative_entries, fresh_entries]
  all_goals repeat' split
  all_goals (try (rename_i heq; cases heq))
  all_goals simp_all [consume]

end Singular
