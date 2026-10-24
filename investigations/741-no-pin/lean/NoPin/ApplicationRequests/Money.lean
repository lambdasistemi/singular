import NoPin.ApplicationRequests.RefundLifecycleClaims
import NoPin.ApplicationRequests.Effects
import OpenDatumApplication.Model
import Singular.Economics
import Singular.Lemmas.RetractionWitness

/-! Hypothetical #741 comparisons, not accepted law. The old side calls the
accepted economic allocations, never a copy of their arithmetic. These are
gross request allocations and refund floors, not wallet wealth or fee quotes.
The old consumer's update law is separate from the economic transaction law.
The new public builder may allocate the whole residual to its caller; arbitrary
accepted transactions only constrain the deposit/refund floors and treasury.
-/
namespace NoPin.ApplicationRequests.Money
open Singular Lean

/-- Hypothesis under #741, not accepted law; stages separate booking from fold. -/
inductive Journey where
  | create | registrationBooking | registrationFold | update
  | terminationBooking | terminationFold | reclaim | cleanup
  | earlyRejection | unsupportedBooking | liveWithdrawal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; one independently credited party. -/
inductive Party where
  | pending | holding | refund | controller | folder | treasury
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; allocation extent excludes ordinary fee funding. -/
structure Allocation where
  pending : Nat := 0
  holding : Nat := 0
  refund : Nat := 0
  controller : Nat := 0
  folder : Nat := 0
  treasury : Nat := 0
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; total party interpretation. -/
def Allocation.at (a : Allocation) : Party → Nat
  | .pending => a.pending | .holding => a.holding | .refund => a.refund
  | .controller => a.controller | .folder => a.folder | .treasury => a.treasury
/-- Hypothesis under #741, not accepted law; accepted model inputs remain explicit. -/
structure Baseline where
  configuration : Config
  registration : Singular.RegistrationBooking
  termination : Singular.TerminationBooking
  protectedDeposit : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; isolated allocation decision sites. -/
inductive Site where
  | oldRegistrationTip | oldRegistrationCarrier | registrationResidual
  | terminationResidual | bookingTreasury | cleanupRefund | oldRefund | oldUpdateSigner
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; a selector changes one site in one layer. -/
inductive Mutation where
  | none | application (site : AppGuard) | allocation (site : Site)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; an allocation mutant changes one amount by one. -/
def amountAt (m : Mutation) (site : Site) (value : Nat) : Nat :=
  if m == .allocation site then value + 1 else value
/-- Hypothesis under #741, not accepted law; no allocation selector changes an application guard. -/
def appMutation : Mutation → AppMutation
  | .application site => .flip site | _ => .none
/-- Hypothesis under #741, not accepted law; calls the accepted producer definitions.
There is no protected-deposit allocation in the economic termination judgement;
the retained application law has a separate release rule, never composed here. -/
def oldAllocation (m : Mutation) (journey : Journey) (b : Baseline) : Allocation :=
  match journey with
  | .registrationBooking => { pending := registrationDeclaredLovelace b.registration.request }
  | .registrationFold =>
    let obligations := foldObligations [.registration b.registration]
    { holding := amountAt m .oldRegistrationCarrier obligations.carriers,
      folder := amountAt m .oldRegistrationTip obligations.tips, treasury := obligations.donation }
  | .terminationBooking => { pending := terminationDeclaredLovelace b.termination.request }
  | .terminationFold =>
    let obligations := foldObligations [.termination b.termination]
    { folder := obligations.tips, treasury := obligations.donation }
  | .reclaim | .cleanup | .earlyRejection =>
    { refund := amountAt m .oldRefund (refundAmount b.registration.request (journey == .reclaim)),
      folder := if journey == .reclaim then 0 else b.registration.request.declaredTip }
  | .update => { holding := b.protectedDeposit }
  | _ => {}
/-- Hypothesis under #741, not accepted law; publicly observed current request and deposit. -/
structure Input where
  lifecycle : RefundLifecycle.Input
  baseline : Baseline
  registration : PendingRequest
  termination : PendingRequest
  deposit : Nat
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; the new allocations follow actual ADA.
For folds these are the maximum request allocation the constructive public builder
pays to ordinary outputs; they are not required payments to a named signer. -/
def newAllocation (m : Mutation) (journey : Journey) (q : Input) : Allocation :=
  match journey with
  | .registrationBooking => { pending := q.registration.output.lovelace }
  | .registrationFold => { holding := q.deposit, folder := amountAt m .registrationResidual q.registration.bid }
  | .terminationBooking => { pending := q.termination.output.lovelace, treasury := amountAt m .bookingTreasury q.deposit }
  | .terminationFold => { folder := amountAt m .terminationResidual q.termination.bid }
  | .reclaim => { refund := q.registration.output.lovelace }
  | .cleanup => { refund := amountAt m .cleanupRefund q.deposit, folder := q.registration.output.lovelace - q.deposit }
  | .update => { holding := q.deposit }
  | _ => {}
