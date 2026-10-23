import NoPin.Held.Corpus

/-! Executed satisfying instances of the #741 hypothesis, not accepted law.
Economic protection is reused from the accepted root at the actual projected
reachable world; the oracle's positive results are proved in the kernel. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 2000000
namespace NoPin.Held.Fixtures
open Singular

/-- Executed root membership instance for #741, not accepted candidate law. -/
theorem pending7_member : booking 7 ∈ (project two).terminations := by
  change booking 7 ∈ [booking 8, booking 7]
  simp

/-- Executed #741 instance reusing the accepted non-rejection statement on every real rejection input. -/
theorem pending7_protected : ∀ ground, ∀ (u : EconomicUtxo) (r : Rejection) (after : World),
    rejectionAccepted (project two) u r = .ok after →
    ((booking 7).request.reference, ground) ∉ r.members := by
  intro ground
  exact (Singular.Statements.termination_unrejectable (project two) two_reachable
    (booking 7) pending7_member).2 ground |>.2

/-- Executed #741 instance reusing accepted operation/nonce commitment, not the simplified role tag. -/
theorem pending7_root_tag : (booking 7).request.contents.trieReadyTags =
    [(project two).registry.config.trieReadyTag
      (trieReadyTagAssetName (booking 7).request.operation (booking 7).request.nonce)] ∧
    (booking 7).request.contents.applicationTags = [] :=
  Singular.Statements.booked_termination_tag_commits_to_own_operation
    (project two) two_reachable (booking 7) pending7_member

/-- Executed #741 instance: every public positive query invokes its actual producer. -/
theorem good_positive (surface : Case) : runQuery .none (goodQuery surface) = true := by
  cases surface with
  | liveUpdate => decide +kernel
  | liveRelease => decide +kernel
  | genuine =>
    change genuine .none hash encode config (.pending (pending 7 5)) = true
    exact genuine7_executes
  | booking =>
    change book .none hash encode before (.live (holding 7 5)) (pending 7 5) [42] = true
    simp only [book, applyGuard, reduceBEq, Bool.false_eq_true, ite_false, book7_accepted]
    have binding : (pending 7 5).booking = booking 7 := rfl
    simp only [binding, book7_accepted, Except.isOk, Bool.and_true]
    decide +kernel
  | rebooking => rfl
  | pendingRelease =>
    change pendingRelease .none hash encode config (pending 7 5) localTx = true
    exact release7_executes
  | projection => decide +kernel
  | coupling =>
    change couplingCheck .none registry 7 (holding 7 5).token localTx.assets folded = true
    simp only [couplingCheck, applyGuard, reduceBEq, Bool.false_eq_true, ite_false]
    change (((decide (observationCorrespondence registry 7 (holding 7 5).token localTx.assets folded) &&
      acceptedFold folded) && _) && _) = true
    rw [fold_executes]
    decide +kernel
  | discovery =>
    change [pending 8 7, pending 7 5].contains (pending 7 5) = true
    simp
  | consumption =>
    change [pending 8 7, pending 7 5].contains (pending 7 5) = true
    simp
  | economicAvailability =>
    change (foldAccepted (project two) (terminationWitnessUnspent (project two) 20)
      (terminationWitnessTransaction (project two) (booking 7) 1000 20 1)).isOk = true
    simp only [foldAccepted,
      terminationWitness_prerequisite (project two) two_reachable (booking 7) pending7_member,
      terminationWitness_members (project two) two_reachable (booking 7) pending7_member,
      List.map_cons, List.map_nil,
      terminationWitness_registry (project two) two_reachable (booking 7) pending7_member,
      terminationWitness_routing (project two) two_reachable (booking 7) pending7_member 1000 20 1 (by decide)]
    rfl
  | partition =>
    change valuePartition selected folded physical = true
    exact partition_executes
  | composed =>
    change composed hash encode registry selected folded physical = true
    exact composition_executes
  | rejection =>
    change Bool.not ((rejectionAccepted (project two) folded.unspent
      (attemptedRejection (goodQuery .rejection) folded)).isOk) = true
    cases accepted : rejectionAccepted (project two) folded.unspent
        (attemptedRejection (goodQuery .rejection) folded) with
    | error reason => rfl
    | ok after =>
      have impossible := pending7_protected .expired folded.unspent
        (attemptedRejection (goodQuery .rejection) folded) after accepted
      exact False.elim (impossible (by simp [attemptedRejection, goodQuery, pending]))
  | permanent => decide +kernel
