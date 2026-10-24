import NoPin.ApplicationRequests.RefundLifecycleProofs

/-! Hypothetical lifecycle statements; frozen statements with proof status recorded per declaration. -/
namespace NoPin.ApplicationRequests.RefundLifecycle.Statements
open Singular Lean
/-- Hypothesis under #741, not accepted law. Status: PROVED.
configurationCreate inversion; independent conditions and observed effects. -/
theorem configurationCreate_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : configurationCreate_inversion_premise .none h c t decode release q) :
    configurationCreate_inversion_claim .none h c t decode release q := by
  unfold configurationCreate_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
bookRegistration inversion; independent conditions and observed effects. -/
theorem bookRegistration_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : bookRegistration_inversion_premise .none h c t decode release q) :
    bookRegistration_inversion_claim .none h c t decode release q := by
  unfold bookRegistration_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
bookTermination inversion; independent conditions and observed effects. -/
theorem bookTermination_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : bookTermination_inversion_premise .none h c t decode release q) :
    bookTermination_inversion_claim .none h c t decode release q := by
  unfold bookTermination_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
registrationFold inversion; independent conditions and observed effects. -/
theorem registrationFold_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : registrationFold_inversion_premise .none h c t decode release q) :
    registrationFold_inversion_claim .none h c t decode release q := by
  unfold registrationFold_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
ownerReclaim inversion; independent conditions and observed effects. -/
theorem ownerReclaim_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : ownerReclaim_inversion_premise .none h c t decode release q) :
    ownerReclaim_inversion_claim .none h c t decode release q := by
  unfold ownerReclaim_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
expiredCleanup inversion; independent conditions and observed effects. -/
theorem expiredCleanup_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : expiredCleanup_inversion_premise .none h c t decode release q) :
    expiredCleanup_inversion_claim .none h c t decode release q := by
  unfold expiredCleanup_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
terminationFold inversion; independent conditions and observed effects. -/
theorem terminationFold_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : terminationFold_inversion_premise .none h c t decode release q) :
    terminationFold_inversion_claim .none h c t decode release q := by
  unfold terminationFold_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
liveUpdate inversion; independent conditions and observed effects. -/
theorem liveUpdate_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : liveUpdate_inversion_premise .none h c t decode release q) :
    liveUpdate_inversion_claim .none h c t decode release q := by
  unfold liveUpdate_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
approvalBurn inversion; independent conditions and observed effects. -/
theorem approvalBurn_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : approvalBurn_inversion_premise .none h c t decode release q) :
    approvalBurn_inversion_claim .none h c t decode release q := by
  unfold approvalBurn_inversion_claim
  rw [
    show applicationStep .none h c decode release q.observation = applicationStepConditions h c decode release q.observation from Proofs.step_eq h c decode release q.observation,
    show applicationAction .none h c decode release q.observation q.action = applicationActionConditions h c decode release q.observation q.action from Proofs.action_eq h c decode release q.observation q.action]

/-- Hypothesis under #741, not accepted law. Status: PROVED.
registration lifecycle; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
termination burn; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
booking authority and parameters; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
treasury at booking; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
additive payments; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
folder protection; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
burning grants nothing; independent conditions and observed effects. -/
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

/-- Hypothesis under #741, not accepted law. Status: PROVED.
no stuck termination; independent conditions and observed effects. -/
theorem no_stuck_termination (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : no_stuck_termination_premise .none h c t decode release q) :
    no_stuck_termination_claim .none h c t decode release q := by
  exact Proofs.termination_available h c t q _premises

/-- Hypothesis under #741, not accepted law. Status: PROVED.
approval burn open. -/
theorem approval_burn_open (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : approval_burn_open_premise .none h c t decode release q) :
    approval_burn_open_claim .none h c t decode release q := by
  rcases _premises with ⟨outside, actions, donation, mint⟩
  exact Proofs.approval_open h c decode release q.observation outside actions donation mint

/-- Hypothesis under #741, not accepted law. Status: PROVED.
configuration immutable. -/
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

end NoPin.ApplicationRequests.RefundLifecycle.Statements
