import NoPin.ApplicationRequests.RefundLifecycleClaims

/-! Hypothetical #741 proofs; no accepted application law. -/
namespace NoPin.ApplicationRequests.RefundLifecycle.Proofs
open Singular Lean
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192

@[simp] theorem appGuard_none (site : AppGuard) (b : Bool) : appGuard .none site b = b := rfl

theorem action_eq (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (a : ApplicationAction) :
    applicationAction .none h c decode release o a =
      applicationActionConditions h c decode release o a := by
  cases a <;> rfl

theorem step_eq (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) :
    applicationStep .none h c decode release o = applicationStepConditions h c decode release o := by
  have actions : RefundApplication.applicationAction .none h c decode release o =
      applicationActionConditions h c decode release o := funext (action_eq h c decode release o)
  unfold applicationStep RefundApplication.applicationStep applicationStepConditions
  rw [actions]
  rfl

theorem accepted_actions (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    ∀ a ∈ o.actions, applicationAction .none h c decode release o a = true := by
  simp only [applicationStep, RefundApplication.applicationStep, Bool.and_eq_true] at accepted
  exact List.all_eq_true.mp accepted.1.1.2

theorem termination_effects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    terminationEffects h c o = true := by
  apply List.all_eq_true.mpr
  intro a member
  have ha := accepted_actions h c decode release o accepted a member
  cases a <;> try rfl
  case terminationFold ref registry key =>
    simp only [applicationAction, RefundApplication.applicationAction,
      NoPin.ApplicationRequests.applicationAction, ApplicationAction.inputReference] at ha
    repeat' first
      | (split at ha)
      | (simp_all [terminationSpend])

theorem approval_open (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (outside : o.inputs.all (fun input => input.credential != release.applicationCredential) = true)
    (actions : o.actions = [.approvalBurn]) (donation : o.donation = 0)
    (mint : o.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy ||
      NoPin.mintQty o.assets entry.1 ≤ 0) = true) :
    applicationStep .none h c decode release o = true := by
  have empty : (o.inputs.filter fun input => input.credential == release.applicationCredential) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro input member
    have hi := List.all_eq_true.mp outside input member
    simpa using hi
  simpa [applicationStep, RefundApplication.applicationStep, actions, empty,
    appGuard_none, applicationAction, RefundApplication.applicationAction,
    NoPin.ApplicationRequests.applicationAction, requestValueSplit, requiredPayments,
    requiredTreasury, birth, donation, ApplicationAction.inputReference,
    ApplicationAction.birthIndex] using mint

theorem burn_maps (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (actions : List ApplicationAction)
    (only : actions.all (· == .approvalBurn) = true) :
    actions.filterMap ApplicationAction.inputReference = [] ∧
    actions.filterMap (birth h c decode release o) = [] := by
  induction actions with
  | nil => exact ⟨rfl, rfl⟩
  | cons a rest ih =>
    have both : (a == .approvalBurn) = true ∧ rest.all (· == .approvalBurn) = true := by
      simpa only [List.all_cons, Bool.and_eq_true] using only
    have same : a = .approvalBurn := by
      cases a <;> first | rfl | exact False.elim (Bool.noConfusion both.1)
    subst a
    simpa [ApplicationAction.inputReference, birth] using ih both.2

theorem burn_only (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    burnOnlyEffect release o = true := by
  unfold burnOnlyEffect
  split
  · rename_i only
    obtain ⟨refs, births⟩ := burn_maps h c decode release o o.actions only
    simp only [applicationStep, RefundApplication.applicationStep, appGuard_none, refs,
      births, Bool.and_eq_true] at accepted
    have empty : (o.inputs.filter fun input => input.credential == release.applicationCredential) = [] := by
      have size := accepted.1.1.1.1.1.2
      have zero : (o.inputs.filter fun input => input.credential == release.applicationCredential).length = 0 := by
        have reverse : 0 = (o.inputs.filter fun input => input.credential == release.applicationCredential).length := by
          simpa only [beq_iff_eq] using size
        exact reverse.symm
      exact List.length_eq_zero_iff.mp zero
    simp only [Bool.and_eq_true]
    constructor
    · apply List.all_eq_true.mpr
      intro input member
      have absent := List.filter_eq_nil_iff.mp empty input member
      simpa using absent
    · simpa using accepted.1.2
  · rfl

theorem booking_effects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    bookingEffects h c decode release o = true := by
  apply List.all_eq_true.mpr
  intro a member
  have ha := accepted_actions h c decode release o accepted a member
  cases a <;> try rfl
  case bookRegistration index =>
    simp only [applicationAction, RefundApplication.applicationAction,
      NoPin.ApplicationRequests.applicationAction] at ha
    dsimp only [Id.run, pure, bind] at ha ⊢
    repeat' first | (split at ha) | (split) | (solve | simp_all)
    all_goals
      try dsimp only [Id.run, pure, bind] at ha ⊢
      simp only [registrationBook, appGuard_none, Bool.and_eq_true, List.any_eq_true] at ha
      simp_all only [Option.some.injEq, ApplicationDatum.registration.injEq]
      simp only [Bool.and_eq_true]
      refine ⟨by trivial, ?_⟩
      rcases ha.1.2 with ⟨configuration, member, hc⟩
      apply List.any_eq_true.mpr
      refine ⟨configuration, member, ?_⟩
      cases hd : configuration.datum <;>
        simp_all [configurationRead, configurationShape, registrationClock,
          nonemptyInterval, Bool.and_eq_true]
  case bookTermination ref index =>
    simp only [applicationAction, RefundApplication.applicationAction,
      NoPin.ApplicationRequests.applicationAction, ApplicationAction.inputReference] at ha
    dsimp only [Id.run, pure, bind] at ha ⊢
    repeat' first | (split at ha) | (split) | (solve | simp_all [terminationBook])


end NoPin.ApplicationRequests.RefundLifecycle.Proofs
