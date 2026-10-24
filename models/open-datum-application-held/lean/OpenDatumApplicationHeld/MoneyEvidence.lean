import OpenDatumApplicationHeld.MoneyStatements
import OpenDatumApplicationHeld.MoneyFixtures


set_option maxRecDepth 8192
set_option maxHeartbeats 4000000
namespace OpenDatumApplicationHeld.Money.Evidence
open Singular Lean SingularApplicationHeld OpenDatumApplicationHeld.Fixtures


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


theorem create_journey_positive : NewClaim .none hash code commit decode release .create (Fixtures.input .create) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · exact ⟨Singular.Reachable.initial _, by decide⟩
  · trivial


theorem create_journey_mutant : ¬ (NewPremise hash code commit decode release .create (Fixtures.input .create) →
    NewClaim (.application .configurationShape) hash code commit decode release .create (Fixtures.input .create)) := by
  intro result
  have bad := (result create_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .configurationShape) hash code decode release (Fixtures.input .create).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


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


theorem registration_booking_journey_positive : NewClaim .none hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial


theorem registration_booking_journey_mutant : ¬ (NewPremise hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking) →
    NewClaim (.application .bookingSignature) hash code commit decode release .registrationBooking (Fixtures.input .registrationBooking)) := by
  intro result
  have bad := (result registration_booking_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .bookingSignature) hash code decode release (Fixtures.input .registrationBooking).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


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


theorem update_journey_positive : NewClaim .none hash code commit decode release .update (Fixtures.input .update) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial


theorem update_journey_mutant : ¬ (NewPremise hash code commit decode release .update (Fixtures.input .update) →
    NewClaim (.application .updateControl) hash code commit decode release .update (Fixtures.input .update)) := by
  intro result
  have bad := (result update_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .updateControl) hash code decode release (Fixtures.input .update).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


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


theorem termination_booking_journey_positive : NewClaim .none hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial


theorem termination_booking_journey_mutant : ¬ (NewPremise hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking) →
    NewClaim (.application .moneyTreasury) hash code commit decode release .terminationBooking (Fixtures.input .terminationBooking)) := by
  intro result
  have bad := (result termination_booking_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .moneyTreasury) hash code decode release (Fixtures.input .terminationBooking).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


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


theorem termination_fold_journey_positive : NewClaim .none hash code commit decode release .terminationFold (Fixtures.input .terminationFold) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · decide
  · trivial
  · trivial


theorem termination_fold_journey_mutant : ¬ (NewPremise hash code commit decode release .terminationFold (Fixtures.input .terminationFold) →
    NewClaim (.application .terminationActiveBurn) hash code commit decode release .terminationFold (Fixtures.input .terminationFold)) := by
  intro result
  have bad := (result termination_fold_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .terminationActiveBurn) hash code decode release (Fixtures.input .terminationFold).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


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


theorem reclaim_journey_positive : NewClaim .none hash code commit decode release .reclaim (Fixtures.input .reclaim) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · decide


theorem reclaim_journey_mutant : ¬ (NewPremise hash code commit decode release .reclaim (Fixtures.input .reclaim) →
    NewClaim (.application .moneyOutputs) hash code commit decode release .reclaim (Fixtures.input .reclaim)) := by
  intro result
  have bad := (result reclaim_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .moneyOutputs) hash code decode release (Fixtures.input .reclaim).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


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


theorem cleanup_journey_positive : NewClaim .none hash code commit decode release .cleanup (Fixtures.input .cleanup) := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_, ?_, ?_⟩
  · intro party; cases party <;> decide
  · trivial
  · trivial
  · trivial


theorem cleanup_journey_mutant : ¬ (NewPremise hash code commit decode release .cleanup (Fixtures.input .cleanup) →
    NewClaim (.application .moneyOutputs) hash code commit decode release .cleanup (Fixtures.input .cleanup)) := by
  intro result
  have bad := (result cleanup_journey_antecedent).1
  have refused : RefundApplication.applicationStep (.flip .moneyOutputs) hash code decode release (Fixtures.input .cleanup).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible


theorem accepted_economic_allocations_antecedent : OldPremise (Fixtures.input .registrationFold) := by
  refine ⟨by decide, ?_, ?_⟩
  · simp [Fixtures.input, Fixtures.baseline, Fixtures.oldRegistration, Fixtures.configuration, registrationBookingRefusal, registrationContentsShape, registrationApplicationTagValid, registrationDeclaredLovelace, RegistrationRequest.operation, RegistrationRequest.trieReadyTag, registrationData, registration, reduceBEq, Interval.valid, Interval.width]
  · simp [Fixtures.input, Fixtures.baseline, Fixtures.oldTermination, Fixtures.configuration, terminationExactContents, terminationContentsShape, terminationDeclaredLovelace, Singular.TerminationRequest.trieReadyTag, Singular.TerminationRequest.operation, termination, reduceBEq]


theorem accepted_economic_allocations_positive : OldClaim .none (Fixtures.input .registrationFold) := by decide


theorem accepted_economic_allocations_mutant : ¬ (OldPremise (Fixtures.input .registrationFold) → OldClaim (.allocation .oldRegistrationTip) (Fixtures.input .registrationFold)) := by
  intro result
  have bad := (result accepted_economic_allocations_antecedent).2.1
  have different : ¬ ((oldAllocation (.allocation .oldRegistrationTip) .registrationFold (Fixtures.input .registrationFold).baseline).folder = (Fixtures.input .registrationFold).baseline.registration.request.declaredTip) := by decide
  exact different bad


theorem journey_allocations_antecedent : Correspondence (Fixtures.input .registrationFold) := by decide


theorem journey_allocations_positive : AllDifferences .none .registrationFold (Fixtures.input .registrationFold) := by
  intro party; cases party <;> decide


theorem journey_allocations_mutant : ¬ (Correspondence (Fixtures.input .registrationFold) → AllDifferences (.allocation .registrationResidual) .registrationFold (Fixtures.input .registrationFold)) := by
  intro result
  have bad := result journey_allocations_antecedent .folder
  exact (by decide : ¬ Difference (.allocation .registrationResidual) .registrationFold .folder (Fixtures.input .registrationFold)) bad


theorem accepted_update_authority_antecedent : OldUpdatePremise Fixtures.oldApplicationWorld 0 [] := by
  exact ⟨Fixtures.oldLive, by rfl, by decide⟩


theorem accepted_update_authority_positive : OldUpdateClaim .none Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] [] := by decide


theorem accepted_update_authority_mutant : ¬ (OldUpdatePremise Fixtures.oldApplicationWorld 0 [] → OldUpdateClaim (.allocation .oldUpdateSigner) Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] []) := by
  intro result
  have bad := result accepted_update_authority_antecedent
  exact (by decide : ¬ OldUpdateClaim (.allocation .oldUpdateSigner) Fixtures.oldApplicationWorld 0 [Fixtures.oldSuccessor] []) bad



end OpenDatumApplicationHeld.Money.Evidence
