import NoPin.ApplicationRequests.MoneyStatements
import NoPin.ApplicationRequests.MoneyFixtures

/-! Hypothetical finite evidence only, not accepted law or general proofs. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 4000000
namespace NoPin.ApplicationRequests.Money.Evidence
open Singular Lean NoPin.ApplicationRequests.Fixtures

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem create_journey_antecedent : NewPremise hash code commit decode release .create (Fixtures.input .create) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · trivial
  · refine ⟨by decide, ?_⟩
    intro output member hasConfiguration
    rcases List.mem_cons.mp member with rfl | member
    · rcases hasConfiguration with ⟨p, impossible⟩; cases impossible
    · have equal := List.mem_singleton.mp member
      subst output
      rfl

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem create_journey_positive : NewClaim .none hash code commit decode release .create (Fixtures.input .create) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · exact ⟨Singular.Reachable.initial _, by decide⟩
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem create_journey_mutant : ¬ (NewPremise hash code commit decode release .create (Fixtures.input .create) →
    NewClaim (.application .configurationShape) hash code commit decode release .create (Fixtures.input .create)) := by
  intro result
  have bad := (result create_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .configurationShape) hash code decode release (Fixtures.input .create).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem registration_booking_journey_antecedent : NewPremise hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem registration_booking_journey_positive : NewClaim .none hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem registration_booking_journey_mutant : ¬ (NewPremise hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking) →
    NewClaim (.application .bookingSignature) hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking)) := by
  intro result
  have bad := (result registration_booking_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .bookingSignature) hash code decode release (Fixtures.input .registrationBooking).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem registration_fold_journey_antecedent : NewPremise hash code commit decode release .registrationFold (Fixtures.input .registrationFold) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · decide
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem registration_fold_journey_positive : NewClaim .none hash code commit decode release .registrationFold (Fixtures.input .registrationFold) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem registration_fold_journey_mutant : ¬ (NewPremise hash code commit decode release .registrationFold (Fixtures.input .registrationFold) →
    NewClaim (.application .registrationDelivery) hash code commit decode release .registrationFold (Fixtures.input .registrationFold)) := by
  intro result
  have bad := (result registration_fold_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .registrationDelivery) hash code decode release (Fixtures.input .registrationFold).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem update_journey_antecedent : NewPremise hash code commit decode release .update (Fixtures.input .update) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem update_journey_positive : NewClaim .none hash code commit decode release .update (Fixtures.input .update) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem update_journey_mutant : ¬ (NewPremise hash code commit decode release .update (Fixtures.input .update) →
    NewClaim (.application .updateControl) hash code commit decode release .update (Fixtures.input .update)) := by
  intro result
  have bad := (result update_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .updateControl) hash code decode release (Fixtures.input .update).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem termination_booking_journey_antecedent : NewPremise hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem termination_booking_journey_positive : NewClaim .none hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem termination_booking_journey_mutant : ¬ (NewPremise hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking) →
    NewClaim (.application .moneyTreasury) hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking)) := by
  intro result
  have bad := (result termination_booking_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .moneyTreasury) hash code decode release (Fixtures.input .terminationBooking).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem termination_fold_journey_antecedent : NewPremise hash code commit decode release .terminationFold (Fixtures.input .terminationFold) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · decide
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem termination_fold_journey_positive : NewClaim .none hash code commit decode release .terminationFold (Fixtures.input .terminationFold) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem termination_fold_journey_mutant : ¬ (NewPremise hash code commit decode release .terminationFold (Fixtures.input .terminationFold) →
    NewClaim (.application .terminationActiveBurn) hash code commit decode release .terminationFold (Fixtures.input .terminationFold)) := by
  intro result
  have bad := (result termination_fold_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .terminationActiveBurn) hash code decode release (Fixtures.input .terminationFold).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem reclaim_journey_antecedent : NewPremise hash code commit decode release .reclaim (Fixtures.input .reclaim) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem reclaim_journey_positive : NewClaim .none hash code commit decode release .reclaim (Fixtures.input .reclaim) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · decide

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem reclaim_journey_mutant : ¬ (NewPremise hash code commit decode release .reclaim (Fixtures.input .reclaim) →
    NewClaim (.application .moneyOutputs) hash code commit decode release .reclaim (Fixtures.input .reclaim)) := by
  intro result
  have bad := (result reclaim_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .moneyOutputs) hash code decode release (Fixtures.input .reclaim).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; complete independent antecedent. -/
theorem cleanup_journey_antecedent : NewPremise hash code commit decode release .cleanup (Fixtures.input .cleanup) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · decide
  · rfl
  · decide
  · decide
  · decide
  · decide
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; literal observed effects and ruled equations. -/
theorem cleanup_journey_positive : NewClaim .none hash code commit decode release .cleanup (Fixtures.input .cleanup) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial

/-- Hypothesis under #741, not accepted law; exactly one application guard changes. -/
theorem cleanup_journey_mutant : ¬ (NewPremise hash code commit decode release .cleanup (Fixtures.input .cleanup) →
    NewClaim (.application .moneyOutputs) hash code commit decode release .cleanup (Fixtures.input .cleanup)) := by
  intro result
  have bad := (result cleanup_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .moneyOutputs) hash code decode release (Fixtures.input .cleanup).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible

/-- Hypothesis under #741, not accepted law; accepted booking predicates execute. -/
theorem accepted_economic_allocations_antecedent : OldPremise (Fixtures.input .registrationFold) := by
  refine ⟨by decide, ?_, ?_⟩
  · simp [Fixtures.input, Fixtures.baseline, Fixtures.oldRegistration, Fixtures.configuration, registrationBookingRefusal, registrationContentsShape, registrationApplicationTagValid, registrationDeclaredLovelace, RegistrationRequest.operation, RegistrationRequest.trieReadyTag, registrationData, registration, reduceBEq, Interval.valid, Interval.width]
  · simp [Fixtures.input, Fixtures.baseline, Fixtures.oldTermination, Fixtures.configuration, terminationExactContents, terminationContentsShape, terminationDeclaredLovelace, Singular.TerminationRequest.trieReadyTag, Singular.TerminationRequest.operation, termination, reduceBEq]

/-- Hypothesis under #741, not accepted law; old allocations execute independently of the new ones. -/
theorem accepted_economic_allocations_positive : OldClaim .none (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; one old allocation site changes. -/
theorem accepted_economic_allocations_mutant : ¬ (OldPremise (Fixtures.input .registrationFold) → OldClaim (.allocation .oldRegistrationTip) (Fixtures.input .registrationFold)) := by
  intro result
  have bad := (result accepted_economic_allocations_antecedent).2.1
  have different : ¬ ((oldAllocation (.allocation .oldRegistrationTip) .registrationFold (Fixtures.input .registrationFold).baseline).folder = (Fixtures.input .registrationFold).baseline.registration.request.declaredTip) := by decide
  exact different bad

/-- Hypothesis under #741, not accepted law; complete nontrivial correspondence. -/
theorem journey_allocations_antecedent : Correspondence (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; the chosen full party grid executes. -/
theorem journey_allocations_positive : AllDifferences .none .registrationFold (Fixtures.input .registrationFold) := by
  intro party; cases party <;> decide

/-- Hypothesis under #741, not accepted law; one residual-amount site is falsified. -/
theorem journey_allocations_mutant : ¬ (Correspondence (Fixtures.input .registrationFold) → AllDifferences (.allocation .registrationResidual) .registrationFold (Fixtures.input .registrationFold)) := by
  intro result
  have bad := result journey_allocations_antecedent .folder
  exact (by decide : ¬ Difference (.allocation .registrationResidual) .registrationFold .folder (Fixtures.input .registrationFold)) bad

/-- Hypothesis under #741, not accepted law; actual old source and missing authority. -/
theorem accepted_update_authority_antecedent : OldUpdatePremise Fixtures.oldApplicationWorld 0 [] := by
  exact ⟨Fixtures.oldLive, by rfl, by decide⟩

/-- Hypothesis under #741, not accepted law; the accepted consumer refuses the unsigned update. -/
theorem accepted_update_authority_positive : OldUpdateClaim .none Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] [] := by decide

/-- Hypothesis under #741, not accepted law; one old consumer authority guard changes. -/
theorem accepted_update_authority_mutant : ¬ (OldUpdatePremise Fixtures.oldApplicationWorld 0 [] → OldUpdateClaim (.allocation .oldUpdateSigner) Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] []) := by
  intro result
  have bad := result accepted_update_authority_antecedent
  exact (by decide : ¬ OldUpdateClaim (.allocation .oldUpdateSigner) Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] []) bad

/-- Hypothesis under #741, not accepted law; all cells of the finite comparison grid execute. -/
theorem complete_grid : ∀ journey party, Difference .none journey party (Fixtures.input journey) := by
  intro journey; cases journey <;> intro party <;> cases party <;> decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_oldRegistrationTip_positive : Difference .none .registrationFold .folder (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_oldRegistrationTip_mutant : ¬ Difference (.allocation .oldRegistrationTip) .registrationFold .folder (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_oldRegistrationCarrier_positive : Difference .none .registrationFold .holding (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_oldRegistrationCarrier_mutant : ¬ Difference (.allocation .oldRegistrationCarrier) .registrationFold .holding (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_registrationResidual_positive : Difference .none .registrationFold .folder (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_registrationResidual_mutant : ¬ Difference (.allocation .registrationResidual) .registrationFold .folder (Fixtures.input .registrationFold) := by decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_terminationResidual_positive : Difference .none .terminationFold .folder (Fixtures.input .terminationFold) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_terminationResidual_mutant : ¬ Difference (.allocation .terminationResidual) .terminationFold .folder (Fixtures.input .terminationFold) := by decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_bookingTreasury_positive : Difference .none .terminationBooking .treasury (Fixtures.input .terminationBooking) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_bookingTreasury_mutant : ¬ Difference (.allocation .bookingTreasury) .terminationBooking .treasury (Fixtures.input .terminationBooking) := by decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_cleanupRefund_positive : Difference .none .cleanup .refund (Fixtures.input .cleanup) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_cleanupRefund_mutant : ¬ Difference (.allocation .cleanupRefund) .cleanup .refund (Fixtures.input .cleanup) := by decide

/-- Hypothesis under #741, not accepted law; this single amount site is exercised. -/
theorem site_oldRefund_positive : Difference .none .reclaim .refund (Fixtures.input .reclaim) := by decide

/-- Hypothesis under #741, not accepted law; this one-site amount perturbation is detected. -/
theorem site_oldRefund_mutant : ¬ Difference (.allocation .oldRefund) .reclaim .refund (Fixtures.input .reclaim) := by decide

/-- Hypothesis under #741, not accepted law; source-derived old authority site has a positive refusal. -/
theorem site_oldUpdateSigner_positive : OldUpdateClaim .none Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] [] := accepted_update_authority_positive

/-- Hypothesis under #741, not accepted law; the old authority mutant permits an unsigned payload change. -/
theorem site_oldUpdateSigner_mutant : ¬ OldUpdateClaim (.allocation .oldUpdateSigner) Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] [] := by decide

end NoPin.ApplicationRequests.Money.Evidence
