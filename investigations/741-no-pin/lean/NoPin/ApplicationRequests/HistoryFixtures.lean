import NoPin.ApplicationRequests.HistoryClaims
import NoPin.ApplicationRequests.Fixtures

/-! Finite hypothetical history certificates, not accepted law. Every active
token in these examples is produced by genesis followed by actual folds. The
application approvals in the initial world have external provenance: this is
a Singular history experiment, not an application lifecycle claim. -/
set_option maxRecDepth 32768
set_option maxHeartbeats 8000000
namespace NoPin.ApplicationRequests.HistoryEvidence
open Singular Fixtures

def memberDecidable {α : Type} [DecidableEq α] (a : α) :
    (xs : List α) → Decidable (a ∈ xs)
  | [] => .isFalse (by simp)
  | x :: xs =>
    if h : a = x then .isTrue (by simp [h])
    else match memberDecidable a xs with
      | .isTrue yes => .isTrue (List.mem_cons_of_mem x yes)
      | .isFalse no => .isFalse (by simpa only [List.mem_cons, h, false_or] using no)
local instance (priority := 10000) {α : Type} [DecidableEq α] (a : α) (xs : List α) :
    Decidable (a ∈ xs) := memberDecidable a xs

private theorem finite_all {α : Type} {xs : List α} {p : α → Prop}
    [DecidablePred p] (h : xs.all (fun x => decide (p x)) = true) : ∀ x ∈ xs, p x := by
  intro x member
  exact of_decide_eq_true (List.all_eq_true.mp h x member)

/-- Hypothesis fixture: a second application uses the very same public seed. -/
def otherRelease : PublishedRelease := ⟨6, 98, 70, 20⟩
def otherId : TokenId := stateAsset hash code otherRelease seed
def secondSeed : OutRef := ⟨11, 3⟩
def secondId : TokenId := stateAsset hash code release secondSeed
def emptyRegistry (r : PublishedRelease) (s : OutRef) (ref : OutRef) : PublicRegistry :=
  let id := stateAsset hash code r s
  ⟨id, s, ⟨ref, r.statePolicy, 2, .root (commit []), [(id, 1)]⟩, []⟩
def first : PublicRegistry := emptyRegistry release seed ⟨100, 0⟩
def other : PublicRegistry := emptyRegistry otherRelease seed ⟨100, 1⟩
def second : PublicRegistry := emptyRegistry release secondSeed ⟨101, 0⟩
def request (r : PublishedRelease) (id : TokenId) (key : Key) (ref : OutRef) : PendingRequest :=
  let data : RegistrationData := ⟨id, key, 42, 50, r.applicationCredential, 1000 + key, 0, 1, 20, 30⟩
  .registration ⟨ref, r.applicationCredential, 10, .application (2000 + key),
    [(registrationAsset hash code r data, 1)]⟩ data
def request7 : PendingRequest := request release first.identity 7 ⟨12, 0⟩
def request8 : PendingRequest := request release first.identity 8 ⟨12, 1⟩
def otherRequest : PendingRequest := request otherRelease other.identity 7 ⟨12, 2⟩
def repeatRequest : PendingRequest := request release first.identity 7 ⟨12, 3⟩
def laterRequest : PendingRequest := request release first.identity 9 ⟨12, 4⟩
def feeInput (index : Nat) : ObservedOutput := ⟨⟨14, index⟩, 60, 0, .empty, []⟩
def fund (index tx : Nat) : FoldFunding := ⟨feeInput index, 77, tx, ⟨5, 6⟩, 0⟩
def terminationApprovalInput : ObservedOutput := ⟨⟨13, 0⟩, release.applicationCredential, 0, .empty,
  [(terminationApproval hash code release first.identity 7, 1)]⟩
def initialOutputs : List ObservedOutput :=
  [⟨seed, 60, 4, .empty, []⟩, ⟨secondSeed, 60, 2, .empty, []⟩,
   request7.output, request8.output, otherRequest.output, repeatRequest.output,
   terminationApprovalInput, feeInput 0, feeInput 1, feeInput 2, feeInput 3,
   feeInput 4, laterRequest.output]
def initial : CandidateWorld := ⟨[], initialOutputs, [], []⟩
def genesisTx : NoPin.TxView := ⟨[seed], [⟨first.state.assets⟩, ⟨other.state.assets⟩],
  [(first.identity, 1), (other.identity, 1)], [release.statePolicy, otherRelease.statePolicy]⟩
