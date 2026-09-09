import Singular.Model
namespace Singular
namespace Statements
/-! Every declaration below is intentional statement-stage debt. No proofs
or readiness claim are supplied. Exact declaration identities are checked. -/

theorem insert_commitment_injective (p q : Proposal) :
    insertAsset p = insertAsset q ↔ p = q := by sorry

theorem action_domain_separation (p : Proposal) (reg id : Nat) (r : Refund) :
    Commitment.insert p ≠ Commitment.withdraw reg id r := by sorry

theorem createInsert_iff (s : State) (r : Request) (a : Approval) (w : Witnesses) (t : Result) :
    step s (.createInsert r a w) = .ok t ↔
    insertNative s r = true ∧ r.authenticatedOrigin = true ∧
    a.asset = insertAsset r.proposal ∧ approved s a w = true ∧ fresh s r.id = true ∧
    t = { state := { s with requests := r :: s.requests,       approvals := a :: s.approvals, used := r.id :: s.used } } := by sorry

theorem mintWithdraw_iff (s : State) (a : Approval) (w : Witnesses) (t : Result) :
    step s (.mintWithdraw a w) = .ok t ↔ approved s a w = true ∧
    (∃ id refund, a.asset.name = .withdraw s.config.registry id refund) ∧
    t = { state := { s with approvals := a :: s.approvals } } := by sorry

theorem release_iff (s : State) (id : Nat) (r : Request) (e : ReleaseEvidence)
    (w : Witnesses) (t : Result) :
    step s (.release id r e w) = .ok t ↔
    ∃ u, s.applications.find? (·.id == id) = some u ∧
    w.applicationSpend = true ∧ e.accepted = true ∧ e.source = id ∧ e.request = r ∧
    releaseNative s r = true ∧ r.authenticatedOrigin = true ∧
    r.held = some u.output.representative ∧ u.key = r.proposal.key ∧ fresh s r.id = true ∧
    t = { state := { (consume s id) with requests := r :: (consume s id).requests,       used := r.id :: (consume s id).used } } := by sorry

theorem evolve_iff (s : State) (id : Nat) (u : ApplicationUTxO) (e : EvolutionEvidence)
    (w : Witnesses) (t : Result) :
    step s (.evolve id u e w) = .ok t ↔
    ∃ old, s.applications.find? (·.id == id) = some old ∧
    w.applicationSpend = true ∧ e.accepted = true ∧ e.source = id ∧ e.successor = u ∧
    u.output.representative = old.output.representative ∧ u.output.quantity = 1 ∧
    u.key = old.key ∧ fresh s u.id = true ∧
    t = { state := { (consume s id) with applications := u :: (consume s id).applications,       used := u.id :: (consume s id).used } } := by sorry

theorem outsider_iff (s : State) (r : Request) (t : Result) :
    step s (.outsider r) = .ok t ↔ fresh s r.id = true ∧ r.held = none ∧
    t = { state := { s with requests := { r with authenticatedOrigin := false } :: s.requests,       used := r.id :: s.used } } := by sorry

theorem withdraw_iff (s : State) (id : Nat) (a : Asset) (refund : Refund)
    (w : Witnesses) (t : Result) :
    step s (.withdraw id a refund w) = .ok t ↔
    ∃ r, s.requests.find? (·.id == id) = some r ∧ w.nativeSpend = true ∧
    r.authenticatedOrigin = true ∧ insertNative s r = true ∧ recognized s a = true ∧
    a.name = .withdraw s.config.registry id refund ∧ t = { state := consume s id } := by sorry

theorem fold_iff (s : State) (items : List FoldItem) (mint : List Delta) (net : List ActionDelta)
    (w : Witnesses) (t : Result) :
    step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧
    foldItems s items = .ok t ∧ sameNet t.logical mint = true ∧
    (nonzero mint = true → w.representativeMint = true) ∧
    (actionNonzero net = true → w.applicationMint = true) := by sorry

theorem moveAction_iff (s : State) (a : Asset) (n : Int) (w : Witnesses) (t : Result) :
    step s (.moveAction a n w) = .ok t ↔ recognized s a = true ∧ n = 0 ∧
    t = { state := s } := by sorry

theorem escape_refused (s : State) (id : Nat) :
    step s (.escape id) = .error "completion-only-custody" := by sorry

