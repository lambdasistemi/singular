import OpenDatumApplicationHeld.MoneyHoldingClaims
import OpenDatumApplicationHeld.MoneyFoldProofs


namespace OpenDatumApplicationHeld.Money.Proofs
open Singular Lean SingularApplicationHeld
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
local instance : LawfulBEq TokenId where
  eq_of_beq := SingularApplicationHeld.Proofs.token_eq _ _
  rfl := by intro a; cases a; simp [reduceBEq]


theorem registration_holding_outcome (h : Hash) (c : Codec) (t : TrieCommit) (q : Input)
    (corr : Correspondence q) (p : FoldPremise h c t .registrationFold q) :
    HoldingSeparatedFoldOutcome .none h c t q := by
  let built := builtFor h c t .registrationFold q
  have accepted : fold .none h c t q.lifecycle.query.release built = true := by
    simpa only [fold, SingularApplicationHeld.Proofs.applyGuard_none, foldConditions] using p.1
  have effect := SingularApplicationHeld.Proofs.fold_effect h c t q.lifecycle.query.release built accepted
  refine ⟨accepted, effect, rfl, rfl, ?_, ?_⟩
  · cases hr : q.registration with
    | termination output registry key => simp [Correspondence, hr] at corr
    | registration output data =>
      have changes : built.changes = [.register output.reference data.key 1 data.deposit] := by
        simp [built, builtFor, reduceBEq, Journey.ctorIdx,
          SingularApplicationHeld.Proofs.public_build_changes,
          SingularApplicationHeld.Proofs.publicPlan, hr]
      constructor
      · rw [effect.1]
        simp [targetBatch, changes, targetTrie, PendingRequest.key]
      · have outputs := OpenDatumApplicationHeld.Money.Proofs.public_build_outputs h c t q.lifecycle.query.release
          q.lifecycle.query.observation.before [q.registration] q.lifecycle.query.funding
        change built.outputs = _ at outputs
        have delivery := SingularApplicationHeld.Proofs.fold_delivery h c t q.lifecycle.query.release built accepted
        have placed : quantity (SingularApplicationHeld.Proofs.publicHolding h c data)
            (activeAsset h c built.before.identity data.key) = 1 := by
          simp only [holdingDelivery, changes, List.all_cons, List.all_nil, Bool.and_true] at delivery
          rw [outputs] at delivery
          simp [SingularApplicationHeld.Proofs.publicPlan, hr, List.zipIdx_cons,
            List.zipIdx_nil, beq_iff_eq] at delivery
          exact delivery.1.2
        have same : activeAsset h c data.registry data.key = activeAsset h c built.before.identity data.key := by
          by_cases same : activeAsset h c data.registry data.key = activeAsset h c built.before.identity data.key
          · exact same
          · simp [quantity, SingularApplicationHeld.Proofs.publicHolding, same] at placed
        have conditions := accepted
        simp only [fold, SingularApplicationHeld.Proofs.applyGuard_none, Bool.and_eq_true] at conditions
        have own : (activeAsset h c data.registry data.key).policy = built.before.identity.policy := by rw [same]; rfl
        have delta := SingularApplicationHeld.Proofs.delta_at built.assets built.before.identity.policy
          (expectedDelta h c built) conditions.1.2 (activeAsset h c data.registry data.key) own
        simpa [expectedDelta, changes, same, hr, Change.key, PendingRequest.registry, PendingRequest.key] using delta
  · have outputs := OpenDatumApplicationHeld.Money.Proofs.public_build_outputs h c t q.lifecycle.query.release
      q.lifecycle.query.observation.before [q.registration] q.lifecycle.query.funding
    cases hr : q.registration with
    | termination output registry key => simp [Correspondence, hr] at corr
    | registration output data =>
      have different := p.2.2.2.1
      change q.lifecycle.query.funding.processorAddress ≠ q.lifecycle.query.observation.before.state.credential at different
      change built.outputs = _ at outputs
      change holdingSeparatedPayment .none built.outputs _ _ = _
      rw [outputs]
      simp [holdingSeparatedPayment, SingularApplicationHeld.Proofs.publicPlan, hr,
        SingularApplicationHeld.Proofs.publicHolding, quantity, paidTo,
        HoldingPaymentMutation.ctorIdx, builder_credential, Ne.symm different,
        newAllocation, amountAt, reduceBEq, PendingRequest.bid, PendingRequest.registry,
        PendingRequest.key, List.zipIdx_cons, List.zipIdx_nil]

theorem registration_holding_journey (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (q : Input)
    (p : NewPremise h c t decode release .registrationFold q) :
    HoldingSeparatedClaim .none h c t decode release q := by
  have accepted : RefundLifecycle.applicationStep .none h c decode release q.lifecycle.observation = true := by
    rw [RefundLifecycle.Proofs.step_eq]
    exact p.2.2.1
  have ef := effects h c decode release q.lifecycle.observation accepted
  refine ⟨accepted, ef.1, ef.2.1, ef.2.2.1, ef.2.2.2.1, ef.2.2.2.2,
    money_effect h c t decode release .registrationFold q p,
    allocations .registrationFold q p.1, ?_, by trivial, by trivial⟩
  have fp : FoldPremise h c t .registrationFold q := p.2.2.2.2.2.2.1
  exact registration_holding_outcome h c t q p.1 fp

end OpenDatumApplicationHeld.Money.Proofs
