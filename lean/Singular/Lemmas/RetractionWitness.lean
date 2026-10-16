import Singular.Lemmas.FoldWitnessAdmission

/-! A finite retraction witness with explicit signers, interval, funding and fee.
The unspent set is a model construction, not a claim about a wallet or ledger. -/

namespace Singular

def retractionWitnessInputs (world : World) (booking : RegistrationBooking) : List TxInput :=
  [foldWitnessInput booking.request.reference,
   foldWitnessInput ⟨terminationWitnessFresh world, 1⟩]

def retractionWitnessTransaction (world : World) (booking : RegistrationBooking)
    (interval : Interval) (signers : List Nat) (funding fee : Nat) : EconomicTransaction :=
  let amount := booking.request.contents.lovelace + (funding - fee)
  let output := { foldWitnessOrdinary amount with
    output.address := some booking.request.refundAddress }
  { transaction := {
      inputs := retractionWitnessInputs world booking, outputs := [output.output],
      mint := [], signers, refunds := [], validity := some interval, fee, donation := 0 },
    identity := terminationWitnessFresh world + 1, outputs := [output],
    trieReadyMint := booking.request.contents.trieReadyTags.map (fun tag => (tag, -1)),
    applicationMint := booking.request.contents.applicationTags.map
      (fun tag => (applicationTagIdentity tag, -1)) }

theorem retractionWitnessInputs_contains (world : World) (booking : RegistrationBooking)
    (ref : OutRef) :
    inputsContainReference (retractionWitnessInputs world booking) ref =
      decide (ref = booking.request.reference ∨ ref = ⟨terminationWitnessFresh world, 1⟩) := by
  simp [inputsContainReference, retractionWitnessInputs, foldWitnessInput, eq_comm]

theorem retractionWitnessInputs_pending {world : World} (booking : RegistrationBooking)
    {ref : OutRef} (member : ref ∈ worldRequestReferences world) :
    inputsContainReference (retractionWitnessInputs world booking) ref =
      decide (ref = booking.request.reference) := by
  have one : ref ≠ ⟨terminationWitnessFresh world, 1⟩ := by
    intro equal; exact terminationWitnessFresh_absent world 1 (equal ▸ member)
  simp [retractionWitnessInputs_contains, one]

theorem retractionWitness_selection (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending) :
    world.pending.filter (fun b => inputsContainReference
      (retractionWitnessInputs world booking) b.request.reference) = [booking] ∧
    world.terminations.filter (fun b => inputsContainReference
      (retractionWitnessInputs world booking) b.request.reference) = [] := by
  have unique := List.nodup_append.mp (reachable_request_references world reachable)
  constructor
  · have predicates : world.pending.filter (fun b => inputsContainReference
        (retractionWitnessInputs world booking) b.request.reference) =
        world.pending.filter (fun b => decide (b.request.reference = booking.request.reference)) := by
      apply List.filter_congr
      intro b member
      exact retractionWitnessInputs_pending booking
        (List.mem_append_left _ (List.mem_map.mpr ⟨b, member, rfl⟩))
    rw [predicates, distinct_key_filter _ unique.1 pending]
  · apply List.filter_eq_nil_iff.mpr
    intro b member
    rw [retractionWitnessInputs_pending booking
      (List.mem_append_right _ (List.mem_map.mpr ⟨b, member, rfl⟩))]
    simp only [decide_eq_true_eq]
    intro equal
    exact unique.2.2 _ (List.mem_map.mpr ⟨booking, pending, rfl⟩)
      _ (List.mem_map.mpr ⟨b, member, rfl⟩) equal.symm

theorem retractionWitness_spent_entries (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending) (funding : Nat) :
    (terminationWitnessUnspent world funding).filter (fun p => inputsContainReference
      (retractionWitnessInputs world booking) p.1) =
      [(booking.request.reference, registrationWitnessOutput booking),
       (⟨terminationWitnessFresh world, 1⟩, foldWitnessOrdinary funding)] := by
  have selected := retractionWitness_selection world reachable booking pending
  have member : booking.request.reference ∈ worldRequestReferences world :=
    List.mem_append_left _ (List.mem_map.mpr ⟨booking, pending, rfl⟩)
  have zero : (⟨terminationWitnessFresh world, 0⟩ : OutRef) ≠ booking.request.reference := by
    intro equal; exact terminationWitnessFresh_absent world 0 (equal.symm ▸ member)
  simp only [terminationWitnessUnspent, List.filter_append, List.filter_map, Function.comp_def,
    selected.1, selected.2, List.map_cons, List.map_nil, List.append_nil]
  simp [retractionWitnessInputs_contains, zero, OutRef.mk.injEq]

theorem retractionWitness_spent (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (signers : List Nat) (funding fee : Nat) :
    economicSpent (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) =
      [registrationWitnessOutput booking, foldWitnessOrdinary funding] := by
  simp [economicSpent, retractionWitnessTransaction,
    retractionWitness_spent_entries world reachable booking pending]

theorem retractionWitness_funding (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (interval : Interval) (signers : List Nat) (funding fee : Nat) :
    retractionFunding (terminationWitnessUnspent world funding)
      (retractionWitnessTransaction world booking interval signers funding fee) booking.request =
      [foldWitnessOrdinary funding] := by
  have member : booking.request.reference ∈ worldRequestReferences world :=
    List.mem_append_left _ (List.mem_map.mpr ⟨booking, pending, rfl⟩)
  have one : (⟨terminationWitnessFresh world, 1⟩ : OutRef) ≠ booking.request.reference := by
    intro equal; exact terminationWitnessFresh_absent world 1 (equal.symm ▸ member)
  have split : (fun p : OutRef × EconomicOutput =>
      inputsContainReference (retractionWitnessInputs world booking) p.1 &&
        p.1 != booking.request.reference) =
      (fun p => (p.1 != booking.request.reference) &&
        inputsContainReference (retractionWitnessInputs world booking) p.1) := by
    funext p; exact Bool.and_comm _ _
  simp only [retractionFunding, retractionWitnessTransaction, split, ← List.filter_filter,
    retractionWitness_spent_entries world reachable booking pending]
  simp [one]

end Singular