theorem foldOne_insert_iff (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation = .insert) :
    foldOne s i = .ok t ↔ r.authenticatedOrigin = true ∧ insertNative s r = true ∧
    r.token.any (recognized s) = true ∧ (entry s r.proposal.key).value = none ∧
    r.proposal.scope.contains (entry s r.proposal.key).incarnation = true ∧
    r.proposal.initial.representative = representative s r.proposal.key ∧
    i.output = some r.proposal.initial ∧ fresh s i.outputId = true ∧
    t = { state := { (setEntry (consume s r.id) { (entry s r.proposal.key) with value := some .active }) with       applications := { id := i.outputId, key := r.proposal.key, output := r.proposal.initial } ::         (consume s r.id).applications, used := i.outputId :: s.used },       logical := [{ asset := representative s r.proposal.key, quantity := 1 }] } := by sorry

theorem foldOne_terminal_iff (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation ≠ .insert) :
    foldOne s i = .ok t ↔ r.authenticatedOrigin = true ∧ releaseNative s r = true ∧
    r.held = some (representative s r.proposal.key) ∧
    (entry s r.proposal.key).value = some .active ∧ i.output = none ∧
    t = { state := setEntry (consume s r.id) { (entry s r.proposal.key) with       value := if r.operation == .update then some .over else none,       incarnation := if r.operation == .delete then (entry s r.proposal.key).incarnation + 1         else (entry s r.proposal.key).incarnation },       logical := [{ asset := representative s r.proposal.key, quantity := -1 }] } := by sorry

theorem sequential_fold_cons (s : State) (i : FoldItem) (is : List FoldItem) (t : Result) :
    foldItems s (i :: is) = .ok t ↔ ∃ first rest,
    foldOne s i = .ok first ∧ foldItems first.state is = .ok rest ∧
    t = { state := rest.state, logical := first.logical ++ rest.logical } := by sorry

theorem supply_conservation (s : State) (a : Action) (t : Result)
    (reachable : Reachable s) (success : step s a = .ok t) : WellFormed t.state := by sorry

theorem over_terminal (s : State) (a : Action) (t : Result) (key : Nat)
    (reachable : Reachable s) (over : (entry s key).value = some .over)
    (success : step s a = .ok t) : (entry t.state key).value = some .over := by sorry

theorem over_no_representative (s : State) (key : Nat) (reachable : Reachable s)
    (over : (entry s key).value = some .over) : supply s key = 0 := by sorry

theorem pending_insert_no_representative (s : State) (r : Request) (a : Approval)
    (w : Witnesses) (t : Result) (h : step s (.createInsert r a w) = .ok t) :
    r.held = none ∧ t.state.entries = s.entries ∧ t.state.applications = s.applications := by sorry

theorem minting_requires_configured_issuer (s : State) (r : Request) (a : Approval)
    (w : Witnesses) (t : Result) (h : step s (.createInsert r a w) = .ok t) :
    a.asset.policy = s.config.applicationPolicy ∧ a.accepted = true ∧ w.applicationMint = true := by sorry

theorem withdrawal_preserves_registry_supply (s : State) (id : Nat) (a : Asset)
    (refund : Refund) (w : Witnesses) (t : Result) (reachable : Reachable s)
    (h : step s (.withdraw id a refund w) = .ok t) :
    t.state.entries = s.entries ∧ t.state.applications = s.applications ∧ t.logical = [] := by sorry

theorem exact_withdraw_scope (s : State) (id : Nat) (a : Asset) (refund : Refund)
    (w : Witnesses) (t : Result) (h : step s (.withdraw id a refund w) = .ok t) :
    a.name = .withdraw s.config.registry id refund := by sorry

theorem local_evolution_registry_unchanged (s : State) (id : Nat) (u : ApplicationUTxO)
    (e : EvolutionEvidence) (w : Witnesses) (t : Result)
    (h : step s (.evolve id u e w) = .ok t) :
    t.state.entries = s.entries ∧ t.logical = [] := by sorry

theorem release_is_operation_specific (s : State) (id : Nat) (r : Request) (e : ReleaseEvidence)
    (w : Witnesses) (t : Result) (h : step s (.release id r e w) = .ok t) :
    e.request.operation = r.operation ∧ e.request = r ∧ w.applicationSpend = true := by sorry

