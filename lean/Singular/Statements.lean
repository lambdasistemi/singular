import Singular.Lemmas
namespace Singular
namespace Statements
/-! The public statement surface of the model. Every declaration keeps the exact text it
was frozen with; the proofs draw on `Singular.Lemmas`. Three statements quantify over
`Reachable s` without needing it, so the unused-variable linter is silenced for them
rather than touching their statements. -/

theorem insert_commitment_injective (p q : Proposal) :
    insertAsset p = insertAsset q ↔ p = q := by
  constructor
  · intro h; simp [insertAsset] at h; exact h.2
  · intro h; subst h; rfl

theorem action_domain_separation (p : Proposal) (reg id : Nat) (r : Refund) :
    Commitment.insert p ≠ Commitment.withdraw reg id r := by
  simp

theorem createInsert_iff (s : State) (r : Request) (a : Approval) (w : Witnesses) (t : Result) :
    step s (.createInsert r a w) = .ok t ↔
    insertNative s r = true ∧ r.authenticatedOrigin = true ∧
    a.asset = insertAsset r.proposal ∧ approved s a w = true ∧ fresh s r.id = true ∧
    t = { state := { s with requests := r :: s.requests,       approvals := a :: s.approvals, used := r.id :: s.used } } := by
  exact createInsert_ok s r a w t

theorem mintWithdraw_iff (s : State) (a : Approval) (w : Witnesses) (t : Result) :
    step s (.mintWithdraw a w) = .ok t ↔ approved s a w = true ∧
    (∃ id refund, a.asset.name = .withdraw s.config.registry id refund) ∧
    t = { state := { s with approvals := a :: s.approvals } } := by
  exact mintWithdraw_ok s a w t

theorem release_iff (s : State) (id : Nat) (r : Request) (e : ReleaseEvidence)
    (w : Witnesses) (t : Result) :
    step s (.release id r e w) = .ok t ↔
    ∃ u, s.applications.find? (·.id == id) = some u ∧
    w.applicationSpend = true ∧ e.accepted = true ∧ e.source = id ∧ e.request = r ∧
    releaseNative s r = true ∧ r.authenticatedOrigin = true ∧
    r.held = some u.output.representative ∧ u.key = r.proposal.key ∧ fresh s r.id = true ∧
    t = { state := { (consume s id) with requests := r :: (consume s id).requests,       used := r.id :: (consume s id).used } } := by
  exact release_ok s id r e w t

theorem evolve_iff (s : State) (id : Nat) (u : ApplicationUTxO) (e : EvolutionEvidence)
    (w : Witnesses) (t : Result) :
    step s (.evolve id u e w) = .ok t ↔
    ∃ old, s.applications.find? (·.id == id) = some old ∧
    w.applicationSpend = true ∧ e.accepted = true ∧ e.source = id ∧ e.successor = u ∧
    u.output.representative = old.output.representative ∧ u.output.quantity = 1 ∧
    u.key = old.key ∧ fresh s u.id = true ∧
    t = { state := { (consume s id) with applications := u :: (consume s id).applications,       used := u.id :: (consume s id).used } } := by
  exact evolve_ok s id u e w t

theorem outsider_iff (s : State) (r : Request) (t : Result) :
    step s (.outsider r) = .ok t ↔ fresh s r.id = true ∧ r.held = none ∧
    t = { state := { s with requests := { r with authenticatedOrigin := false } :: s.requests,       used := r.id :: s.used } } := by
  exact outsider_ok s r t

theorem withdraw_iff (s : State) (id : Nat) (a : Asset) (refund : Refund)
    (w : Witnesses) (t : Result) :
    step s (.withdraw id a refund w) = .ok t ↔
    ∃ r, s.requests.find? (·.id == id) = some r ∧ w.nativeSpend = true ∧
    r.authenticatedOrigin = true ∧ insertNative s r = true ∧ recognized s a = true ∧
    a.name = .withdraw s.config.registry id refund ∧ t = { state := consume s id } := by
  exact withdraw_ok s id a refund w t

theorem fold_iff (s : State) (items : List FoldItem) (mint : List Delta) (net : List ActionDelta)
    (w : Witnesses) (t : Result) :
    step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧
    foldItems s items = .ok t ∧ sameNet t.logical mint = true ∧
    (nonzero mint = true → w.representativeMint = true) ∧
    (actionNonzero net = true → w.applicationMint = true) := by
  exact fold_ok s items mint net w t