/-- Hypothesis under #741, not accepted law; each intentional change names its ruling. -/
inductive Ruling where
  | valueIsBid | treasuryAtTerminationBooking | noTreasuryAtFold | threePhases
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; fixed semantic disposition, not amount-selected tags. -/
def rulingFor : Journey → Party → Option Ruling
  | .registrationFold, .folder | .terminationFold, .folder => some .valueIsBid
  | .registrationFold, .treasury | .terminationFold, .treasury => some .noTreasuryAtFold
  | .terminationBooking, .treasury => some .treasuryAtTerminationBooking
  | .cleanup, .refund | .cleanup, .folder => some .threePhases
  | .earlyRejection, .refund | .earlyRejection, .folder => some .threePhases
  | _, _ => none
/-- Hypothesis under #741, not accepted law; complete correspondence, including all used clocks.
The old cost/tip fields have no new admission meaning. No equality of admissions
or cryptographic identities is asserted by this amount correspondence. -/
abbrev Correspondence (q : Input) : Prop :=
  q.registration.output.lovelace = q.baseline.registration.request.contents.lovelace ∧
  q.termination.output.lovelace = q.baseline.termination.request.contents.lovelace ∧
  q.deposit = q.baseline.registration.request.carrierAda ∧
  q.deposit = q.baseline.protectedDeposit ∧
  q.baseline.registration.request.contents.lovelace =
    q.baseline.registration.request.registrationCost + q.baseline.registration.request.declaredTip + q.deposit ∧
  q.baseline.termination.request.contents.lovelace =
    q.baseline.termination.request.declaredTip + q.baseline.termination.request.carrierAda ∧
  (match q.registration with
   | .registration _ data => data.deposit = q.deposit ∧
       data.refundAddress = q.baseline.registration.request.refundAddress ∧
       data.key = q.baseline.registration.request.key ∧
       data.holdingAddress = q.baseline.registration.request.destination ∧
       q.baseline.registration.request.datum = some data.initialDatum ∧
       data.bookedAt = q.baseline.registration.request.submittedAt ∧
       data.processDeadline = data.bookedAt + q.baseline.configuration.processTime ∧
       data.reclaimEnd = data.processDeadline + q.baseline.configuration.retractTime
   | _ => False) ∧
  (match q.termination with | .termination _ _ key => key = q.baseline.termination.request.key | _ => False)
/-- Hypothesis under #741, not accepted law; constructive finite decoding cases. -/
instance (q : Input) : Decidable (Correspondence q) := by
  cases q with
  | mk lifecycle baseline registration termination deposit =>
    cases registration <;> cases termination <;> unfold Correspondence <;> infer_instance
/-- Hypothesis under #741, not accepted law; exact old/new equations, not a blanket equivalence. -/
abbrev Difference (m : Mutation) (journey : Journey) (party : Party) (q : Input) : Prop :=
  let old := (oldAllocation m journey q.baseline).at party
  let new := (newAllocation m journey q).at party
  match rulingFor journey party with
  | none => old = new
  | some .valueIsBid => match journey with
    | .registrationFold => new = old + q.baseline.registration.request.registrationCost
    | .terminationFold => new = old + q.baseline.termination.request.carrierAda
    | _ => False
  | some .treasuryAtTerminationBooking => old = 0 ∧ new = q.deposit
  | some .noTreasuryAtFold => new = 0 ∧ old =
      (if journey == .registrationFold then q.baseline.registration.request.registrationCost
       else q.baseline.termination.request.carrierAda)
  | some .threePhases => match journey, party with
    | .cleanup, .refund => old = new + q.baseline.registration.request.registrationCost
    | .cleanup, .folder => new = old + q.baseline.registration.request.registrationCost
    | .earlyRejection, .refund => new = 0 ∧ old =
        q.baseline.registration.request.registrationCost + q.deposit
    | .earlyRejection, .folder => new = 0 ∧ old = q.baseline.registration.request.declaredTip
    | _, _ => False
/-- Hypothesis under #741, not accepted law; constructive interpretation of every party/stage cell. -/
instance (m : Mutation) (journey : Journey) (party : Party) (q : Input) :
    Decidable (Difference m journey party q) := by
  cases journey <;> cases party <;> unfold Difference rulingFor <;> infer_instance