theorem release_removes_application_custody (s : State) (id : Nat) (r : Request)
    (e : ReleaseEvidence) (w : Witnesses) (t : Result) (reachable : Reachable s)
    (h : step s (.release id r e w) = .ok t) :
    t.state.applications.find? (·.id == id) = none := by sorry

theorem request_single_spend (s : State) (i : FoldItem) (t : Result)
    (reachable : Reachable s) (h : foldOne s i = .ok t) :
    t.state.requests.find? (·.id == i.request) = none := by sorry

theorem approval_scope_checked (s : State) (i : FoldItem) (r : Request) (t : Result)
    (hr : s.requests.find? (·.id == i.request) = some r) (hop : r.operation = .insert)
    (h : foldOne s i = .ok t) :
    r.proposal.scope.contains (entry s r.proposal.key).incarnation = true := by sorry

theorem outsider_not_admitted (s : State) (r : Request) (t : Result)
    (h : step s (.outsider r) = .ok t) (i : FoldItem) (hi : i.request = r.id) :
    foldOne t.state i = .error "unauthenticated-request" := by sorry

theorem native_witness_even_zero_net (s : State) (items : List FoldItem) (n : List ActionDelta)
    (w : Witnesses) (t : Result) (h : step s (.fold items [] n w) = .ok t) :
    w.nativeSpend = true ∧ sameNet t.logical [] = true := by sorry

theorem nonzero_action_invokes_policy (s : State) (items : List FoldItem) (mint : List Delta)
    (n : List ActionDelta) (w : Witnesses) (t : Result) (hn : actionNonzero n = true)
    (h : step s (.fold items mint n w) = .ok t) : w.applicationMint = true := by sorry

theorem existing_action_does_not_refresh_scope (s : State) (a : Asset) (w : Witnesses)
    (t : Result) (h : step s (.moveAction a 0 w) = .ok t) : t.state = s := by sorry

theorem resolve_unauthenticated (s : State) (key : Nat) :
    resolve s key false = .unauthenticated := by sorry

theorem resolve_absent (s : State) (key : Nat) (h : (entry s key).value = none) :
    resolve s key true = .absent := by sorry

theorem resolve_over (s : State) (key : Nat) (h : (entry s key).value = some .over) :
    resolve s key true = .retired := by sorry

theorem resolve_address_iff (s : State) (key datum : Nat) :
    resolve s key true = .address datum ↔ (entry s key).value = some .active ∧
    ∃ u, s.applications.find? (fun u => u.key == key &&
      u.output.representative == representative s key && u.output.quantity == 1) = some u ∧
      u.output.datum = datum := by sorry

theorem resolve_pending_iff (s : State) (key : Nat) :
    resolve s key true = .pending ↔ (entry s key).value = some .active ∧
    s.applications.find? (fun u => u.key == key &&
      u.output.representative == representative s key && u.output.quantity == 1) = none := by sorry

theorem release_registry_independent (s : State) (entries : List Entry) (r : Request) :
    releaseNative { s with entries := entries } r = releaseNative s r := by sorry

theorem insert_creation_registry_independent (s : State) (entries : List Entry) (r : Request) :
    insertNative { s with entries := entries } r = insertNative s r := by sorry

theorem whole_release_acceptance_independent (s : State) (entries : List Entry)
    (id : Nat) (r : Request) (e : ReleaseEvidence) (w : Witnesses) :
    (∃ t, step { s with entries := entries } (.release id r e w) = .ok t) ↔
    (∃ t, step s (.release id r e w) = .ok t) := by sorry

theorem whole_release_refusal_independent (s : State) (entries : List Entry)
    (id : Nat) (r : Request) (e : ReleaseEvidence) (w : Witnesses) (reason : String) :
    step { s with entries := entries } (.release id r e w) = .error reason ↔
    step s (.release id r e w) = .error reason := by sorry

theorem whole_insert_acceptance_independent (s : State) (entries : List Entry)
    (r : Request) (a : Approval) (w : Witnesses) :
    (∃ t, step { s with entries := entries } (.createInsert r a w) = .ok t) ↔
    (∃ t, step s (.createInsert r a w) = .ok t) := by sorry

theorem whole_insert_refusal_independent (s : State) (entries : List Entry)
    (r : Request) (a : Approval) (w : Witnesses) (reason : String) :
    step { s with entries := entries } (.createInsert r a w) = .error reason ↔
    step s (.createInsert r a w) = .error reason := by sorry

end Statements
end Singular