theorem moveAction_iff (s : State) (a : Asset) (n : Int) (w : Witnesses) (t : Result) :
    step s (.moveAction a n w) = .ok t ↔ recognized s a = true ∧ n = 0 ∧
    t = { state := s } := by
  exact moveAction_ok s a n w t

theorem escape_refused (s : State) (id : Nat) :
    step s (.escape id) = .error "completion-only-custody" := by
  rfl

theorem foldOne_insert_iff (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation = .insert) :
    foldOne s i = .ok t ↔ r.authenticatedOrigin = true ∧ insertNative s r = true ∧
    r.token.any (recognized s) = true ∧ (entry s r.proposal.key).value = none ∧
    r.proposal.scope.contains (entry s r.proposal.key).incarnation = true ∧
    r.proposal.initial.representative = representative s r.proposal.key ∧
    i.output = some r.proposal.initial ∧ fresh s i.outputId = true ∧
    t = { state := { (setEntry (consume s r.id) { (entry s r.proposal.key) with value := some .active }) with       applications := { id := i.outputId, key := r.proposal.key, output := r.proposal.initial } ::         (consume s r.id).applications, used := i.outputId :: s.used },       logical := [{ asset := representative s r.proposal.key, quantity := 1 }] } := by
  exact foldOne_insert_ok s i r t hr hop

theorem foldOne_terminal_iff (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation ≠ .insert) :
    foldOne s i = .ok t ↔ r.authenticatedOrigin = true ∧ releaseNative s r = true ∧
    r.held = some (representative s r.proposal.key) ∧
    (entry s r.proposal.key).value = some .active ∧ i.output = none ∧
    t = { state := setEntry (consume s r.id) { (entry s r.proposal.key) with       value := if r.operation == .update then some .over else none,       incarnation := if r.operation == .delete then (entry s r.proposal.key).incarnation + 1         else (entry s r.proposal.key).incarnation },       logical := [{ asset := representative s r.proposal.key, quantity := -1 }] } := by
  exact foldOne_terminal_ok s i r t hr hop

theorem sequential_fold_cons (s : State) (i : FoldItem) (is : List FoldItem) (t : Result) :
    foldItems s (i :: is) = .ok t ↔ ∃ first rest,
    foldOne s i = .ok first ∧ foldItems first.state is = .ok rest ∧
    t = { state := rest.state, logical := first.logical ++ rest.logical } := by
  exact foldItems_cons_ok s i is t

theorem supply_conservation (s : State) (a : Action) (t : Result)
    (reachable : Reachable s) (success : step s a = .ok t) : WellFormed t.state := by
  exact (inv_step (reachable_inv reachable) success).wf

set_option linter.unusedVariables false in
theorem over_terminal (s : State) (a : Action) (t : Result) (key : Nat)
    (reachable : Reachable s) (over : (entry s key).value = some .over)
    (success : step s a = .ok t) : (entry t.state key).value = some .over := by
  cases a with
  | createInsert r c w =>
    rw [createInsert_ok] at success
    obtain ⟨-, -, -, -, -, rfl⟩ := success
    exact over
  | mintWithdraw c w =>
    rw [mintWithdraw_ok] at success
    obtain ⟨-, -, rfl⟩ := success
    exact over
  | release id r e w =>
    rw [release_ok] at success
    obtain ⟨u, -, -, -, -, -, -, -, -, -, -, rfl⟩ := success
    exact over
  | evolve id u e w =>
    rw [evolve_ok] at success
    obtain ⟨old, -, -, -, -, -, -, -, -, -, rfl⟩ := success
    exact over
  | outsider r =>
    rw [outsider_ok] at success
    obtain ⟨-, -, rfl⟩ := success
    exact over
  | withdraw id a refund w =>
    rw [withdraw_ok] at success
    obtain ⟨r, -, -, -, -, -, -, rfl⟩ := success
    exact over
  | fold items mint net w =>
    rw [fold_ok] at success
    exact foldItems_entry_over over success.2.1
  | moveAction a n w =>
    rw [moveAction_ok] at success
    obtain ⟨-, -, rfl⟩ := success
    exact over
  | escape id => cases success

theorem over_no_representative (s : State) (key : Nat) (reachable : Reachable s)
    (over : (entry s key).value = some .over) : supply s key = 0 := by
  have hw := (reachable_inv reachable).wf key
  rw [over] at hw
  simpa using hw

