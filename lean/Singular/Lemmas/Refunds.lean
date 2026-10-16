import Singular.Lemmas.EconomicRejection
import Singular.Statements.Booking

/-! Refund floors judge actual transactions. An address receives the sum of
all outputs at that address, regardless of their purported purpose. -/

namespace Singular.RefundProof

theorem mem_addresses (addresses : List Nat) (address : Nat) :
    address ∈ addresses.eraseDups ↔ address ∈ addresses := by
  match addresses with
  | [] => simp
  | head :: rest =>
    rw [List.eraseDups_cons]
    have shorter : (rest.filter fun b => !b == head).length < (head :: rest).length :=
      Nat.lt_succ_of_le (List.length_filter_le _ _)
    rw [List.mem_cons, mem_addresses]
    simp only [List.mem_filter, List.mem_cons]
    by_cases same : address = head <;> simp_all
termination_by addresses.length

theorem unique_addresses (addresses : List Nat) : addresses.eraseDups.Nodup := by
  match addresses with
  | [] => simp
  | head :: rest =>
    rw [List.eraseDups_cons, List.nodup_cons]
    have shorter : (rest.filter fun b => !b == head).length < (head :: rest).length :=
      Nat.lt_succ_of_le (List.length_filter_le _ _)
    exact ⟨by simp [mem_addresses], unique_addresses _⟩
termination_by addresses.length

set_option maxRecDepth 2048 in
theorem rejection_refunds {world after : World} {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionAccepted world u r = .ok after) :
    refundRefusal r.transaction (refundObligations (rejectedRequests world r.members) false)
      "reject-refund-short" = none := by
  have refused : rejectionRefusal world u r = none := by
    unfold rejectionAccepted at accepted
    split at accepted
    · contradiction
    · assumption
  unfold rejectionRefusal at refused
  simp only [bind, pure, Option.bind] at refused
  repeat (split at refused <;> try contradiction)
  all_goals simp_all [← Option.eq_none_iff_forall_ne_some]

theorem refund_floor {tx : EconomicTransaction} {requests : List RegistrationRequest}
    {retract : Bool} {reason : String}
    (checked : refundRefusal tx (refundObligations requests retract) reason = none)
    (address : Nat) : refundOwed requests retract address ≤ refundPaid tx address := by
  have all : ∀ obligation ∈ refundObligations requests retract,
      obligation.2 ≤ refundPaid tx obligation.1 := by
    simpa [refundRefusal, List.all_eq_true] using checked
  by_cases present : address ∈ requests.map (·.refundAddress)
  · apply all (address, refundOwed requests retract address)
    exact List.mem_map.mpr ⟨address, (mem_addresses _ _).mpr present, rfl⟩
  · have empty : requests.filter (fun r => r.refundAddress == address) = [] := by
      apply List.filter_eq_nil_iff.mpr
      intro request member
      have different : request.refundAddress ≠ address := by
        intro equal
        exact present (equal ▸ List.mem_map.mpr ⟨request, member, rfl⟩)
      simpa using different
    simp [refundOwed, empty]

theorem selected_members {world after : World} {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionAccepted world u r = .ok after) :
    (rejectedRequests world r.members).map (·.reference) = r.members.map Prod.fst := by
  obtain ⟨interval, _, _, _, _, grounds, _⟩ := (rejectionAccepted_checks accepted).2.2.2
  have found : ∀ member ∈ r.members, ∃ booking,
      world.pending.find? (fun b => b.request.reference == member.1) = some booking := by
    intro member belongs
    have admitted := grounds member belongs
    cases lookup : world.pending.find? (fun b => b.request.reference == member.1) with
    | some b => exact ⟨b, rfl⟩
    | none =>
      simp only [rejectionMemberRefusal, lookup] at admitted
      repeat (split at admitted <;> try contradiction)
  have selected : ∀ members, (∀ member ∈ members, ∃ booking,
      world.pending.find? (fun b => b.request.reference == member.1) = some booking) →
      (rejectedRequests world members).map (·.reference) = members.map Prod.fst := by
    intro members
    induction members with
    | nil => intro _; rfl
    | cons member rest ih =>
      intro found
      obtain ⟨booking, lookup⟩ := found member (by simp)
      have reference : booking.request.reference = member.1 := by
        simpa using List.find?_some lookup
      simp only [rejectedRequests, List.filterMap_cons, lookup, Option.map_some,
        List.map_cons, reference]
      exact congrArg (List.cons member.1) (ih (fun m hm => found m (List.mem_cons_of_mem _ hm)))
  exact selected r.members found

theorem selected_pending {world : World} {members : List (OutRef × RejectReason)}
    {request : RegistrationRequest} (member : request ∈ rejectedRequests world members) :
    ∃ booking ∈ world.pending, booking.request = request := by
  obtain ⟨item, _, found⟩ := List.mem_filterMap.mp member
  cases lookup : world.pending.find? (fun b => b.request.reference == item.1) with
  | none => simp [lookup] at found
  | some booking =>
    simp only [lookup, Option.map_some, Option.some.injEq] at found
    exact ⟨booking, List.mem_of_find?_eq_some lookup, found⟩

