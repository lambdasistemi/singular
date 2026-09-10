import Singular.NamingLemmas
namespace Singular
namespace NamingStatements
/-! The first-release naming statement surface. Every declaration here names one
observable property of the naming profile; the frozen demo journey constants in
`Singular.Naming` make each concrete statement a nonvacuous execution of the
real transition functions, and the quantified statements bind arbitrary queued
certified claims, not demo fixtures. -/

/-- The naming profile defines no delete: a crafted generic release carrying a
Delete request straight into the naming transition is refused with
`naming-no-delete`, never accepted and never a generic exception. -/
theorem naming_delete_refused (state : NamingState) (source : Nat) (request : Request)
    (evidence : ReleaseEvidence) (witness : Witnesses) :
    namingStep state (Action.release source request evidence witness) = .error "naming-no-delete" := by
  rfl

/-- Approval reserves nothing: two competing `alice` claims both queue, and
after both approvals the spelling's key is still absent, with no active record
and exactly the two pending claims. -/
theorem naming_approval_reserves_nothing :
    claimedTwice.registry.entries = [] ∧ claimedTwice.records = [] ∧
    claimedTwice.claims.length = 2 ∧ (entry claimedTwice.registry aliceKey).value = none := by
  decide

/-- The first valid fold of a certified absent-key Insert activates the key and
mints exactly one application output. -/
theorem naming_absent_certified_insert_activates :
    (entry activeOnce.registry aliceKey).value = some Value.active ∧
    activeOnce.registry.applications.length = 1 := by
  decide

/-- Uniqueness is decided only at fold: a competing certified Insert for the
now-occupied key is refused with the named registry reason. -/
theorem naming_occupied_key_refuses_duplicate :
    namingFoldRequest activeOnce 2 = .error "occupied-key" := by
  rfl

/-- Fixture preservation, quantified: for an arbitrary queued certified claim,
a successful fold of that claim places a record carrying the claim's key and
its four certified fixture fields, unchanged, into the active records. -/
theorem naming_fixture_fields_preserved_on_insert (state : NamingState) (claim : NamingClaim)
    (result : NamingResult)
    (hc : state.claims.find? (fun c => c.requestId == claim.requestId) = some claim)
    (hok : namingFoldRequest state claim.requestId = .ok result) :
    ∃ rec, rec.key = claim.key ∧ rec.fixture = claim.fixture ∧ rec ∈ result.state.records := by
  have hinst : (namingFoldAction state claim.requestId).bind (namingStep state) = .ok result := by
    have hunfold : namingFoldRequest state claim.requestId =
        (requireSome (state.claims.find? (fun c => c.requestId == claim.requestId)) "request-unavailable").bind
          fun _ => (namingFoldAction state claim.requestId).bind (namingStep state) := rfl
    rw [hunfold, hc, requireSome, exceptBindOkClaim] at hok
    exact hok
  cases rq : state.registry.requests.find? (fun q => q.id == claim.requestId) with
  | none =>
    rw [namingFoldAction, rq] at hinst
    rw [exceptBindErrAction] at hinst
    exact absurd hinst (by simp)
  | some r =>
    by_cases hop : r.operation = Operation.insert
    · exact namingFoldInsertPreservesFixture state claim r result hc rq hop hinst
    · exfalso
      rw [namingFoldAction, rq] at hinst
      rw [exceptBindOkAction] at hinst
      simp only [namingStep, List.any_cons, List.any_nil] at hinst
      rw [rq] at hinst
      dsimp only at hinst
      cases hopr : r.operation with
      | insert => exact hop hopr
      | delete =>
        rw [hopr] at hinst
        change (Except.error "naming-no-delete" : Except String NamingResult) = .ok result at hinst
        simp at hinst
      | update =>
        rw [hopr] at hinst
        change (Except.error "naming-no-delete" : Except String NamingResult) = .ok result at hinst
        simp at hinst

/-- An unauthenticated view observes nothing about the naming state. -/
theorem naming_unauthenticated_resolve (state : NamingState) (key : Nat) :
    namingResolve state key false = .ok NamingObservation.unauthenticated := by
  rfl

/-- The demo fixture's payment destination is present and distinct from the
control address; the competing fixture's is absent. Both are well formed. -/
theorem naming_payment_destination_distinct_from_control :
    aliceFixture.paymentDestination = some destinationAddress ∧
    aliceFixture.controlAddress = controllerAddress ∧
    aliceFixture.paymentDestination != some aliceFixture.controlAddress ∧
    paymentKeyAddress aliceFixture.controlAddress = true ∧
    wellFormedCommitment aliceFixture.nextControlCommitment = true ∧
    wellFormedFixture aliceFixture = true ∧ wellFormedFixture otherFixture = true := by
  decide

/-! Branch inversions: every decision branch of the naming transition, the
queue guards, and the observation carries an exact-premise characterization. -/

/-- The createInsert branch is the generic registry transition lifted into the
naming state; the naming layer adds nothing and refuses nothing here. -/
theorem naming_step_create_insert (state : NamingState) (r : Request) (a : Approval) (w : Witnesses) :
    namingStep state (Action.createInsert r a w) =
      (step state.registry (Action.createInsert r a w)).map
        (fun res => { state := { state with registry := res.state }, logical := res.logical }) := by
  rfl

