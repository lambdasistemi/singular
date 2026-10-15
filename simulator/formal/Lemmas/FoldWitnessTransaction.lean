import Singular.Lemmas.FoldWitnessObservation
import Singular.Lemmas.FoldConservation

/-! A finite termination transaction with explicit funding and fee. -/

namespace Singular

def foldWitnessInput (reference : OutRef) : TxInput :=
  { role := .request, datum := .inline, stateTokens := 0, approvals := 0,
    lovelace := 0, ref := some reference }

def terminationWitnessInputs (world : World) (booking : TerminationBooking) : List TxInput :=
  [foldWitnessInput booking.request.reference,
   foldWitnessInput ⟨terminationWitnessFresh world, 0⟩,
   foldWitnessInput ⟨terminationWitnessFresh world, 1⟩]

def terminationWitnessResult (world : World) (booking : TerminationBooking) : Result :=
  let first := applyEdge (foldProjectedRegistry world)
    (foldLegacyRequest world.registry.config (.termination booking))
  combineResults first (emptyResult first.state)

def terminationWitnessTransaction (world : World) (booking : TerminationBooking)
    (time funding fee : Nat) : EconomicTransaction :=
  let outputs := [foldWitnessState (terminationWitnessResult world booking).state.config,
    foldWitnessOrdinary (funding + booking.request.declaredTip - fee)]
  { transaction := {
      inputs := terminationWitnessInputs world booking,
      outputs := outputs.map (·.output), mint := [], signers := [], refunds := [],
      validity := some ⟨time, time + 1⟩, fee,
      donation := booking.request.contents.lovelace - booking.request.declaredTip },
    identity := terminationWitnessFresh world + 1, outputs,
    trieReadyMint := booking.request.contents.trieReadyTags.map (fun tag => (tag, -1)),
    applicationMint := [], singularMint := booking.request.singularTags.map (fun tag => (tag, -1)) }

theorem terminationWitnessInputs_contains (world : World) (booking : TerminationBooking)
    (ref : OutRef) :
    inputsContainReference (terminationWitnessInputs world booking) ref =
      decide (ref = booking.request.reference ∨ ref = ⟨terminationWitnessFresh world, 0⟩ ∨
        ref = ⟨terminationWitnessFresh world, 1⟩) := by
  simp [inputsContainReference, terminationWitnessInputs, foldWitnessInput, eq_comm]

theorem terminationWitnessInputs_pending {world : World} (booking : TerminationBooking)
    {ref : OutRef} (member : ref ∈ worldRequestReferences world) :
    inputsContainReference (terminationWitnessInputs world booking) ref =
      decide (ref = booking.request.reference) := by
  have zero : ref ≠ ⟨terminationWitnessFresh world, 0⟩ := by
    intro equal; exact terminationWitnessFresh_absent world 0 (equal ▸ member)
  have one : ref ≠ ⟨terminationWitnessFresh world, 1⟩ := by
    intro equal; exact terminationWitnessFresh_absent world 1 (equal ▸ member)
  simp [terminationWitnessInputs_contains, zero, one]

theorem terminationWitness_members (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) :
    foldMembers world (terminationWitnessTransaction world booking time funding fee) =
      [.termination booking] := by
  simp [foldMembers, terminationWitnessTransaction, terminationWitnessInputs, foldWitnessInput,
    foldMemberAt_pending_termination world reachable booking pending,
    foldMemberAt_absent (terminationWitnessFresh_absent world 0),
    foldMemberAt_absent (terminationWitnessFresh_absent world 1)]

theorem terminationWitness_spent_entries (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) :
    (terminationWitnessUnspent world funding).filter (fun p => inputsContainReference
      (terminationWitnessTransaction world booking time funding fee).transaction.inputs p.1) =
      [(booking.request.reference, terminationWitnessOutput booking),
       (⟨terminationWitnessFresh world, 0⟩, foldWitnessState world.registry.config),
       (⟨terminationWitnessFresh world, 1⟩, foldWitnessOrdinary funding)] := by
  have unique := List.nodup_append.mp (reachable_request_references world reachable)
  have regs : (world.pending.map (fun b => (b.request.reference, registrationWitnessOutput b))).filter
      (fun p => inputsContainReference (terminationWitnessInputs world booking) p.1) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro entry member
    obtain ⟨b, bookingMember, rfl⟩ := List.mem_map.mp member
    rw [terminationWitnessInputs_pending booking (List.mem_append_left _ (List.mem_map.mpr ⟨b, bookingMember, rfl⟩))]
    simp only [decide_eq_true_eq]
    exact unique.2.2 _ (List.mem_map.mpr ⟨b, bookingMember, rfl⟩) _ (List.mem_map.mpr ⟨booking, pending, rfl⟩)
  have terms : (world.terminations.map (fun b => (b.request.reference, terminationWitnessOutput b))).filter
      (fun p => inputsContainReference (terminationWitnessInputs world booking) p.1) =
      [(booking.request.reference, terminationWitnessOutput booking)] := by
    rw [List.filter_map]
    simp only [Function.comp_def]
    have filtered : world.terminations.filter (fun b =>
        inputsContainReference (terminationWitnessInputs world booking) b.request.reference) =
        world.terminations.filter (fun b => decide (b.request.reference = booking.request.reference)) := by
      apply List.filter_congr
      intro b member
      exact terminationWitnessInputs_pending booking
        (List.mem_append_right _ (List.mem_map.mpr ⟨b, member, rfl⟩))
    rw [filtered, distinct_key_filter _ unique.2.1 pending]
    rfl
  simp only [terminationWitnessUnspent, terminationWitnessTransaction,
    List.filter_append, regs, terms, List.nil_append, List.map_append]
  simp [terminationWitnessInputs_contains]

theorem terminationWitness_spent (world : World) (reachable : WorldReachable world)
    (booking : TerminationBooking) (pending : booking ∈ world.terminations)
    (time funding fee : Nat) :
    economicSpent (terminationWitnessUnspent world funding)
      (terminationWitnessTransaction world booking time funding fee) =
      [terminationWitnessOutput booking, foldWitnessState world.registry.config,
        foldWitnessOrdinary funding] := by
  simp only [economicSpent, terminationWitness_spent_entries world reachable booking pending,
    List.map_cons, List.map_nil]

end Singular
