import Singular.Lemmas.RetractionWitnessAdmission
import Singular.Statements.Booking

/-! The finite witness passes every retraction admission check. -/

namespace Singular

theorem retractionWitness_accepted (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (nonempty : interval.valid)
    (starts : booking.request.submittedAt + world.registry.config.processTime ≤ interval.lower)
    (ends : interval.upper ≤ booking.request.submittedAt + world.registry.config.processTime +
      world.registry.config.retractTime)
    (signers : List Nat) (signed : booking.request.refundAddress ∈ signers)
    (funding fee : Nat) (funded : fee ≤ funding) :
    retractionAccepted world (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) =
      .ok (retractionEffect world (retractionWitnessTransaction world booking interval signers funding fee)) := by
  have contents := (Statements.booked_request_has_exact_contents world reachable booking pending).1
  have bare : booking.request.contents.otherAssets = [] := by
    simp only [exactContents, registrationContentsShape, Bool.and_eq_true, decide_eq_true_eq] at contents
    exact contents.1.1.1.2.2.2
  obtain ⟨trieTag, application, applicationTag, _⟩ :=
    Statements.booked_request_tags_commit_to_own_fields world reachable booking pending
  have burn : requestTagsBurned (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) = true := by
    simp only [requestTagsBurned, retractionWitness_spent world reachable booking pending]
    simp [retractionWitnessTransaction, registrationWitnessOutput, foldWitnessOrdinary,
      trieTag, applicationTag, exactBurns]
  have supply : rejectionSupplyUnchanged (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) = true := by
    simp only [rejectionSupplyUnchanged, retractionWitness_spent world reachable booking pending]
    simp [retractionWitnessTransaction, registrationWitnessOutput, foldWitnessOrdinary, bare]
  have refusal : retractionRefusal world (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) = none := by
    simp only [retractionRefusal,
      retractionWitness_inputs world reachable booking pending,
      retractionWitness_observation world reachable booking,
      retractionWitness_request world reachable booking pending,
      retractionFundingRefusal, retractionFundingLovelace,
      retractionWitness_funding world reachable booking pending,
      retractionWitness_spent world reachable booking pending,
      burn, supply, retractionWitness_balance world reachable booking pending interval signers funding fee funded]
    simp [retractionWitnessTransaction, foldWitnessOrdinary, registrationWitnessOutput,
      foldOrdinaryLovelace, foldOrdinary, foldBareValue, bare, signed, List.eraseDups_cons,
      nonempty, Nat.not_lt.mpr starts, Nat.not_lt.mpr ends, Nat.not_lt.mpr funded,
      refundRefusal, refundObligations, refundOwed, refundAmount, refundPaid]
  simp [retractionAccepted, refusal]

end Singular
