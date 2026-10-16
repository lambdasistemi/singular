import Singular.Lemmas.Refunds
import Singular.Lemmas.FoldWitnessRouting
import Singular.Lemmas.RejectionState

/-! Observed funding and conservation for arbitrary accepted retractions. -/

namespace Singular

set_option maxRecDepth 2048 in
theorem retraction_funding_checks {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : retractionAccepted world u tx = .ok after) :
    ∃ request, retractionRequest world tx = .ok request ∧
      retractionFundingRefusal u tx request = none ∧
      tx.transaction.donation = 0 ∧ tx.transaction.fee ≤ retractionFundingLovelace u tx request ∧
      balanced u.ledger tx.transaction = true ∧
      tx.outputs.all foldBareValue = true ∧ (economicSpent u tx).all foldBareValue = true := by
  have refused : retractionRefusal world u tx = none := by
    unfold retractionAccepted at accepted
    split at accepted
    · contradiction
    · assumption
  unfold retractionRefusal at refused
  simp only [bind, pure, Option.bind] at refused
  repeat (split at refused <;> try contradiction)
  all_goals simp_all [← Option.eq_none_iff_forall_ne_some]

theorem retraction_funding_ordinary {u : EconomicUtxo} {tx : EconomicTransaction}
    {request : RegistrationRequest} (checked : retractionFundingRefusal u tx request = none) :
    ∀ output ∈ retractionFunding u tx request, foldOrdinary output = true ∧
      output.output.role ≠ .state ∧ output.output.role ≠ .request ∧ output.request = none := by
  intro output member
  have checked := List.findSome?_eq_none_iff.mp checked output member
  simp only [retractionFundingRefusal] at checked
  repeat (split at checked <;> try contradiction)
  all_goals simp_all [foldOrdinary]

theorem sum_filter_parts {α : Type} (values : List α) (predicate : α → Bool)
    (weight : α → Nat) :
    (values.map weight).sum = ((values.filter predicate).map weight).sum +
      ((values.filter fun value => !predicate value).map weight).sum := by
  induction values with
  | nil => simp
  | cons value rest ih => cases h : predicate value <;> simp [h, ih, Nat.add_assoc, Nat.add_left_comm, Nat.add_comm]

theorem retraction_input_lovelace {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} {request : RegistrationRequest}
    (accepted : retractionAccepted world u tx = .ok after)
    (selected : retractionRequest world tx = .ok request) :
    outputLovelace (spentOutputs u.ledger tx.transaction) =
      request.contents.lovelace + retractionFundingLovelace u tx request := by
  have observations := (RefundProof.retraction_checks accepted).2.1
  obtain ⟨worldObserved, unique, _⟩ := rejectionObservation_world observations
  obtain ⟨booking, pending, same, consumed⟩ := RefundProof.retraction_request selected
  have observed : observesRegistration u request = true := by
    rw [← same]
    exact List.all_eq_true.mp (Bool.and_eq_true_iff.mp worldObserved).1 booking pending
  have spent : inputsContainReference tx.transaction.inputs request.reference = true := by
    simpa [inputsContainReference, List.any_eq_true, List.mem_map] using consumed
  cases lookup : economicLookup u request.reference with
  | none => simp [observesRegistration, lookup] at observed
  | some output =>
    have actual := economicLookup_mem lookup
    have value : output.output.lovelace = request.contents.lovelace := by
      simp only [observesRegistration, lookup, decide_eq_true_eq] at observed
      exact observed.2.2.2.2.2.1
    let entries := u.filter (fun p => inputsContainReference tx.transaction.inputs p.1)
    have one : entries.filter (fun p => p.1 == request.reference) = [(request.reference, output)] := by
      have selectedActual : (request.reference, output) ∈ entries := List.mem_filter.mpr ⟨actual, spent⟩
      have uniqueSelected : (entries.map Prod.fst).Nodup :=
        unique.sublist (List.Sublist.map _ List.filter_sublist)
      have one := distinct_key_filter Prod.fst uniqueSelected selectedActual
      have predicates : (fun p : OutRef × EconomicOutput => p.1 == request.reference) =
          (fun p => decide (p.1 = request.reference)) := by
        funext p; apply Bool.eq_iff_iff.mpr; simp
      rw [predicates]; exact one
    obtain ⟨found, foundAt, funding, _⟩ := retraction_funding_checks accepted
    have equal : found = request := by rw [selected] at foundAt; exact Except.ok.inj foundAt.symm
    subst found
    have ordinary := retraction_funding_ordinary funding
    have allOrdinary : (retractionFunding u tx request).filter foldOrdinary = retractionFunding u tx request := by
      apply List.filter_eq_self.mpr
      intro output member
      exact (ordinary output member).1
    have rest : entries.filter (fun p => !(p.1 == request.reference)) =
        u.filter (fun p => inputsContainReference tx.transaction.inputs p.1 && p.1 != request.reference) := by
      simp only [entries, List.filter_filter]
      apply List.filter_congr
      intro p _
      apply Bool.eq_iff_iff.mpr
      simp [Bool.and_comm]
    have total := sum_filter_parts entries (fun p => p.1 == request.reference)
      (fun p => p.2.output.lovelace)
    rw [one, rest] at total
    unfold retractionFundingLovelace foldOrdinaryLovelace
    rw [allOrdinary]
    simpa [entries, outputLovelace, spentOutputs, EconomicUtxo.ledger, List.filter_map, retractionFunding,
      List.map_map, Function.comp_def, value] using total

end Singular