/-- Hypothesis under #741, not accepted law; the domain is discovered by the compiled report. -/
abbrev AllDifferences (m : Mutation) (journey : Journey) (q : Input) : Prop :=
  ∀ party, Difference m journey party q
/-- Hypothesis under #741, not accepted law; owner signature and exactly the same protected fields.
This comparison calls the retained consumer, rather than defining an old update. -/
def oldUpdate (m : Mutation) (world : OpenDatumApplication.World) (reference : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat) :=
  OpenDatumApplication.updateStep
    { OpenDatumApplication.Law.standard with checkUpdateSigner := amountAt m .oldUpdateSigner 0 == 0 }
    world reference successors signers
/-- Hypothesis under #741, not accepted law; execute the accepted retraction judgement
on its coherent witness transaction with this observation's actual signers and interval.
The witness builder supplies outputs; it is not an observed ledger transaction. -/
def oldReclaim (q : Input) : Except String Bool := do
  let initial : Singular.World := ⟨⟨{ q.baseline.configuration with root := rootOf [] }, [], [], []⟩, [], [], 0⟩
  let world ← Singular.book initial q.baseline.registration
  let funding := q.lifecycle.query.funding.ordinaryInput.lovelace
  let fee := q.lifecycle.query.funding.fee
  return (retractionAccepted world (terminationWitnessUnspent world funding)
    (retractionWitnessTransaction world q.baseline.registration q.lifecycle.observation.interval
      q.lifecycle.observation.signers funding fee)).isOk
/-- Hypothesis under #741, not accepted law; a genuine old mismatch rejection.
The trace registers the key through step, books the second request through book,
then judges a coherent reference-state transaction. Fees/minimums remain unmodelled. -/
def oldRejection (q : Input) : Except String Bool := do
  let c := q.baseline.configuration
  let r := q.baseline.registration.request
  let approval : Approval := {
    policy := c.applicationPolicy, edge := .insertActive, key := r.key, owner := r.refundAddress,
    destination := r.destination, assetName := approvalAssetName .insertActive r.key r.refundAddress r.destination }
  let legacy : Request := {
    edge := .insertActive, key := r.key, owner := r.refundAddress, output := r.destination,
    datum := r.datum, approval := some approval, claimed := delta .insertActive }
  let initial : RegistryState := ⟨{ c with root := rootOf [] }, [], [], []⟩
  let registered ← Singular.step initial legacy
  let world ← Singular.book ⟨registered.state, [], [], 0⟩ q.baseline.registration
  let unspent := terminationWitnessUnspent world 0
  let stateRef : OutRef := ⟨terminationWitnessFresh world, 0⟩
  let refund := { foldWitnessOrdinary (refundAmount r false) with
    output.address := some r.refundAddress }
  let reward := { foldWitnessOrdinary r.declaredTip with
    output.address := some q.lifecycle.query.funding.processorAddress }
  let outputs := [refund, reward]
  let tx : EconomicTransaction := {
    transaction := {
      inputs := [foldWitnessInput r.reference], referenceInputs := [foldWitnessInput stateRef],
      outputs := outputs.map (·.output), mint := [], signers := [], refunds := [],
      validity := some q.lifecycle.observation.interval, fee := 0, donation := 0 },
    identity := terminationWitnessFresh world + 1, outputs,
    trieReadyMint := r.contents.trieReadyTags.map (fun asset => (asset, -1)),
    applicationMint := r.contents.applicationTags.map (fun tag => (applicationTagIdentity tag, -1)) }
  return (rejectionAccepted world unspent ⟨tx, stateRef, [(r.reference, .mismatch (.known .active))]⟩).isOk
/-- Hypothesis under #741, not accepted law; the generic oracle calls allocation definitions only. -/
inductive Surface where
  | oldAllocation | newAllocation | applicationStep | oldReclaim | oldRejection
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; no theorem or expected result is an input. -/
structure Scenario where
  surface : Surface
  journey : Journey
  input : Input
  mutation : Mutation
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; explicit finite interpretation, with malformed inputs refused. -/
def runScenario (s : Scenario) : Except String Json := do
  let q := s.input.lifecycle.query
  unless wellFormed q do throw "incomplete-money-observation"
  match s.surface with
  | .oldAllocation => return toJson (oldAllocation s.mutation s.journey s.input.baseline)
  | .newAllocation => return toJson (newAllocation s.mutation s.journey s.input)
  | .applicationStep => return toJson (RefundApplication.applicationStep (appMutation s.mutation) (NoPin.lookupHash q.hashes)
      (queryCode q) (queryDecode q) q.release s.input.lifecycle.observation)
  | .oldReclaim => return toJson (← oldReclaim s.input)
  | .oldRejection => return toJson (← oldRejection s.input)

end NoPin.ApplicationRequests.Money
