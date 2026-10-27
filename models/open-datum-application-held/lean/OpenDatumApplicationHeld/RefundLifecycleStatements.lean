import OpenDatumApplicationHeld.RefundLifecycleProofs

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld.RefundLifecycle.Statements
open Singular Lean SingularApplicationHeld

theorem configurationCreate_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : configurationCreate_inversion_premise .none h c t decode release q) :
    configurationCreate_inversion_claim .none h c t decode release q := by
  unfold configurationCreate_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem bookRegistration_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : bookRegistration_inversion_premise .none h c t decode release q) :
    bookRegistration_inversion_claim .none h c t decode release q := by
  unfold bookRegistration_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem bookTermination_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : bookTermination_inversion_premise .none h c t decode release q) :
    bookTermination_inversion_claim .none h c t decode release q := by
  unfold bookTermination_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem registrationFold_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : registrationFold_inversion_premise .none h c t decode release q) :
    registrationFold_inversion_claim .none h c t decode release q := by
  unfold registrationFold_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem ownerReclaim_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : ownerReclaim_inversion_premise .none h c t decode release q) :
    ownerReclaim_inversion_claim .none h c t decode release q := by
  unfold ownerReclaim_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem expiredCleanup_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : expiredCleanup_inversion_premise .none h c t decode release q) :
    expiredCleanup_inversion_claim .none h c t decode release q := by
  unfold expiredCleanup_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem terminationFold_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : terminationFold_inversion_premise .none h c t decode release q) :
    terminationFold_inversion_claim .none h c t decode release q := by
  unfold terminationFold_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem liveUpdate_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : liveUpdate_inversion_premise .none h c t decode release q) :
    liveUpdate_inversion_claim .none h c t decode release q := by
  unfold liveUpdate_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem approvalBurn_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : approvalBurn_inversion_premise .none h c t decode release q) :
    approvalBurn_inversion_claim .none h c t decode release q := by
  unfold approvalBurn_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]


theorem registration_lifecycle (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : registration_lifecycle_premise .none h c t decode release q) :
    registration_lifecycle_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, Proofs.registration_effects h c decode release q.observation ?_⟩
    rwa [Proofs.step_eq]
  · exact And.left


theorem termination_burn (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : termination_burn_premise .none h c t decode release q) :
    termination_burn_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, Proofs.termination_effects h c decode release q.observation ?_⟩
    rwa [Proofs.step_eq]
  · exact And.left


theorem booking_authority_and_parameters (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : booking_authority_and_parameters_premise .none h c t decode release q) :
    booking_authority_and_parameters_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, Proofs.booking_effects h c decode release q.observation ?_⟩
    rwa [Proofs.step_eq]
  · exact And.left


theorem treasury_at_booking (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : treasury_at_booking_premise .none h c t decode release q) :
    treasury_at_booking_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, ?_⟩
    simp only [applicationStepConditions, Bool.and_eq_true, requestValueSplitConditions] at accepted
    exact accepted.2.2
  · exact And.left


theorem additive_payments (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : additive_payments_premise .none h c t decode release q) :
    additive_payments_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, ?_⟩
    simp only [applicationStepConditions, Bool.and_eq_true, requestValueSplitConditions] at accepted
    exact accepted.2.1
  · exact And.left


theorem folder_protection (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : folder_protection_premise .none h c t decode release q) :
    folder_protection_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, Proofs.folder_protected h c decode release q.observation ?_⟩
    rwa [Proofs.step_eq]
  · exact And.left


theorem burning_grants_nothing (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : burning_grants_nothing_premise .none h c t decode release q) :
    burning_grants_nothing_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, Proofs.burn_only h c decode release q.observation ?_⟩
    rwa [Proofs.step_eq]
  · exact And.left


theorem no_stuck_termination (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : no_stuck_termination_premise .none h c t decode release q) :
    no_stuck_termination_claim .none h c t decode release q := by
  exact Proofs.termination_available h c t q _premises


theorem approval_burn_open (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : approval_burn_open_premise .none h c t decode release q) :
    approval_burn_open_claim .none h c t decode release q := by
  rcases _premises with ⟨outside, actions, donation, mint⟩
  exact Proofs.approval_open h c decode release q.observation outside actions donation mint


theorem configuration_immutable (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : configuration_immutable_premise .none h c t decode release q) :
    configuration_immutable_claim .none h c t decode release q := by
  change applicationStep .none h c decode release q.observation = true ↔ _
  rw [Proofs.step_eq]
  constructor
  · intro accepted
    refine ⟨accepted, Proofs.configuration_protected h c decode release q.observation ?_⟩
    rwa [Proofs.step_eq]
  · exact And.left

theorem configuration_created_once (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : configuration_created_once_premise .none h c t decode release q) :
    configuration_created_once_claim .none h c t decode release q := by
  intro accepted registry seed index member
  exact Proofs.configuration_minted_once h c decode release q.observation accepted registry seed index member

end OpenDatumApplicationHeld.RefundLifecycle.Statements