set_option maxRecDepth 2048 in
theorem retraction_checks {world after : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (accepted : retractionAccepted world u tx = .ok after) :
    retractionInputsRefusal u tx = none ∧ economicObservationRefusal world u tx = none ∧
    ∃ request, retractionRequest world tx = .ok request ∧
      tx.transaction.signers.contains request.refundAddress = true ∧
      (∃ interval, tx.transaction.validity = some interval ∧ interval.valid ∧
        request.submittedAt + world.registry.config.processTime ≤ interval.lower ∧
        interval.upper ≤ request.submittedAt + world.registry.config.processTime +
          world.registry.config.retractTime) ∧
      requestTagsBurned u tx = true ∧ rejectionSupplyUnchanged u tx = true ∧
      refundRefusal tx (refundObligations [request] true) "retract-refund-short" = none := by
  have refused : retractionRefusal world u tx = none := by
    unfold retractionAccepted at accepted
    split at accepted
    · contradiction
    · assumption
  unfold retractionRefusal at refused
  simp only [bind, pure, Option.bind] at refused
  repeat (split at refused <;> try contradiction)
  all_goals simp_all [← Option.eq_none_iff_forall_ne_some]

theorem retraction_request {world : World} {tx : EconomicTransaction} {request : RegistrationRequest}
    (found : retractionRequest world tx = .ok request) :
    ∃ booking ∈ world.pending, booking.request = request ∧
      some request.reference ∈ tx.transaction.inputs.map (·.ref) := by
  unfold retractionRequest at found
  simp only [pure, Except.pure] at found
  split at found
  · contradiction
  · split at found
    · contradiction
    next booking selected =>
      have equal : booking.request = request := by
        simpa [bind, Except.bind, pure, Except.pure] using found
      have member : booking ∈ world.pending.filter (fun b =>
          inputsContainReference tx.transaction.inputs b.request.reference) := by
        rw [selected]; simp
      obtain ⟨pending, consumed⟩ := List.mem_filter.mp member
      refine ⟨booking, pending, equal, ?_⟩
      rw [equal] at consumed
      simpa [inputsContainReference, List.any_eq_true, List.mem_map] using consumed
    · contradiction

theorem retraction_no_state {u : EconomicUtxo} {tx : EconomicTransaction}
    (checked : retractionInputsRefusal u tx = none) :
    (spentOutputs u.ledger tx.transaction).any
        (fun o => o.stateTokens > 0 || o.role == .state) = false ∧
    (u.filter fun p => inputsContainReference tx.transaction.referenceInputs p.1).any
        (fun p => p.2.output.stateTokens > 0 || p.2.output.role == .state) = false := by
  unfold retractionInputsRefusal at checked
  repeat (split at checked <;> try contradiction)
  all_goals simp_all <;> assumption

theorem allocations {world : World} (reachable : WorldReachable world)
    {request : RegistrationRequest} (pending : ∃ b ∈ world.pending, b.request = request) :
    request.contents.lovelace = request.registrationCost + request.declaredTip + request.carrierAda := by
  obtain ⟨booking, member, rfl⟩ := pending
  have exact := (Statements.booked_request_has_exact_contents world reachable booking member).1
  unfold exactContents at exact
  have amount := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp exact).1).2
  simpa [registrationDeclaredLovelace] using amount

theorem costs_le_owed {world : World} (reachable : WorldReachable world)
    (requests : List RegistrationRequest) (retract : Bool) (address : Nat)
    (pending : ∀ request ∈ requests, ∃ b ∈ world.pending, b.request = request) :
    ((requests.filter fun r => r.refundAddress == address).map (·.registrationCost)).sum ≤
      refundOwed requests retract address := by
  unfold refundOwed
  have bound : ∀ request ∈ requests, request.registrationCost ≤ refundAmount request retract := by
    intro request member
    have amount := allocations reachable (pending request member)
    cases retract <;> simp only [refundAmount, Bool.false_eq_true, ↓reduceIte] <;> omega
  have sumBound : ∀ items : List RegistrationRequest,
      (∀ r ∈ items, r.registrationCost ≤ refundAmount r retract) →
      (items.map (·.registrationCost)).sum ≤ (items.map fun r => refundAmount r retract).sum := by
    intro items
    induction items with
    | nil => simp
    | cons r rest ih =>
      intro bounds
      have first := bounds r (by simp)
      have other := ih (fun x hx => bounds x (List.mem_cons_of_mem _ hx))
      simpa using Nat.add_le_add first other
  exact sumBound _ (fun r hr => bound r (List.mem_filter.mp hr).1)

end Singular.RefundProof
