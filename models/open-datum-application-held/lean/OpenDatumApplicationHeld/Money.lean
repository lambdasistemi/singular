import OpenDatumApplicationHeld.RefundLifecycleClaims
import SingularApplicationHeld.Effects
import OpenDatumApplication.Model
import Singular.Economics


namespace OpenDatumApplicationHeld.Money
open Singular Lean SingularApplicationHeld


inductive Journey where
  | create | registrationBooking | registrationFold | update
  | terminationBooking | terminationFold | reclaim | cleanup
  | earlyRejection | unsupportedBooking | liveWithdrawal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Party where
  | pending | holding | refund | controller | folder | treasury
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Allocation where
  pending : Nat := 0
  holding : Nat := 0
  refund : Nat := 0
  controller : Nat := 0
  folder : Nat := 0
  treasury : Nat := 0
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def Allocation.at (a : Allocation) : Party → Nat
  | .pending => a.pending | .holding => a.holding | .refund => a.refund
  | .controller => a.controller | .folder => a.folder | .treasury => a.treasury

structure Baseline where
  configuration : Config
  registration : Singular.RegistrationBooking
  termination : Singular.TerminationBooking
  protectedDeposit : Nat
  deriving BEq, DecidableEq, ToJson, FromJson

inductive Site where
  | oldRegistrationTip | oldRegistrationCarrier | registrationResidual
  | terminationResidual | bookingTreasury | cleanupRefund | oldRefund | oldUpdateSigner
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Mutation where
  | none | application (site : AppGuard) | allocation (site : Site)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def amountAt (m : Mutation) (site : Site) (value : Nat) : Nat :=
  if m == .allocation site then value + 1 else value

def appMutation : Mutation → AppMutation
  | .application site => .flip site | _ => .none

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

structure Input where
  lifecycle : RefundLifecycle.Input
  baseline : Baseline
  registration : PendingRequest
  termination : PendingRequest
  deposit : Nat
  deriving ToJson, FromJson

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

inductive Ruling where
  | valueIsBid | treasuryAtTerminationBooking | noTreasuryAtFold | threePhases
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def rulingFor : Journey → Party → Option Ruling
  | .registrationFold, .folder | .terminationFold, .folder => some .valueIsBid
  | .registrationFold, .treasury | .terminationFold, .treasury => some .noTreasuryAtFold
  | .terminationBooking, .treasury => some .treasuryAtTerminationBooking
  | .cleanup, .refund | .cleanup, .folder => some .threePhases
  | .earlyRejection, .refund | .earlyRejection, .folder => some .threePhases
  | _, _ => none

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
       data.holdingAddress.paymentCredential = q.baseline.registration.request.destination ∧
       q.baseline.registration.request.datum = some data.initialDatum ∧
       data.bookedAt = q.baseline.registration.request.submittedAt ∧
       data.processDeadline = data.bookedAt + q.baseline.configuration.processTime ∧
       data.reclaimEnd = data.processDeadline + q.baseline.configuration.retractTime
   | _ => False) ∧
  (match q.termination with | .termination _ _ key => key = q.baseline.termination.request.key | _ => False)

instance (q : Input) : Decidable (Correspondence q) := by
  cases q with
  | mk lifecycle baseline registration termination deposit =>
    cases registration <;> cases termination <;> unfold Correspondence <;> infer_instance

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

instance (m : Mutation) (journey : Journey) (party : Party) (q : Input) :
    Decidable (Difference m journey party q) := by
  cases journey <;> cases party <;> unfold Difference rulingFor <;> infer_instance

abbrev AllDifferences (m : Mutation) (journey : Journey) (q : Input) : Prop :=
  ∀ party, Difference m journey party q

def oldUpdate (m : Mutation) (world : OpenDatumApplication.World) (reference : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat) :=
  OpenDatumApplication.updateStep
    { OpenDatumApplication.Law.standard with checkUpdateSigner := amountAt m .oldUpdateSigner 0 == 0 }
    world reference successors signers

end OpenDatumApplicationHeld.Money
