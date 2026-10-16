import Singular.Lemmas.FoldFacts
import Singular.Lemmas.FoldWitnessRouting

/-! Economic termination provenance and availability. The application's
release condition remains an external obligation, not an application tag. -/

namespace Singular.Statements

/-- Every termination selected by an accepted fold is pending, its actual
unspent output agrees with that booking, and it carries the key's genuine
singular tag. The retained booking was admitted in a reachable earlier world.
This proves Singular's booking provenance, not the application's release rule. -/
theorem only_booked_terminations_fold (world after : World) (reachable : WorldReachable world)
    (unspent : EconomicUtxo) (transaction : EconomicTransaction)
    (accepted : foldAccepted world unspent transaction = .ok after)
    (booking : TerminationBooking)
    (selected : FoldMember.termination booking ∈ foldMembers world transaction) :
    booking ∈ world.terminations ∧ observesTermination unspent booking.request = true ∧
    booking.request.singularTags = [world.registry.config.singularTag booking.request.key] ∧
    ∃ before booked : World, WorldReachable before ∧ bookTermination before booking = .ok booked := by
  have pending := (foldMembers_termination selected).1
  have observations := (foldPrerequisite_observations (foldAccepted_checks accepted).1).1
  have observed := (rejectionObservation_world observations).1
  have actual : observesTermination unspent booking.request = true :=
    List.all_eq_true.mp (Bool.and_eq_true_iff.mp observed).2 booking pending
  obtain ⟨_, tags, _, _, before, booked, reached, admitted, _⟩ :=
    termination_request_carries_genuine_token world reachable booking pending
  exact ⟨pending, actual, tags, before, booked, reached, admitted⟩

/-- At any chosen time a pending termination has an accepted model
transaction. The unspent set is constructed coherently from the reachable
world and the supplied ordinary funding. Willingness to process this tip,
funding for the fee, and a fee within the declared tip are explicit premises.
This proves neither available ledger funding nor inclusion or builder behavior;
there is no ledger minimum, fee-market or application-release claim. -/
theorem booked_termination_foldable (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) (folderAccepts : Nat → Prop)
    (willing : folderAccepts booking.request.declaredTip)
    (funded : fee ≤ funding) (feeWithinTip : fee ≤ booking.request.declaredTip) :
    ∃ unspent : EconomicUtxo, ∃ transaction : EconomicTransaction, ∃ after : World,
      observesWorld world unspent = true ∧
      transaction.transaction.validity = some ⟨time, time + 1⟩ ∧
      transaction.transaction.fee = fee ∧
      foldOrdinaryLovelace (economicSpent unspent transaction) = funding ∧
      foldMembers world transaction = [.termination booking] ∧
      foldAccepted world unspent transaction = .ok after ∧
      WorldReachable after ∧
      trieGet after.registry.trie booking.request.key = .known .terminal ∧
      booking ∉ after.terminations ∧
      folderAccepts (foldObligations (foldMembers world transaction)).tips ∧
      transaction.transaction.fee ≤ (foldObligations (foldMembers world transaction)).tips := by
  let unspent := terminationWitnessUnspent world funding
  let transaction := terminationWitnessTransaction world booking time funding fee
  let result := terminationWitnessResult world booking
  let after := foldEffect world transaction result
  have accepted : foldAccepted world unspent transaction = .ok after := by
    simp only [foldAccepted, unspent, transaction,
      terminationWitness_prerequisite world reachable booking pending,
      terminationWitness_members world reachable booking pending, List.map_cons, List.map_nil,
      terminationWitness_registry world reachable booking pending,
      terminationWitness_routing world reachable booking pending time funding fee funded]
    rfl
  have selected := terminationWitness_members world reachable booking pending time funding fee
  have tags := booked_termination_tag_commits_to_own_operation world reachable booking pending
  refine ⟨unspent, transaction, after,
    terminationWitnessUnspent_observes world reachable funding, rfl, rfl, ?_, selected,
    accepted, WorldReachable.fold reachable unspent transaction accepted, ?_, ?_, ?_, ?_⟩
  · simp [unspent, transaction, terminationWitness_spent world reachable booking pending,
      foldOrdinaryLovelace, foldOrdinary, terminationWitnessOutput, foldWitnessState,
      foldWitnessOrdinary, tags.1]
  · simp [after, result, foldEffect, foldRegistryEffect, terminationWitnessResult,
      combineResults, emptyResult, applyEdge, foldLegacyRequest, foldProjectedRegistry, trieGet_set_eq]
  · simp [after, foldEffect, foldRemainingTerminations, transaction, terminationWitnessTransaction,
      terminationWitnessInputs_contains]
  · simpa only [transaction, selected, foldObligations, List.map_cons, List.map_nil,
      List.sum_cons, List.sum_nil, FoldMember.tip, Nat.add_zero] using willing
  · change fee ≤ (foldObligations (foldMembers world transaction)).tips
    simpa only [transaction, selected, foldObligations, List.map_cons, List.map_nil,
      List.sum_cons, List.sum_nil, FoldMember.tip, Nat.add_zero] using feeWithinTip

end Singular.Statements