theorem pending_insert_no_representative (s : State) (r : Request) (a : Approval)
    (w : Witnesses) (t : Result) (h : step s (.createInsert r a w) = .ok t) :
    r.held = none ∧ t.state.entries = s.entries ∧ t.state.applications = s.applications := by
  rw [createInsert_ok] at h
  obtain ⟨hn, -, -, -, -, rfl⟩ := h
  refine ⟨?_, rfl, rfl⟩
  simp only [insertNative, Bool.and_eq_true, Option.isNone_iff_eq_none] at hn
  exact hn.1.1.2

theorem minting_requires_configured_issuer (s : State) (r : Request) (a : Approval)
    (w : Witnesses) (t : Result) (h : step s (.createInsert r a w) = .ok t) :
    a.asset.policy = s.config.applicationPolicy ∧ a.accepted = true ∧ w.applicationMint = true := by
  rw [createInsert_ok] at h
  obtain ⟨-, -, -, ha, -, -⟩ := h
  simp only [approved, Bool.and_eq_true, beq_iff_eq] at ha
  exact ⟨ha.2, ha.1.2, ha.1.1⟩

theorem withdrawal_preserves_registry_supply (s : State) (id : Nat) (a : Asset)
    (refund : Refund) (w : Witnesses) (t : Result) (reachable : Reachable s)
    (h : step s (.withdraw id a refund w) = .ok t) :
    t.state.entries = s.entries ∧ t.state.applications = s.applications ∧ t.logical = [] := by
  rw [withdraw_ok] at h
  obtain ⟨r, hr, -, -, -, -, -, rfl⟩ := h
  have hid : r.id = id := by simpa using List.find?_some hr
  subst hid
  refine ⟨rfl, ?_, rfl⟩
  exact (reachable_inv reachable).filter_applications (List.mem_of_find?_eq_some hr)

theorem exact_withdraw_scope (s : State) (id : Nat) (a : Asset) (refund : Refund)
    (w : Witnesses) (t : Result) (h : step s (.withdraw id a refund w) = .ok t) :
    a.name = .withdraw s.config.registry id refund := by
  rw [withdraw_ok] at h
  obtain ⟨r, -, -, -, -, -, hname, -⟩ := h
  exact hname

theorem local_evolution_registry_unchanged (s : State) (id : Nat) (u : ApplicationUTxO)
    (e : EvolutionEvidence) (w : Witnesses) (t : Result)
    (h : step s (.evolve id u e w) = .ok t) :
    t.state.entries = s.entries ∧ t.logical = [] := by
  rw [evolve_ok] at h
  obtain ⟨old, -, -, -, -, -, -, -, -, -, rfl⟩ := h
  exact ⟨rfl, rfl⟩

theorem release_is_operation_specific (s : State) (id : Nat) (r : Request) (e : ReleaseEvidence)
    (w : Witnesses) (t : Result) (h : step s (.release id r e w) = .ok t) :
    e.request.operation = r.operation ∧ e.request = r ∧ w.applicationSpend = true := by
  rw [release_ok] at h
  obtain ⟨u, -, hw, -, -, hreq, -⟩ := h
  exact ⟨by rw [hreq], hreq, hw⟩

set_option linter.unusedVariables false in
theorem release_removes_application_custody (s : State) (id : Nat) (r : Request)
    (e : ReleaseEvidence) (w : Witnesses) (t : Result) (reachable : Reachable s)
    (h : step s (.release id r e w) = .ok t) :
    t.state.applications.find? (·.id == id) = none := by
  rw [release_ok] at h
  obtain ⟨u, -, -, -, -, -, -, -, -, -, -, rfl⟩ := h
  simp [consume, List.find?_eq_none]

set_option linter.unusedVariables false in
theorem request_single_spend (s : State) (i : FoldItem) (t : Result)
    (reachable : Reachable s) (h : foldOne s i = .ok t) :
    t.state.requests.find? (·.id == i.request) = none := by
  obtain ⟨r, hr⟩ := foldOne_ok_find h
  have hid : r.id = i.request := by simpa using List.find?_some hr
  by_cases hop : r.operation = .insert
  · rw [foldOne_insert_ok s i r t hr hop] at h
    obtain ⟨-, -, -, -, -, -, -, -, rfl⟩ := h
    simp [List.find?_eq_none, hid]
  · rw [foldOne_terminal_ok s i r t hr hop] at h
    obtain ⟨-, -, -, -, -, rfl⟩ := h
    simp [List.find?_eq_none, hid]

theorem approval_scope_checked (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation = .insert)
    (h : foldOne s i = .ok t) :
    r.proposal.scope.contains (entry s r.proposal.key).incarnation = true := by
  rw [foldOne_insert_ok s i r t hr hop] at h
  exact h.2.2.2.2.1