/-- The fold branch, under the exact premise that every item's queued request
is a certified Insert, is the generic fold lifted with claim migration and
nothing else. -/
theorem naming_step_fold_generic_when_all_insert (state : NamingState) (items : List FoldItem)
    (mint : List Delta) (net : List ActionDelta) (w : Witnesses)
    (ht : ∀ (i : FoldItem) (r : Request),
        state.registry.requests.find? (fun q => q.id == i.request) = some r →
        r.operation = Operation.insert) :
    namingStep state (Action.fold items mint net w) =
      (step state.registry (Action.fold items mint net w)).map
        (fun res => { state := migrateClaims state items res.state, logical := res.logical }) := by
  rw [namingStepFoldActionEq, if_neg (namingTerminalFalse state items ht)]
  rw [exceptMapEqAny]

/-- The catch-all branch: an action that is neither a certified Insert queue
nor a fold is refused with `naming-no-delete`. -/
theorem naming_step_refuses_other (state : NamingState) (a : Action)
    (h : match a with
      | .createInsert _ _ _ => False
      | .fold _ _ _ _ => False
      | _ => True) :
    namingStep state a = .error "naming-no-delete" := by
  cases a <;> (first | simp_all [namingStep, throwEqError] | rfl)

/-- Queue guard one: an unknown spelling is exactly what refuses a queue with
`unknown-spelling`. -/
theorem naming_queue_unknown_spelling_iff (spelling : String) (fixture : NamingFixture) :
    namingQueueValidate spelling fixture true = .error "unknown-spelling" ↔
      spellingKey spelling = none := by
  cases hkey : spellingKey spelling <;>
    cases hfixture : wellFormedFixture fixture <;>
    simp [namingQueueValidate, hkey, hfixture]

/-- Queue guard two: with a known spelling, a malformed fixture is exactly what
refuses a queue with `invalid-fixture`. -/
theorem naming_queue_malformed_fixture_iff (spelling : String) (fixture : NamingFixture)
    (key : Nat) (hkey : spellingKey spelling = some key) :
    namingQueueValidate spelling fixture true = .error "invalid-fixture" ↔
      wellFormedFixture fixture = false := by
  cases hfixture : wellFormedFixture fixture <;>
    simp [namingQueueValidate, hkey, hfixture]

/-- Queue guard three: with a known spelling and a well-formed fixture, a
rejected application approval is exactly what refuses the queue. -/
theorem naming_queue_unapproved_refused (spelling : String) (fixture : NamingFixture)
    (key : Nat) (hkey : spellingKey spelling = some key)
    (hok : wellFormedFixture fixture = true) :
    namingQueueValidate spelling fixture false = .error "application-approval" := by
  simp [namingQueueValidate, hkey, hok]

/-- Observation branch one: the unauthenticated observation is exactly the
unauthenticated view. -/
theorem naming_resolve_unauthenticated_iff (state : NamingState) (key : Nat) (authenticated : Bool) :
    namingResolve state key authenticated = .ok NamingObservation.unauthenticated ↔
      authenticated = false := by
  cases authenticated with
  | false => simp [namingResolve]
  | true =>
    cases hr : state.records.find? (fun r => r.key == key) with
    | some rec => simp [namingResolve, hr]
    | none =>
      cases he : (entry state.registry key).value with
      | some value => cases value <;> simp [namingResolve, hr, he]
      | none =>
        cases hc : state.claims.any (fun c => c.key == key) <;>
          simp [namingResolve, hr, he, hc]

/-- Observation branch two: an active observation is exactly a record for the
key, and its fixture is the recorded certified fixture. -/
theorem naming_resolve_active_iff (state : NamingState) (key : Nat) (fixture : NamingFixture) :
    namingResolve state key true = .ok (NamingObservation.active fixture) ↔
      ∃ rec, state.records.find? (fun r => r.key == key) = some rec ∧ rec.fixture = fixture := by
  cases hr : state.records.find? (fun r => r.key == key) with
  | some rec => simp [namingResolve, hr]
  | none =>
    cases he : (entry state.registry key).value with
    | some value => cases value <;> simp [namingResolve, hr, he]
    | none =>
      cases hc : state.claims.any (fun c => c.key == key) <;>
        simp [namingResolve, hr, he, hc]

/-- Observation branch three: with no record, pending is exactly an active
entry awaiting its record or a queued claim. Over is a distinct observation. -/
theorem naming_resolve_pending_iff (state : NamingState) (key : Nat)
    (hno : state.records.find? (fun r => r.key == key) = none) :
    namingResolve state key true = .ok NamingObservation.pending ↔
      ((entry state.registry key).value = some .active ||
        ((entry state.registry key).value = none ∧ state.claims.any (fun c => c.key == key))) := by
  cases he : (entry state.registry key).value with
  | some value => cases value <;> simp [namingResolve, hno, he]
  | none =>
    cases hc : state.claims.any (fun c => c.key == key) <;>
      simp [namingResolve, hno, he, hc]

/-- Observation branch four: with no record, absent is exactly a key that is
neither present in the registry nor claimed. -/
theorem naming_resolve_absent_iff (state : NamingState) (key : Nat)
    (hno : state.records.find? (fun r => r.key == key) = none) :
    namingResolve state key true = .ok NamingObservation.absent ↔
      ((entry state.registry key).value = none ∧ ¬state.claims.any (fun c => c.key == key)) := by
  cases he : (entry state.registry key).value with
  | some value => cases value <;> simp [namingResolve, hno, he]
  | none =>
    cases hc : state.claims.any (fun c => c.key == key) <;>
      simp [namingResolve, hno, he, hc]

end NamingStatements
end Singular
