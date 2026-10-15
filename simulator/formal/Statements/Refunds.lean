import Singular.Lemmas.Refunds

/-! Public refund floors over accepted transactions in reachable worlds. -/

namespace Singular.Statements

open RefundProof

/-- Every distinct rejected request contributes its held lovelace minus its
declared tip to its own address's floor. The lookup accounts for every member;
reachable booking contents include cost and carrier, not just a typed amount. -/
theorem rejection_refund_floor (world after : World) (reachable : WorldReachable world)
    (u : EconomicUtxo) (r : Rejection) (accepted : rejectionAccepted world u r = .ok after) :
    (r.members.map Prod.fst).Nodup ∧
    (rejectedRequests world r.members).map (·.reference) = r.members.map Prod.fst ∧
    (∀ request ∈ rejectedRequests world r.members,
      request.contents.lovelace = request.registrationCost + request.declaredTip + request.carrierAda) ∧
    ∀ address, ((rejectedRequests world r.members |>.filter fun q => q.refundAddress == address).map
      fun q => q.contents.lovelace - q.declaredTip).sum ≤ refundPaid r.transaction address := by
  refine ⟨(rejectionInputs_facts (rejectionAccepted_checks accepted).1).2.2.1,
    selected_members accepted, ?_, ?_⟩
  · intro request member
    exact allocations reachable (selected_pending member)
  · exact refund_floor (rejection_refunds accepted)

/-- A retraction has one pending registration input, its owner's signature,
a whole reclaim interval, no state spend or read, both tags burned, all held
lovelace returned at its address, and that request absent from the new pool.
The return is a floor on actual received value, with no processor-take claim. -/
theorem retraction_refund_floor (world after : World) (reachable : WorldReachable world)
    (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : retractionAccepted world u tx = .ok after) :
    ∃ booking ∈ world.pending,
      tx.transaction.inputs.map (·.ref) = [some booking.request.reference] ∧
      tx.transaction.signers.contains booking.request.refundAddress = true ∧
      (∃ interval, tx.transaction.validity = some interval ∧ interval.valid ∧
        booking.request.submittedAt + world.registry.config.processTime ≤ interval.lower ∧
        interval.upper ≤ booking.request.submittedAt + world.registry.config.processTime +
          world.registry.config.retractTime) ∧
      (spentOutputs u.ledger tx.transaction).any
        (fun o => o.stateTokens > 0 || o.role == .state) = false ∧
      (u.filter fun p => inputsContainReference tx.transaction.referenceInputs p.1).any
        (fun p => p.2.output.stateTokens > 0 || p.2.output.role == .state) = false ∧
      requestTagsBurned u tx = true ∧
      booking.request.contents.lovelace = booking.request.registrationCost +
        booking.request.declaredTip + booking.request.carrierAda ∧
      booking.request.contents.lovelace ≤ refundPaid tx booking.request.refundAddress ∧
      (∀ b ∈ after.pending, b.request.reference ≠ booking.request.reference) := by
  obtain ⟨inputs, observation, request, found, signed, interval, burned, supply, refunds⟩ :=
    retraction_checks accepted
  obtain ⟨booking, pending, same, consumed⟩ := retraction_request found
  subst request
  have noState := retraction_no_state inputs
  refine ⟨booking, pending, consumed, signed, interval, noState.1, noState.2, burned,
    allocations reachable ⟨booking, pending, rfl⟩, ?_, ?_⟩
  · simpa [refundOwed, refundAmount] using refund_floor refunds booking.request.refundAddress
  · intro b remaining equal
    rw [retractionAccepted_effect accepted] at remaining
    have unspent := (List.mem_filter.mp remaining).2
    have spent : inputsContainReference tx.transaction.inputs booking.request.reference = true := by
      have member : some booking.request.reference ∈ tx.transaction.inputs.map (·.ref) := by
        simp [consumed]
      obtain ⟨input, present, ref⟩ := List.mem_map.mp member
      apply List.any_eq_true.mpr
      exact ⟨input, present, by simp [ref]⟩
    simp [equal, spent] at unspent

/-- Registration cost is inside the aggregate returned on rejection and the
whole amount returned on retraction. No successful fold is covered here. -/
theorem registration_cost_returned_on_exit (world : World) (reachable : WorldReachable world) :
    (∀ (after : World) (u : EconomicUtxo) (r : Rejection),
      rejectionAccepted world u r = .ok after → ∀ address,
      ((rejectedRequests world r.members |>.filter fun q => q.refundAddress == address).map
        (·.registrationCost)).sum ≤ refundPaid r.transaction address) ∧
    (∀ (after : World) (u : EconomicUtxo) (tx : EconomicTransaction),
      retractionAccepted world u tx = .ok after → ∃ booking ∈ world.pending,
      tx.transaction.inputs.map (·.ref) = [some booking.request.reference] ∧
      booking.request.registrationCost ≤ refundPaid tx booking.request.refundAddress) := by
  constructor
  · intro after u r accepted address
    exact Nat.le_trans (costs_le_owed reachable _ false address (fun _ h => selected_pending h))
      (refund_floor (rejection_refunds accepted) address)
  · intro after u tx accepted
    obtain ⟨b, pending, consumed, _, _, _, _, _, amount, paid, _⟩ :=
      retraction_refund_floor world after reachable u tx accepted
    exact ⟨b, pending, consumed, by omega⟩

/-- One obligation per address is the exact sum of its distinct requests;
the judgement checks that sum against actual outputs at that address. Each
output's own address selects it once. Payments for another purpose at the same
address count too: this model has no separate output-purpose observation. -/
theorem refunds_sum_per_address (world after : World) (reachable : WorldReachable world)
    (u : EconomicUtxo) (r : Rejection) (accepted : rejectionAccepted world u r = .ok after) :
    (rejectedRequests world r.members |>.map (·.reference)).Nodup ∧
    (refundObligations (rejectedRequests world r.members) false |>.map Prod.fst).Nodup ∧
    (∀ address amount, (address, amount) ∈ refundObligations (rejectedRequests world r.members) false ↔
      address ∈ (rejectedRequests world r.members).map (·.refundAddress) ∧
      amount = ((rejectedRequests world r.members |>.filter fun q => q.refundAddress == address).map
        fun q => q.contents.lovelace - q.declaredTip).sum) ∧
    ∀ address, refundOwed (rejectedRequests world r.members) false address ≤
      ((r.transaction.outputs.filter fun o => o.output.address == some address).map
        fun o => o.output.lovelace).sum := by
  have floor := rejection_refund_floor world after reachable u r accepted
  refine ⟨floor.2.1.symm ▸ floor.1, ?_, ?_, refund_floor (rejection_refunds accepted)⟩
  · simpa [refundObligations, List.map_map, Function.comp_def] using
      unique_addresses ((rejectedRequests world r.members).map (·.refundAddress))
  · intro address amount
    simp [refundObligations, List.mem_map, mem_addresses, refundOwed, refundAmount,
      eq_comm, and_comm, and_left_comm]

end Singular.Statements