def secondGenesisTx : NoPin.TxView := ⟨[secondSeed], [⟨second.state.assets⟩],
  [(second.identity, 1)], [release.statePolicy]⟩

/-- Hypothesis fixture: reconstruct only the observed successor, not ledger validity. -/
def successor (before : CandidateWorld) (registries : List PublicRegistry) (domain : List Preimage)
    (view : NoPin.TxView) (outputs : List ObservedOutput) : CandidateWorld :=
  ⟨registries, before.unspent.filter (fun output => !view.spent.contains output.reference) ++ outputs,
    before.spentReferences ++ view.spent, domain⟩
def genesisWorld : CandidateWorld := successor initial [first] [.state seed] genesisTx [first.state, other.state]
def otherGenesisWorld : CandidateWorld := { genesisWorld with registries := [other] }
def secondGenesisWorld : CandidateWorld := successor genesisWorld [first, second]
  (genesisWorld.domain ++ [.state secondSeed]) secondGenesisTx [second.state]
def otherSecondGenesisWorld : CandidateWorld := { secondGenesisWorld with
  registries := [other], domain := otherGenesisWorld.domain }
def registerFirst : FoldObservation := buildFold hash code commit release first [request7, request8] (fund 0 102)
def registerOther : FoldObservation := buildFold hash code commit otherRelease other [otherRequest] (fund 1 103)
def foldWorld (before : CandidateWorld) (o : FoldObservation) : CandidateWorld :=
  successor before (before.registries.map fun registry =>
    if registry.identity == o.before.identity then o.after else registry)
    (before.domain ++ o.changes.flatMap (changePreimages o)) o.assets o.outputs
def registeredFirst : CandidateWorld := foldWorld secondGenesisWorld registerFirst
def otherRegisteredFirst : CandidateWorld := { registeredFirst with
  registries := [other], domain := otherSecondGenesisWorld.domain }
def registeredBoth : CandidateWorld := successor registeredFirst registeredFirst.registries
  registeredFirst.domain registerOther.assets registerOther.outputs
def otherRegisteredBoth : CandidateWorld := foldWorld otherRegisteredFirst registerOther
def active7 : ObservedOutput := registerFirst.outputs[1]
def active8 : ObservedOutput := registerFirst.outputs[2]
def pending : ObservedOutput := ⟨⟨104, 0⟩, release.applicationCredential, 0, .empty,
  active7.assets ++ terminationApprovalInput.assets⟩
def bookingTx : NoPin.TxView := ⟨[active7.reference, terminationApprovalInput.reference],
  [⟨pending.assets⟩], [], [release.applicationPolicy]⟩
def booked : CandidateWorld := successor registeredBoth registeredBoth.registries
  registeredBoth.domain bookingTx [pending]
def otherBooked : CandidateWorld := successor otherRegisteredBoth otherRegisteredBoth.registries
  otherRegisteredBoth.domain bookingTx [pending]
def terminate : FoldObservation := buildFold hash code commit release registerFirst.after
  [.termination pending first.identity 7] (fund 2 105)
def terminated : CandidateWorld := foldWorld booked terminate
def otherTerminated : CandidateWorld := successor otherBooked otherBooked.registries
  otherBooked.domain terminate.assets terminate.outputs
def remint : FoldObservation :=
  let base := buildFold hash code commit release terminate.after [repeatRequest] (fund 4 107)
  let trie := trieSet terminate.after.trie 7 (.known .active)
  let state := { base.after.state with datum := .root (commit trie) }
  let outputs := state :: base.outputs.drop 1
  { base with
    after := { base.after with trie, state }
    outputs := outputs
    assets := { base.assets with outputs := outputs.map fun output => ⟨output.assets⟩ } }
def reminted : CandidateWorld := foldWorld terminated remint
def later : FoldObservation := buildFold hash code commit release terminate.after [laterRequest] (fund 3 106)
def laterWorld : CandidateWorld := foldWorld terminated later
def otherLaterWorld : CandidateWorld := successor otherTerminated otherTerminated.registries
  otherTerminated.domain later.assets later.outputs

/-- Hypothesis fixture: an extra mint of the untouched, already live key. -/
def duplicate : FoldObservation :=
  let last := terminate.outputs.getLast?.getD terminate.after.state
  let outputs := terminate.outputs.dropLast ++ [{ last with
    assets := last.assets ++ [(activeAsset hash code first.identity 8, 1)] }]
  { terminate with
    outputs := outputs
    assets := { terminate.assets with
      outputs := outputs.map (fun output => ⟨output.assets⟩)
      mint := terminate.assets.mint ++ [(activeAsset hash code first.identity 8, 1)] } }
