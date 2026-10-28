import NoPin.ApplicationRequests.MoneyProofs

/-! Hypothetical journey composition; no accepted application law. -/
namespace NoPin.ApplicationRequests.Money.Proofs
open Singular Lean
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
local instance : LawfulBEq Journey where
  eq_of_beq := by intro a b h; cases a <;> cases b <;> simp_all [reduceBEq, Journey.ctorIdx]
  rfl := by intro a; cases a <;> rfl
local instance : LawfulBEq TokenId where
  eq_of_beq := NoPin.ApplicationRequests.Proofs.token_eq _ _
  rfl := by intro a; cases a; simp
local instance : LawfulBEq OutRef where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq ApplicationParameters where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq OutputDatum where
  eq_of_beq := by intro a b h; cases a <;> cases b <;> simp_all [reduceBEq]
  rfl := by intro a; cases a <;> simp [reduceBEq]
local instance : LawfulBEq ProtectedControl where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq RegistrationData where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq ApplicationDatum where
  eq_of_beq := by intro a b h; cases a <;> cases b <;> simp_all [reduceBEq]
  rfl := by intro a; cases a <;> simp [reduceBEq]
local instance : LawfulBEq ObservedOutput where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]

theorem registration_source (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (a : ApplicationAction)
    (output : ObservedOutput) (r : RegistrationData)
    (accepted : RefundApplication.applicationStep .none h c decode release o = true)
    (am : a ∈ o.actions) (href : a.inputReference = some output.reference)
    (member : output ∈ o.inputs) (hd : decoded decode output = some (.registration r)) :
    o.inputs.find? (fun input => input.reference == output.reference) = some output := by
  have ha := RefundLifecycle.Proofs.accepted_actions h c decode release o accepted a am
  obtain ⟨selected, found, one⟩ := RefundLifecycle.Proofs.action_source h c decode release o a output.reference href ha
  exact RefundLifecycle.Proofs.unique_find _ _ output member (by simp) one

theorem money_effect (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (journey : Journey) (q : Input)
    (p : NewPremise h c t decode release journey q) : actualMoneyEffect journey q = true := by
  obtain ⟨corr, rel, conditions, stage, actions, matching, rest⟩ := p
  have accepted : RefundApplication.applicationStep .none h c decode release q.lifecycle.observation = true := by
    change RefundLifecycle.applicationStep .none h c decode release q.lifecycle.observation = true
    rwa [RefundLifecycle.Proofs.step_eq]
  have ef := effects h c decode release q.lifecycle.observation accepted
  have treasury := ef.2.2.2.1
  cases hj : journey <;> cases ha : q.lifecycle.action <;>
    simp only [hj, ha, stageAction, Bool.false_eq_true] at stage
  all_goals simp only [actualMoneyEffect]
  all_goals try { simpa [RefundLifecycle.treasuryEffect, actions, ha] using treasury }
  case terminationBooking.bookTermination ref index =>
    simp only [stageCorrespondence, hj, ha, Bool.and_eq_true] at matching
    rcases matching with ⟨_, matching⟩
    repeat' first | (split at matching) | (solve | simp_all)
    all_goals simp_all [RefundLifecycle.treasuryEffect, actions, ha, beq_iff_eq,
      List.filterMap_cons, List.filterMap_nil, bind, Option.bind, pure]
  all_goals
    cases hr : q.registration with
    | termination output registry key => simp [stageCorrespondence, hj, ha, hr] at matching
    | registration output data =>
      simp only [stageCorrespondence, hj, ha, hr, PendingRequest.output,
        Bool.and_eq_true, beq_iff_eq, List.contains_iff_mem] at matching
      have reference := matching.1.1
      have member := matching.1.2
      have hd := matching.2
      have found := registration_source h c decode release q.lifecycle.observation q.lifecycle.action output data
        accepted (by simp [actions]) (by simp [ha, ApplicationAction.inputReference, reference]) member hd
      have reg := List.all_eq_true.mp ef.1 q.lifecycle.action (by simp [actions])
      simp only [RefundLifecycle.registrationEffects] at reg
      simp only [ha, ApplicationAction.inputReference, reference, found, hd] at reg
      simp [reduceBEq, Journey.ctorIdx, hr, RefundLifecycle.registrationEffect, ha, Bool.and_eq_true,
        decide_eq_true_eq, beq_iff_eq] at reg ⊢
      omega

theorem reclaim_signer (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (p : NewPremise h c t decode release .reclaim q) :
    q.lifecycle.observation.signers.contains q.baseline.registration.request.refundAddress = true := by
  obtain ⟨corr, rel, conditions, stage, actions, matching, rest⟩ := p
  have accepted : RefundLifecycle.applicationStep .none h c decode release q.lifecycle.observation = true := by
    rwa [RefundLifecycle.Proofs.step_eq]
  cases ha : q.lifecycle.action <;> simp only [ha, stageAction, Bool.false_eq_true] at stage
  rename_i ref
  cases hr : q.registration with
  | termination output registry key => simp [Correspondence, hr] at corr
  | registration output data =>
    simp only [stageCorrespondence, ha, hr, PendingRequest.output, Bool.and_eq_true,
      beq_iff_eq, List.contains_iff_mem] at matching
    have found := registration_source h c decode release q.lifecycle.observation q.lifecycle.action output data
      accepted (by simp [actions]) (by simp [ha, ApplicationAction.inputReference, matching.1.1])
      matching.1.2 matching.2
    have effects := RefundLifecycle.Proofs.registration_effects h c decode release q.lifecycle.observation accepted
    have reg := List.all_eq_true.mp effects q.lifecycle.action (by simp [actions])
    simp only [ha, ApplicationAction.inputReference, matching.1.1, found, matching.2,
      RefundLifecycle.registrationEffect, Bool.and_eq_true] at reg
    have refund : data.refundAddress = q.baseline.registration.request.refundAddress := by
      simp only [Correspondence, hr] at corr
      exact corr.2.2.2.2.2.2.1.2.1
    simpa [refund] using reg.1.2

theorem simple_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (journey : Journey) (q : Input)
    (p : NewPremise h c t decode release journey q)
    (notRegistration : journey ≠ .registrationFold) (notTermination : journey ≠ .terminationFold) :
    NewClaim .none h c t decode release journey q := by
  have accepted : RefundLifecycle.applicationStep .none h c decode release q.lifecycle.observation = true := by
    rw [RefundLifecycle.Proofs.step_eq]
    exact p.2.2.1
  have ef := effects h c decode release q.lifecycle.observation accepted
  refine ⟨accepted, ef.1, ef.2.1, ef.2.2.1, ef.2.2.2.1, ef.2.2.2.2,
    money_effect h c t decode release journey q p, allocations journey q p.1, ?_, ?_, ?_⟩
  · simp [notRegistration, notTermination, beq_iff_eq]
  · split
    · rename_i create
      have same : journey = .create := beq_iff_eq.mp create
      subst journey
      refine ⟨Singular.Reachable.initial _, ?_⟩
      have created := p.2.2.2.2.2.2.2
      simp only [beq_self_eq_true, ite_true] at created
      have rel := p.2.1
      simpa [genesis, genesisConditions, NoPin.ApplicationRequests.Proofs.applyGuard_none, rel] using created.1
    · trivial
  · split
    · rename_i reclaim
      have same : journey = .reclaim := beq_iff_eq.mp reclaim
      subst journey
      exact reclaim_signer h c t decode release q p
    · trivial

end NoPin.ApplicationRequests.Money.Proofs