theorem outsider_not_admitted (s : State) (r : Request) (t : Result)
    (h : step s (.outsider r) = .ok t) (i : FoldItem) (hi : i.request = r.id) :
    foldOne t.state i = .error "unauthenticated-request" := by
  rw [outsider_ok] at h
  obtain ⟨-, -, rfl⟩ := h
  simp [foldOne, hi, bind, Except.bind]

theorem native_witness_even_zero_net (s : State) (items : List FoldItem) (n : List ActionDelta)
    (w : Witnesses) (t : Result) (h : step s (.fold items [] n w) = .ok t) :
    w.nativeSpend = true ∧ sameNet t.logical [] = true := by
  rw [fold_ok] at h
  exact ⟨h.1, h.2.2.1⟩

theorem nonzero_action_invokes_policy (s : State) (items : List FoldItem) (mint : List Delta)
    (n : List ActionDelta) (w : Witnesses) (t : Result) (hn : actionNonzero n = true)
    (h : step s (.fold items mint n w) = .ok t) : w.applicationMint = true := by
  rw [fold_ok] at h
  exact h.2.2.2.2 hn

theorem existing_action_does_not_refresh_scope (s : State) (a : Asset) (w : Witnesses)
    (t : Result) (h : step s (.moveAction a 0 w) = .ok t) : t.state = s := by
  rw [moveAction_ok] at h
  rw [h.2.2]

theorem resolve_unauthenticated (s : State) (key : Nat) :
    resolve s key false = .unauthenticated := by
  rfl

theorem resolve_absent (s : State) (key : Nat) (h : (entry s key).value = none) :
    resolve s key true = .absent := by
  simp [resolve, h]

theorem resolve_over (s : State) (key : Nat) (h : (entry s key).value = some .over) :
    resolve s key true = .retired := by
  simp [resolve, h]

theorem resolve_address_iff (s : State) (key datum : Nat) :
    resolve s key true = .address datum ↔ (entry s key).value = some .active ∧
    ∃ u, s.applications.find? (fun u => u.key == key &&
      u.output.representative == representative s key && u.output.quantity == 1) = some u ∧
      u.output.datum = datum := by
  simp only [resolve, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  repeat' split
  all_goals simp [*]

theorem resolve_pending_iff (s : State) (key : Nat) :
    resolve s key true = .pending ↔ (entry s key).value = some .active ∧
    s.applications.find? (fun u => u.key == key &&
      u.output.representative == representative s key && u.output.quantity == 1) = none := by
  simp only [resolve, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  repeat' split
  all_goals simp [*]

theorem release_registry_independent (s : State) (entries : List Entry) (r : Request) :
    releaseNative { s with entries := entries } r = releaseNative s r := by
  rfl

theorem insert_creation_registry_independent (s : State) (entries : List Entry) (r : Request) :
    insertNative { s with entries := entries } r = insertNative s r := by
  rfl

theorem whole_release_acceptance_independent (s : State) (entries : List Entry)
    (id : Nat) (r : Request) (e : ReleaseEvidence) (w : Witnesses) :
    (∃ t, step { s with entries := entries } (.release id r e w) = .ok t) ↔
    (∃ t, step s (.release id r e w) = .ok t) := by
  rw [step_release_entries]
  cases step s (.release id r e w) <;> simp [Except.map]

theorem whole_release_refusal_independent (s : State) (entries : List Entry)
    (id : Nat) (r : Request) (e : ReleaseEvidence) (w : Witnesses) (reason : String) :
    step { s with entries := entries } (.release id r e w) = .error reason ↔
    step s (.release id r e w) = .error reason := by
  rw [step_release_entries]
  cases step s (.release id r e w) <;> simp [Except.map]

theorem whole_insert_acceptance_independent (s : State) (entries : List Entry)
    (r : Request) (a : Approval) (w : Witnesses) :
    (∃ t, step { s with entries := entries } (.createInsert r a w) = .ok t) ↔
    (∃ t, step s (.createInsert r a w) = .ok t) := by
  rw [step_createInsert_entries]
  cases step s (.createInsert r a w) <;> simp [Except.map]

theorem whole_insert_refusal_independent (s : State) (entries : List Entry)
    (r : Request) (a : Approval) (w : Witnesses) (reason : String) :
    step { s with entries := entries } (.createInsert r a w) = .error reason ↔
    step s (.createInsert r a w) = .error reason := by
  rw [step_createInsert_entries]
  cases step s (.createInsert r a w) <;> simp [Except.map]

end Statements
end Singular