def duplicated : CandidateWorld := foldWorld booked duplicate
/-- Hypothesis fixture: burn a genuine untouched token in the same physical fold. -/
def foreignBurn : FoldObservation :=
  { terminate with
    spentOutputs := terminate.spentOutputs ++ [active8]
    assets := { terminate.assets with
      spent := terminate.assets.spent ++ [active8.reference]
      mint := terminate.assets.mint ++ [(activeAsset hash code first.identity 8, -1)] } }
def foreignBurned : CandidateWorld := foldWorld booked foreignBurn

theorem initial_reachable : CandidateReachable hash code commit release initial := by
  exact .initial initialOutputs (by decide) (by decide)
theorem other_initial_reachable : CandidateReachable hash code commit otherRelease initial := by
  exact .initial initialOutputs (by decide) (by decide)
theorem genesis_ledger : LedgerObservationCorrespondence initial genesisWorld genesisTx
    [initialOutputs[0]] [first.state, other.state] 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_genesis_ledger : LedgerObservationCorrespondence initial otherGenesisWorld genesisTx
    [initialOutputs[0]] [first.state, other.state] 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem genesis_reachable : CandidateReachable hash code commit release genesisWorld := by
  exact .genesis initial_reachable seed genesisTx [initialOutputs[0]] [first.state, other.state]
    first 0 0 genesis_ledger (by decide) rfl rfl (by decide) (by decide) rfl (by decide) rfl rfl
theorem other_genesis_reachable : CandidateReachable hash code commit otherRelease otherGenesisWorld := by
  exact .genesis other_initial_reachable seed genesisTx [initialOutputs[0]] [first.state, other.state]
    other 0 0 other_genesis_ledger (by decide) rfl rfl (by decide) (by decide) rfl (by decide) rfl rfl
theorem second_genesis_ledger : LedgerObservationCorrespondence genesisWorld secondGenesisWorld secondGenesisTx
    [initialOutputs[1]] [second.state] 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_second_genesis_ledger : LedgerObservationCorrespondence otherGenesisWorld otherSecondGenesisWorld secondGenesisTx
    [initialOutputs[1]] [second.state] 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem second_genesis_reachable : CandidateReachable hash code commit release secondGenesisWorld := by
  exact .genesis genesis_reachable secondSeed secondGenesisTx [initialOutputs[1]] [second.state]
    second 0 0 second_genesis_ledger (by decide) rfl rfl (by decide) (by decide) rfl (by decide) rfl rfl
theorem other_second_genesis_reachable : CandidateReachable hash code commit otherRelease otherSecondGenesisWorld := by
  exact .neutral other_genesis_reachable secondGenesisTx [initialOutputs[1]] [second.state] 0 0
    other_second_genesis_ledger (by decide) (by decide) rfl rfl
theorem register_first_ledger : LedgerObservationCorrespondence secondGenesisWorld registeredFirst
    registerFirst.assets registerFirst.spentOutputs registerFirst.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_register_first_ledger : LedgerObservationCorrespondence otherSecondGenesisWorld otherRegisteredFirst
    registerFirst.assets registerFirst.spentOutputs registerFirst.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem registered_first_reachable : CandidateReachable hash code commit release registeredFirst := by
  exact .fold second_genesis_reachable registerFirst register_first_ledger (by decide) (by decide) rfl rfl
theorem other_registered_first_reachable : CandidateReachable hash code commit otherRelease otherRegisteredFirst := by
  exact .neutral other_second_genesis_reachable registerFirst.assets registerFirst.spentOutputs registerFirst.outputs
    0 0 other_register_first_ledger (by decide) (by decide) rfl rfl
theorem register_other_ledger : LedgerObservationCorrespondence registeredFirst registeredBoth
    registerOther.assets registerOther.spentOutputs registerOther.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_register_other_ledger : LedgerObservationCorrespondence otherRegisteredFirst otherRegisteredBoth
    registerOther.assets registerOther.spentOutputs registerOther.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem registered_both_reachable : CandidateReachable hash code commit release registeredBoth := by
  exact .neutral registered_first_reachable registerOther.assets registerOther.spentOutputs registerOther.outputs
    0 0 register_other_ledger (by decide) (by decide) rfl rfl
