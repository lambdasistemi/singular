import Singular.Lemmas.RetractionFunding

/-! Payments elsewhere are bounded by ordinary funds after the ledger fee. -/

namespace Singular

theorem retraction_output_observations {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : retractionAccepted world u tx = .ok after) :
    tx.outputs.map (·.output) = tx.transaction.outputs := by
  have observations := (RefundProof.retraction_checks accepted).2.1
  unfold economicObservationRefusal at observations
  repeat (split at observations <;> try contradiction)
  all_goals simp_all

theorem retraction_other_payments {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} {request : RegistrationRequest}
    (accepted : retractionAccepted world u tx = .ok after)
    (selected : retractionRequest world tx = .ok request) :
    ((tx.outputs.filter fun output => output.output.address != some request.refundAddress).map
      (·.output.lovelace)).sum ≤ retractionFundingLovelace u tx request - tx.transaction.fee := by
  obtain ⟨_, _, found, foundAt, _, _, _, _, refunds⟩ := RefundProof.retraction_checks accepted
  have equal : found = request := by rw [selected] at foundAt; exact Except.ok.inj foundAt.symm
  subst found
  have floor : request.contents.lovelace ≤ refundPaid tx request.refundAddress := by
    simpa [refundOwed, refundAmount] using RefundProof.refund_floor refunds request.refundAddress
  obtain ⟨found, foundAt, _, donation, fee, balance, _⟩ := retraction_funding_checks accepted
  have equal : found = request := by rw [selected] at foundAt; exact Except.ok.inj foundAt.symm
  subst found
  have conserved : outputLovelace (spentOutputs u.ledger tx.transaction) =
      outputLovelace tx.transaction.outputs + tx.transaction.donation + tx.transaction.fee := by
    simp only [balanced, Bool.and_eq_true, beq_iff_eq] at balance
    exact balance.1.1
  rw [retraction_input_lovelace accepted selected,
    ← retraction_output_observations accepted, donation] at conserved
  have partition := sum_filter_parts tx.outputs
    (fun output => output.output.address == some request.refundAddress) (·.output.lovelace)
  simp only [outputLovelace, List.map_map, Function.comp_def, Nat.add_zero] at conserved
  change (tx.outputs.map (·.output.lovelace)).sum = refundPaid tx request.refundAddress +
    ((tx.outputs.filter fun output => output.output.address != some request.refundAddress).map
      (·.output.lovelace)).sum at partition
  omega

theorem retraction_outputs_ordinary {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : retractionAccepted world u tx = .ok after) :
    ∀ output ∈ tx.outputs, foldOrdinary output = true ∧ foldBareValue output = true := by
  obtain ⟨_, _, _, _, _, _, burned, supply, _⟩ := RefundProof.retraction_checks accepted
  simp only [requestTagsBurned, Bool.and_eq_true] at burned
  simp only [rejectionSupplyUnchanged, Bool.and_eq_true] at supply
  intro output member
  have tags := List.all_eq_true.mp burned.2 output member
  have assets := List.all_eq_true.mp supply.2 output member
  simp_all [foldOrdinary, foldBareValue]

end Singular
