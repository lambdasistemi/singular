import Singular.Statements.Refunds
import Singular.Lemmas.RetractionPayments
import Singular.Lemmas.RetractionWitnessAccepted

/-! Economic retraction payments and availability over the observed model. -/

namespace Singular.Statements

/-- Every accepted retraction returns the request's whole held value, pays its
fee from observed ordinary funding, balances and leaves the treasury unchanged.
Ordinary funding and change are lovelace only, as in the fold. Value sent to
another address is at most ordinary funding left after the fee: this model
cannot distinguish such change from a payment to a third party. No request tip
or cost can fund that payment. This concerns arbitrary accepted transactions
in reachable worlds, not a wallet builder or ledger acceptance. -/
theorem retraction_pays_only_the_refund_and_the_fee (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : retractionAccepted world u tx = .ok after) :
    ∃ booking ∈ world.pending,
      retractionRequest world tx = .ok booking.request ∧
      booking.request.contents.lovelace = booking.request.registrationCost +
        booking.request.declaredTip + booking.request.carrierAda ∧
      booking.request.contents.lovelace ≤ refundPaid tx booking.request.refundAddress ∧
      tx.transaction.donation = 0 ∧ after.treasury = world.treasury ∧
      tx.transaction.fee ≤ retractionFundingLovelace u tx booking.request ∧
      balanced u.ledger tx.transaction = true ∧
      (∀ output ∈ retractionFunding u tx booking.request,
        foldOrdinary output = true ∧ foldBareValue output = true ∧
        output.output.role ≠ .state ∧ output.output.role ≠ .request ∧ output.request = none) ∧
      (∀ output ∈ tx.outputs, foldOrdinary output = true ∧ foldBareValue output = true) ∧
      ((tx.outputs.filter fun output => output.output.address != some booking.request.refundAddress).map
        (·.output.lovelace)).sum ≤ retractionFundingLovelace u tx booking.request - tx.transaction.fee := by
  obtain ⟨request, selected, funding, donation, fee, balance, _, bare⟩ := retraction_funding_checks accepted
  obtain ⟨booking, pending, same, _⟩ := RefundProof.retraction_request selected
  subst request
  obtain ⟨_, _, found, foundAt, _, _, _, _, refunds⟩ := RefundProof.retraction_checks accepted
  have equal : found = booking.request := by rw [selected] at foundAt; exact Except.ok.inj foundAt.symm
  subst found
  refine ⟨booking, pending, selected, RefundProof.allocations reachable ⟨booking, pending, rfl⟩,
    ?_, donation, ?_, fee, balance, ?_, retraction_outputs_ordinary accepted,
    retraction_other_payments accepted selected⟩
  · simpa [refundOwed, refundAmount] using RefundProof.refund_floor refunds booking.request.refundAddress
  · rw [retractionAccepted_effect accepted]; rfl
  · intro output member
    have ordinary := retraction_funding_ordinary funding output member
    have spent : output ∈ economicSpent u tx := by
      obtain ⟨entry, present, rfl⟩ := List.mem_map.mp member
      have conditions := List.mem_filter.mp present
      exact List.mem_map.mpr ⟨entry,
        List.mem_filter.mpr ⟨conditions.1, (Bool.and_eq_true_iff.mp conditions.2).1⟩, rfl⟩
    exact ⟨ordinary.1, List.all_eq_true.mp bare output spent, ordinary.2⟩

/-- A pending registration can be retracted throughout an explicitly chosen
nonempty interval inside its reclaim window when its refund address signs and
ordinary lovelace funding covers the chosen fee. A coherent unspent set and a
balanced accepted transaction are constructed from that reachable world. The
funding is lovelace only. This is model existence, not available wallet funds,
a builder, a ledger fee minimum, inclusion or acceptance by another script. -/
theorem pending_registration_can_be_retracted (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (nonempty : interval.valid)
    (starts : booking.request.submittedAt + world.registry.config.processTime ≤ interval.lower)
    (ends : interval.upper ≤ booking.request.submittedAt + world.registry.config.processTime +
      world.registry.config.retractTime)
    (signers : List Nat) (signed : booking.request.refundAddress ∈ signers)
    (funding fee : Nat) (funded : fee ≤ funding) :
    ∃ unspent : EconomicUtxo, ∃ transaction : EconomicTransaction, ∃ after : World,
      observesWorld world unspent = true ∧
      transaction.transaction.validity = some interval ∧ transaction.transaction.signers = signers ∧
      transaction.transaction.fee = fee ∧
      retractionRequest world transaction = .ok booking.request ∧
      retractionFundingLovelace unspent transaction booking.request = funding ∧
      booking.request.contents.lovelace ≤ refundPaid transaction booking.request.refundAddress ∧
      retractionAccepted world unspent transaction = .ok after ∧
      balanced unspent.ledger transaction.transaction = true ∧ WorldReachable after ∧
      booking ∉ after.pending := by
  let unspent := terminationWitnessUnspent world funding
  let transaction := retractionWitnessTransaction world booking interval signers funding fee
  let after := retractionEffect world transaction
  have accepted : retractionAccepted world unspent transaction = .ok after :=
    retractionWitness_accepted world reachable booking pending interval nonempty starts ends
      signers signed funding fee funded
  refine ⟨unspent, transaction, after, terminationWitnessUnspent_observes world reachable funding,
    rfl, rfl, rfl, retractionWitness_request world reachable booking pending interval signers funding fee,
    ?_, ?_, accepted, retractionWitness_balance world reachable booking pending interval signers funding fee funded,
    WorldReachable.retraction reachable unspent transaction accepted, ?_⟩
  · simp [unspent, transaction, retractionFundingLovelace,
      retractionWitness_funding world reachable booking pending,
      foldOrdinaryLovelace, foldOrdinary, foldWitnessOrdinary]
  · simp [transaction, retractionWitnessTransaction, refundPaid, foldWitnessOrdinary]
  · simp [after, retractionEffect, transaction, retractionWitnessTransaction,
      retractionWitnessInputs_contains]

end Singular.Statements