theorem other_registered_both_reachable : CandidateReachable hash code commit otherRelease otherRegisteredBoth := by
  exact .fold other_registered_first_reachable registerOther other_register_other_ledger (by decide) (by decide) rfl rfl
theorem booking_ledger : LedgerObservationCorrespondence registeredBoth booked bookingTx
    [active7, terminationApprovalInput] [pending] 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_booking_ledger : LedgerObservationCorrespondence otherRegisteredBoth otherBooked bookingTx
    [active7, terminationApprovalInput] [pending] 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem booked_reachable : CandidateReachable hash code commit release booked := by
  exact .neutral registered_both_reachable bookingTx [active7, terminationApprovalInput] [pending]
    0 0 booking_ledger (by decide) (by decide) rfl rfl
theorem other_booked_reachable : CandidateReachable hash code commit otherRelease otherBooked := by
  exact .neutral other_registered_both_reachable bookingTx [active7, terminationApprovalInput] [pending]
    0 0 other_booking_ledger (by decide) (by decide) rfl rfl
theorem termination_ledger : LedgerObservationCorrespondence booked terminated
    terminate.assets terminate.spentOutputs terminate.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_termination_ledger : LedgerObservationCorrespondence otherBooked otherTerminated
    terminate.assets terminate.spentOutputs terminate.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem terminated_reachable : CandidateReachable hash code commit release terminated := by
  exact .fold booked_reachable terminate termination_ledger (by decide) (by decide) rfl rfl
theorem other_terminated_reachable : CandidateReachable hash code commit otherRelease otherTerminated := by
  exact .neutral other_booked_reachable terminate.assets terminate.spentOutputs terminate.outputs
    0 0 other_termination_ledger (by decide) (by decide) rfl rfl
theorem remint_ledger : LedgerObservationCorrespondence terminated reminted
    remint.assets remint.spentOutputs remint.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem duplicate_ledger : LedgerObservationCorrespondence booked duplicated
    duplicate.assets duplicate.spentOutputs duplicate.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem foreign_burn_ledger : LedgerObservationCorrespondence booked foreignBurned
    foreignBurn.assets foreignBurn.spentOutputs foreignBurn.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem later_ledger : LedgerObservationCorrespondence terminated laterWorld
    later.assets later.spentOutputs later.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem later_reachable : CandidateReachable hash code commit release laterWorld := by
  exact .fold terminated_reachable later later_ledger (by decide) (by decide) rfl rfl
theorem other_later_ledger : LedgerObservationCorrespondence otherTerminated otherLaterWorld
    later.assets later.spentOutputs later.outputs 0 0 := by constructor <;> first | decide | exact finite_all (by decide)
theorem other_later_reachable : CandidateReachable hash code commit otherRelease otherLaterWorld := by
  exact .neutral other_terminated_reachable later.assets later.spentOutputs later.outputs
    0 0 other_later_ledger (by decide) (by decide) rfl rfl
theorem projection_trace_agrees :
    [initial, genesisWorld, secondGenesisWorld, registeredFirst, registeredBoth, booked, terminated, laterWorld].map (·.unspent) =
    [initial, otherGenesisWorld, otherSecondGenesisWorld, otherRegisteredFirst,
      otherRegisteredBoth, otherBooked, otherTerminated, otherLaterWorld].map (·.unspent) := by decide

theorem active_history_premise : HistoryPremises hash code commit release booked registerFirst.after 8 := by
  refine ⟨booked_reachable, by decide, ?_, ?_⟩
  · unfold FiniteEncoding; decide
  · unfold FiniteCollisionFree; decide
theorem terminal_history_premise : HistoryPremises hash code commit release terminated terminate.after 7 := by
  refine ⟨terminated_reachable, by decide, ?_, ?_⟩
  · unfold FiniteEncoding; decide
  · unfold FiniteCollisionFree; decide
theorem other_history_premise : HistoryPremises hash code commit otherRelease
    otherRegisteredBoth registerOther.after 7 := by
  refine ⟨other_registered_both_reachable, by decide, ?_, ?_⟩
  · unfold FiniteEncoding; decide
  · unfold FiniteCollisionFree; decide
theorem termination_history_premise : HistoryFoldPremises hash code commit release booked terminated terminate :=
  ⟨booked_reachable, termination_ledger, by decide, by decide, rfl, rfl⟩
theorem later_history_premise : HistoryFoldPremises hash code commit release terminated laterWorld later :=
  ⟨terminated_reachable, later_ledger, by decide, by decide, rfl, rfl⟩


end NoPin.ApplicationRequests.HistoryEvidence