/-- Hypothesis fixture under #741, not accepted law; first actual terminal root result. -/
def terminal7 : Result := applyEdge registered8.state
  (foldLegacyRequest registered8.state.config (.termination (booking 7)))
/-- Hypothesis fixture under #741, not accepted law; second actual terminal root result. -/
def terminal8 : Result := applyEdge terminal7.state
  (foldLegacyRequest terminal7.state.config (.termination (booking 8)))
/-- Executed #741 instance of the accepted root transition, not candidate law. -/
theorem terminal7_accepted : step registered8.state
    (foldLegacyRequest registered8.state.config (.termination (booking 7))) = .ok terminal7 := by rfl
/-- Executed #741 instance of the accepted root transition, not candidate law. -/
theorem terminal8_accepted : step terminal7.state
    (foldLegacyRequest terminal7.state.config (.termination (booking 8))) = .ok terminal8 := by rfl
/-- Executed #741 instance; the actual folded registry has an accepted root derivation. -/
theorem folded_registry_reachable : Reachable folded.after.registry := by
  change Reachable terminal8.state
  exact Reachable.next (Reachable.next registered_reachable terminal7_accepted) terminal8_accepted
/-- Executed #741 instance reusing the exact accepted permanent-key law, including every future batch. -/
theorem folded7_permanent :
    (∀ r : Request, r.key = 7 → ∃ why, step folded.after.registry r = .error why) ∧
    (∀ (acts : List Request) (result : Result), foldBatch folded.after.registry acts = .ok result →
      trieGet result.state.trie 7 = .known .terminal) :=
  Singular.Statements.termination folded.after.registry 7 folded_registry_reachable (by decide +kernel)
/-- Executed #741 finite-world instance of the accepted supply law for every key. -/
theorem projected_supply (key : Key) :
    (worldSingularSupply (project two) key = 1 ↔ trieGet (project two).registry.trie key = .known .active) ∧
    (worldSingularSupply (project two) key = 0 ↔ trieGet (project two).registry.trie key ≠ .known .active) ∧
    worldSingularSupply (project two) key ≤ 1 ∧
    carriedSingularCount (project two) key = pendingTerminationCount (project two) key :=
  Singular.Statements.world_supply_sync (project two) two_reachable key
/-- Hypothesis fixture under #741, not accepted law; retained key 7 with another key's root booking. -/
def wrongKeyBooking : Pending := { pending 7 5 with
  holding := { (pending 7 5).holding with reference := (request 8).reference }, booking := booking 8 }
/-- Executed #741 violating twin, not accepted law; exact root admission does not replace key/custody binding. -/
theorem wrong_key_booking_refused : book .none hash encode before (.live (holding 7 5)) wrongKeyBooking [42] = false := by
  simp only [book, applyGuard, reduceBEq, Bool.false_eq_true, ite_false]
  have binding : ((holding 7 5).control.registry == before.registryIdentity && wrongKeyBooking.booking.custodyInputs == [(holding 7 5).rootHolding] &&
    wrongKeyBooking.booking.request.key == (holding 7 5).control.key) = false := by decide +kernel
  rw [binding]
  simp
/-- Executed #741 connected consumption instance, not accepted law; both actual pending outputs leave. -/
theorem folded_outputs_consumed : (consume two folded.transaction).outputs = [] := by decide +kernel
/-- Executed #741 connected root instance, not accepted law; selected pending bookings leave the root world. -/
theorem folded_root_pending_empty : folded.after.terminations = [] := by decide +kernel
end NoPin.Held.Fixtures
