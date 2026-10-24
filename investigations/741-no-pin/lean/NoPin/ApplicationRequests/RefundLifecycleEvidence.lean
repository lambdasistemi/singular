import NoPin.ApplicationRequests.RefundLifecycleStatements
import NoPin.ApplicationRequests.RefundLifecycleFixtures

set_option maxRecDepth 16384
set_option maxHeartbeats 4000000
namespace NoPin.ApplicationRequests.RefundLifecycle.Evidence
open Singular Lean NoPin.ApplicationRequests.Fixtures RefundLifecycle.Fixtures
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem configurationCreate_inversion_antecedent : configurationCreate_inversion_premise .none hash code commit decode release (inputFor "configurationCreate") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem configurationCreate_inversion_positive : configurationCreate_inversion_claim .none hash code commit decode release (inputFor "configurationCreate") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem configurationCreate_inversion_mutant : ¬ (configurationCreate_inversion_premise (.flip .configurationShape) hash code commit decode release (inputFor "configurationCreate") → configurationCreate_inversion_claim (.flip .configurationShape) hash code commit decode release (inputFor "configurationCreate")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem bookRegistration_inversion_antecedent : bookRegistration_inversion_premise .none hash code commit decode release (inputFor "bookRegistration") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem bookRegistration_inversion_positive : bookRegistration_inversion_claim .none hash code commit decode release (inputFor "bookRegistration") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem bookRegistration_inversion_mutant : ¬ (bookRegistration_inversion_premise (.flip .configurationShape) hash code commit decode release (inputFor "bookRegistration") → bookRegistration_inversion_claim (.flip .configurationShape) hash code commit decode release (inputFor "bookRegistration")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem bookTermination_inversion_antecedent : bookTermination_inversion_premise .none hash code commit decode release (inputFor "bookTermination") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem bookTermination_inversion_positive : bookTermination_inversion_claim .none hash code commit decode release (inputFor "bookTermination") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem bookTermination_inversion_mutant : ¬ (bookTermination_inversion_premise (.flip .bookingSignature) hash code commit decode release (inputFor "bookTermination") → bookTermination_inversion_claim (.flip .bookingSignature) hash code commit decode release (inputFor "bookTermination")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem registrationFold_inversion_antecedent : registrationFold_inversion_premise .none hash code commit decode release (inputFor "registrationFold") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem registrationFold_inversion_positive : registrationFold_inversion_claim .none hash code commit decode release (inputFor "registrationFold") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem registrationFold_inversion_mutant : ¬ (registrationFold_inversion_premise (.flip .registrationShape) hash code commit decode release (inputFor "registrationFold") → registrationFold_inversion_claim (.flip .registrationShape) hash code commit decode release (inputFor "registrationFold")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem ownerReclaim_inversion_antecedent : ownerReclaim_inversion_premise .none hash code commit decode release (inputFor "ownerReclaim") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem ownerReclaim_inversion_positive : ownerReclaim_inversion_claim .none hash code commit decode release (inputFor "ownerReclaim") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem ownerReclaim_inversion_mutant : ¬ (ownerReclaim_inversion_premise (.flip .registrationShape) hash code commit decode release (inputFor "ownerReclaim") → ownerReclaim_inversion_claim (.flip .registrationShape) hash code commit decode release (inputFor "ownerReclaim")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem expiredCleanup_inversion_antecedent : expiredCleanup_inversion_premise .none hash code commit decode release (inputFor "expiredCleanup") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem expiredCleanup_inversion_positive : expiredCleanup_inversion_claim .none hash code commit decode release (inputFor "expiredCleanup") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem expiredCleanup_inversion_mutant : ¬ (expiredCleanup_inversion_premise (.flip .registrationShape) hash code commit decode release (inputFor "expiredCleanup") → expiredCleanup_inversion_claim (.flip .registrationShape) hash code commit decode release (inputFor "expiredCleanup")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem terminationFold_inversion_antecedent : terminationFold_inversion_premise .none hash code commit decode release (inputFor "terminationFold") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem terminationFold_inversion_positive : terminationFold_inversion_claim .none hash code commit decode release (inputFor "terminationFold") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem terminationFold_inversion_mutant : ¬ (terminationFold_inversion_premise (.flip .terminationShape) hash code commit decode release (inputFor "terminationFold") → terminationFold_inversion_claim (.flip .terminationShape) hash code commit decode release (inputFor "terminationFold")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem liveUpdate_inversion_antecedent : liveUpdate_inversion_premise .none hash code commit decode release (inputFor "liveUpdate") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem liveUpdate_inversion_positive : liveUpdate_inversion_claim .none hash code commit decode release (inputFor "liveUpdate") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem liveUpdate_inversion_mutant : ¬ (liveUpdate_inversion_premise (.flip .bookingSignature) hash code commit decode release (inputFor "liveUpdate") → liveUpdate_inversion_claim (.flip .bookingSignature) hash code commit decode release (inputFor "liveUpdate")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem approvalBurn_inversion_antecedent : approvalBurn_inversion_premise .none hash code commit decode release (inputFor "approvalBurn") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem approvalBurn_inversion_positive : approvalBurn_inversion_claim .none hash code commit decode release (inputFor "approvalBurn") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem approvalBurn_inversion_mutant : ¬ (approvalBurn_inversion_premise (.flip .inputCoverage) hash code commit decode release (inputFor "approvalBurn") → approvalBurn_inversion_claim (.flip .inputCoverage) hash code commit decode release (inputFor "approvalBurn")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem registration_lifecycle_antecedent : registration_lifecycle_premise .none hash code commit decode release (inputFor "ownerReclaim") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem registration_lifecycle_positive : registration_lifecycle_claim .none hash code commit decode release (inputFor "ownerReclaim") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem registration_lifecycle_mutant : ¬ (registration_lifecycle_premise (.flip .reclaimPhase) hash code commit decode release (inputFor "ownerReclaim") → registration_lifecycle_claim (.flip .reclaimPhase) hash code commit decode release (inputFor "ownerReclaim")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem termination_burn_antecedent : termination_burn_premise .none hash code commit decode release (inputFor "terminationFold") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem termination_burn_positive : termination_burn_claim .none hash code commit decode release (inputFor "terminationFold") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem termination_burn_mutant : ¬ (termination_burn_premise (.flip .terminationActiveBurn) hash code commit decode release (inputFor "terminationFold") → termination_burn_claim (.flip .terminationActiveBurn) hash code commit decode release (inputFor "terminationFold")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem booking_authority_and_parameters_antecedent : booking_authority_and_parameters_premise .none hash code commit decode release (inputFor "bookRegistration") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem booking_authority_and_parameters_positive : booking_authority_and_parameters_claim .none hash code commit decode release (inputFor "bookRegistration") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem booking_authority_and_parameters_mutant : ¬ (booking_authority_and_parameters_premise (.flip .bookingSignature) hash code commit decode release (inputFor "bookRegistration") → booking_authority_and_parameters_claim (.flip .bookingSignature) hash code commit decode release (inputFor "bookRegistration")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem treasury_at_booking_antecedent : treasury_at_booking_premise .none hash code commit decode release (inputFor "bookTermination") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem treasury_at_booking_positive : treasury_at_booking_claim .none hash code commit decode release (inputFor "bookTermination") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem treasury_at_booking_mutant : ¬ (treasury_at_booking_premise (.flip .moneyTreasury) hash code commit decode release (inputFor "bookTermination") → treasury_at_booking_claim (.flip .moneyTreasury) hash code commit decode release (inputFor "bookTermination")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem additive_payments_antecedent : additive_payments_premise .none hash code commit decode release (inputFor "expiredCleanup") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem additive_payments_positive : additive_payments_claim .none hash code commit decode release (inputFor "expiredCleanup") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem additive_payments_mutant : ¬ (additive_payments_premise (.flip .moneyOutputs) hash code commit decode release (inputFor "expiredCleanup") → additive_payments_claim (.flip .moneyOutputs) hash code commit decode release (inputFor "expiredCleanup")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem folder_protection_antecedent : folder_protection_premise .none hash code commit decode release (inputFor "ownerReclaim") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem folder_protection_positive : folder_protection_claim .none hash code commit decode release (inputFor "ownerReclaim") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem folder_protection_mutant : ¬ (folder_protection_premise (.flip .reclaimPhase) hash code commit decode release (inputFor "ownerReclaim") → folder_protection_claim (.flip .reclaimPhase) hash code commit decode release (inputFor "ownerReclaim")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem burning_grants_nothing_antecedent : burning_grants_nothing_premise .none hash code commit decode release (inputFor "approvalBurn") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem burning_grants_nothing_positive : burning_grants_nothing_claim .none hash code commit decode release (inputFor "approvalBurn") := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem burning_grants_nothing_mutant : ¬ (burning_grants_nothing_premise (.flip .inputCoverage) hash code commit decode release (inputFor "approvalBurn") → burning_grants_nothing_claim (.flip .inputCoverage) hash code commit decode release (inputFor "approvalBurn")) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_configurationShape_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_configurationShape_mutant : ¬ (applicationStep (.flip .configurationShape) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_configurationGenesis_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_configurationGenesis_mutant : ¬ (applicationStep (.flip .configurationGenesis) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_freshApproval_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_freshApproval_mutant : ¬ (applicationStep (.flip .freshApproval) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_inputCoverage_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_inputCoverage_mutant : ¬ (applicationStep (.flip .inputCoverage) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_birthCoverage_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_birthCoverage_mutant : ¬ (applicationStep (.flip .birthCoverage) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_moneyOutputs_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_moneyOutputs_mutant : ¬ (applicationStep (.flip .moneyOutputs) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_moneyTreasury_positive : applicationStep .none hash code decode release (exampleFor "configurationCreate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_moneyTreasury_mutant : ¬ (applicationStep (.flip .moneyTreasury) hash code decode release (exampleFor "configurationCreate") = true ↔ applicationStepConditions hash code decode release (exampleFor "configurationCreate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_configurationReference_positive : applicationStep .none hash code decode release (exampleFor "bookRegistration") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_configurationReference_mutant : ¬ (applicationStep (.flip .configurationReference) hash code decode release (exampleFor "bookRegistration") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookRegistration") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationShape_positive : applicationStep .none hash code decode release (exampleFor "bookRegistration") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationShape_mutant : ¬ (applicationStep (.flip .registrationShape) hash code decode release (exampleFor "bookRegistration") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookRegistration") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationControl_positive : applicationStep .none hash code decode release (exampleFor "bookRegistration") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationControl_mutant : ¬ (applicationStep (.flip .registrationControl) hash code decode release (exampleFor "bookRegistration") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookRegistration") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationClock_positive : applicationStep .none hash code decode release (exampleFor "bookRegistration") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationClock_mutant : ¬ (applicationStep (.flip .registrationClock) hash code decode release (exampleFor "bookRegistration") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookRegistration") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationFunding_positive : applicationStep .none hash code decode release (exampleFor "bookRegistration") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationFunding_mutant : ¬ (applicationStep (.flip .registrationFunding) hash code decode release (exampleFor "bookRegistration") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookRegistration") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_bookingSignature_positive : applicationStep .none hash code decode release (exampleFor "bookRegistration") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_bookingSignature_mutant : ¬ (applicationStep (.flip .bookingSignature) hash code decode release (exampleFor "bookRegistration") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookRegistration") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_terminationShape_positive : applicationStep .none hash code decode release (exampleFor "bookTermination") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_terminationShape_mutant : ¬ (applicationStep (.flip .terminationShape) hash code decode release (exampleFor "bookTermination") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookTermination") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_liveShape_positive : applicationStep .none hash code decode release (exampleFor "bookTermination") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_liveShape_mutant : ¬ (applicationStep (.flip .liveShape) hash code decode release (exampleFor "bookTermination") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookTermination") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_liveControl_positive : applicationStep .none hash code decode release (exampleFor "bookTermination") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_liveControl_mutant : ¬ (applicationStep (.flip .liveControl) hash code decode release (exampleFor "bookTermination") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookTermination") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_liveDeposit_positive : applicationStep .none hash code decode release (exampleFor "bookTermination") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_liveDeposit_mutant : ¬ (applicationStep (.flip .liveDeposit) hash code decode release (exampleFor "bookTermination") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookTermination") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_requestInput_positive : applicationStep .none hash code decode release (exampleFor "bookTermination") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_requestInput_mutant : ¬ (applicationStep (.flip .requestInput) hash code decode release (exampleFor "bookTermination") = true ↔ applicationStepConditions hash code decode release (exampleFor "bookTermination") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_approvalBurn_positive : applicationStep .none hash code decode release (exampleFor "registrationFold") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_approvalBurn_mutant : ¬ (applicationStep (.flip .approvalBurn) hash code decode release (exampleFor "registrationFold") = true ↔ applicationStepConditions hash code decode release (exampleFor "registrationFold") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_processingPhase_positive : applicationStep .none hash code decode release (exampleFor "registrationFold") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_processingPhase_mutant : ¬ (applicationStep (.flip .processingPhase) hash code decode release (exampleFor "registrationFold") = true ↔ applicationStepConditions hash code decode release (exampleFor "registrationFold") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationDelivery_positive : applicationStep .none hash code decode release (exampleFor "registrationFold") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_registrationDelivery_mutant : ¬ (applicationStep (.flip .registrationDelivery) hash code decode release (exampleFor "registrationFold") = true ↔ applicationStepConditions hash code decode release (exampleFor "registrationFold") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_reclaimPhase_positive : applicationStep .none hash code decode release (exampleFor "ownerReclaim") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_reclaimPhase_mutant : ¬ (applicationStep (.flip .reclaimPhase) hash code decode release (exampleFor "ownerReclaim") = true ↔ applicationStepConditions hash code decode release (exampleFor "ownerReclaim") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_cleanupPhase_positive : applicationStep .none hash code decode release (exampleFor "expiredCleanup") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_cleanupPhase_mutant : ¬ (applicationStep (.flip .cleanupPhase) hash code decode release (exampleFor "expiredCleanup") = true ↔ applicationStepConditions hash code decode release (exampleFor "expiredCleanup") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_terminationActiveBurn_positive : applicationStep .none hash code decode release (exampleFor "terminationFold") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_terminationActiveBurn_mutant : ¬ (applicationStep (.flip .terminationActiveBurn) hash code decode release (exampleFor "terminationFold") = true ↔ applicationStepConditions hash code decode release (exampleFor "terminationFold") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_terminationInvocation_positive : applicationStep .none hash code decode release (exampleFor "terminationFold") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_terminationInvocation_mutant : ¬ (applicationStep (.flip .terminationInvocation) hash code decode release (exampleFor "terminationFold") = true ↔ applicationStepConditions hash code decode release (exampleFor "terminationFold") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_updateControl_positive : applicationStep .none hash code decode release (exampleFor "liveUpdate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_updateControl_mutant : ¬ (applicationStep (.flip .updateControl) hash code decode release (exampleFor "liveUpdate") = true ↔ applicationStepConditions hash code decode release (exampleFor "liveUpdate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_updateAssets_positive : applicationStep .none hash code decode release (exampleFor "liveUpdate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_updateAssets_mutant : ¬ (applicationStep (.flip .updateAssets) hash code decode release (exampleFor "liveUpdate") = true ↔ applicationStepConditions hash code decode release (exampleFor "liveUpdate") = true) := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_updateDeposit_positive : applicationStep .none hash code decode release (exampleFor "liveUpdate") = true := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem guard_updateDeposit_mutant : ¬ (applicationStep (.flip .updateDeposit) hash code decode release (exampleFor "liveUpdate") = true ↔ applicationStepConditions hash code decode release (exampleFor "liveUpdate") = true) := by decide

/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem termination_encoding : FiniteEncoding (queryCode terminationInput.query) (publicDomain terminationInput.query) := by
  intro a ha b hb he
  change a ∈ [Preimage.state seed, .active registryId 8, .terminationApproval registryId 8] at ha
  change b ∈ [Preimage.state seed, .active registryId 8, .terminationApproval registryId 8] at hb
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl | rfl <;> rcases hb with rfl | rfl | rfl
  all_goals first | rfl | exact False.elim ((by decide : _ ≠ _) he)
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem termination_collision : FiniteCollisionFree (NoPin.lookupHash terminationInput.query.hashes) (queryCode terminationInput.query) (publicDomain terminationInput.query) := by
  intro a ha b hb he
  change a ∈ [Preimage.state seed, .active registryId 8, .terminationApproval registryId 8] at ha
  change b ∈ [Preimage.state seed, .active registryId 8, .terminationApproval registryId 8] at hb
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl | rfl <;> rcases hb with rfl | rfl | rfl
  all_goals first | rfl | exact False.elim ((by decide : _ ≠ _) he)
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem termination_public_inputs : PublicFoldPremises (NoPin.lookupHash terminationInput.query.hashes)
    (queryCode terminationInput.query) (queryCommit terminationInput.query)
    (queryDecode terminationInput.query) release NoPin.ApplicationRequests.Fixtures.registry [termination] funding := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide,
    by decide, by decide, by decide, by decide, by decide, ?_, ?_⟩
  · intro output member
    change output ∈ [NoPin.ApplicationRequests.Fixtures.registry.state, termination.output, funding.ordinaryInput] at member
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with rfl | rfl | rfl <;> decide
  · intro request member
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with rfl
    dsimp [NoPin.ApplicationRequests.Fixtures.termination]
    decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem no_stuck_termination_antecedent : no_stuck_termination_premise .none (NoPin.lookupHash terminationInput.query.hashes) (queryCode terminationInput.query) (queryCommit terminationInput.query) (queryDecode terminationInput.query) release terminationInput :=
  ⟨termination_public_inputs, by decide, by decide, termination_encoding, termination_collision,
    ⟨termination.output, registryId, 8, rfl⟩⟩
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem no_stuck_termination_positive : no_stuck_termination_claim .none (NoPin.lookupHash terminationInput.query.hashes) (queryCode terminationInput.query) (queryCommit terminationInput.query) (queryDecode terminationInput.query) release terminationInput := by decide
/-- Executed finite #741 hypothetical instance, not accepted law. -/
theorem no_stuck_termination_mutant : ¬ (no_stuck_termination_premise (.flip .terminationActiveBurn) (NoPin.lookupHash terminationInput.query.hashes) (queryCode terminationInput.query) (queryCommit terminationInput.query) (queryDecode terminationInput.query) release terminationInput →
    no_stuck_termination_claim (.flip .terminationActiveBurn) (NoPin.lookupHash terminationInput.query.hashes) (queryCode terminationInput.query) (queryCommit terminationInput.query) (queryDecode terminationInput.query) release terminationInput) := by
  intro claimed
  have failed : ¬ no_stuck_termination_claim (.flip .terminationActiveBurn) (NoPin.lookupHash terminationInput.query.hashes) (queryCode terminationInput.query) (queryCommit terminationInput.query) (queryDecode terminationInput.query) release terminationInput := by decide
  exact failed (claimed no_stuck_termination_antecedent)

/-- Executed finite #741 hypothesis instance, not accepted law. -/
theorem approval_burn_open_antecedent : approval_burn_open_premise .none hash code commit decode release (inputFor "approvalBurn") := by decide
/-- Executed finite #741 hypothesis instance, not accepted law. -/
theorem approval_burn_open_positive : approval_burn_open_claim .none hash code commit decode release (inputFor "approvalBurn") := by decide
/-- Executed finite #741 hypothesis instance, not accepted law. -/
theorem approval_burn_open_mutant : ¬ (approval_burn_open_premise (.flip .inputCoverage) hash code commit decode release (inputFor "approvalBurn") → approval_burn_open_claim (.flip .inputCoverage) hash code commit decode release (inputFor "approvalBurn")) := by decide

/-- Executed finite #741 hypothesis instance, not accepted law. -/
theorem configuration_immutable_antecedent : configuration_immutable_premise .none hash code commit decode release (inputFor "bookRegistration") := by decide
/-- Executed finite #741 hypothesis instance, not accepted law. -/
theorem configuration_immutable_positive : configuration_immutable_claim .none hash code commit decode release (inputFor "bookRegistration") := by decide
/-- Executed finite #741 hypothesis instance, not accepted law. -/
theorem configuration_immutable_mutant : ¬ (configuration_immutable_premise (.flip .configurationShape) hash code commit decode release (inputFor "bookRegistration") → configuration_immutable_claim (.flip .configurationShape) hash code commit decode release (inputFor "bookRegistration")) := by decide

/-- Hypothesis boundary under #741, not accepted law; a straddling early reclaim. -/
def earlyReclaim : Input :=
  let q := inputFor "ownerReclaim"
  {q with observation := {q.observation with interval := ⟨19, 21⟩}}
/-- Executed early-window refusal against independent effects, not accepted law. -/
theorem early_reclaim_lifecycle : registration_lifecycle_claim .none hash code commit decode release earlyReclaim := by decide
/-- Hypothesis boundary under #741, not accepted law; surplus in a committed exact holding. -/
def overdeposit : Input :=
  let q := inputFor "registrationFold"
  let outputs := q.observation.outputs.mapIdx fun index output =>
    if index == 1 then {output with lovelace := registrationData.deposit + 1} else output
  {q with observation := {q.observation with outputs}}
/-- Executed exact-deposit refusal against independent effects, not accepted law. -/
theorem overdeposit_lifecycle : registration_lifecycle_claim .none hash code commit decode release overdeposit := by decide

end NoPin.ApplicationRequests.RefundLifecycle.Evidence
