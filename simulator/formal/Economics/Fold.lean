import Singular.Economics.Retraction
import Singular.Economics.FoldRouting

/-! Economic fold admission over observed transactions. Legacy foldAdmission
is never called: a booked termination has no processing window. -/

namespace Singular

def foldMemberRefusal (c : Config) (interval : Interval) (member : FoldMember) : Option String :=
  match member with
  | .registration b =>
    if interval.lower < b.request.submittedAt ||
        !inPhase1 c b.request.submittedAt interval.upper then some "not-phase1"
    else none
  | .termination _ => none

def foldPrerequisite (world : World) (u : EconomicUtxo) (tx : EconomicTransaction) : Option String := do
  if ¬ (tx.transaction.inputs.map (·.ref)).Nodup then return "fold-duplicate-input"
  if !disjointInputs tx.transaction then return "fold-input-overlap"
  if let some why := inputPresenceRefusal u.ledger tx.transaction then return why
  if let some why := economicObservationRefusal world u tx then return why
  let members := foldMembers world tx
  if members.isEmpty then return "empty-fold"
  let some interval := tx.transaction.validity | return "fold-interval-missing"
  if ¬ interval.valid then return "fold-interval-empty"
  if let some why := members.findSome? (foldMemberRefusal world.registry.config interval) then return why
  if !(u.all fun p =>
      !inputsContainReference tx.transaction.inputs p.1 ||
      (foldMemberAt world p.1).isSome || p.2.output.stateTokens > 0 || foldOrdinary p.2) then
    return "fold-unrecognized-input"
  none

def foldEffect (world : World) (tx : EconomicTransaction) (result : Result) : World :=
  { registry := foldRegistryEffect world tx result,
    pending := world.pending.filter fun b =>
      !inputsContainReference tx.transaction.inputs b.request.reference,
    terminations := foldRemainingTerminations world tx,
    treasury := world.treasury + tx.transaction.donation }

/-- Atomic admission: observations and economic request rules precede the
registry transition, then exact routing and conservation judge the outputs.
The synthetic legacy approval is not economic authorization or admission. -/
def foldAccepted (world : World) (u : EconomicUtxo) (tx : EconomicTransaction) : Except String World :=
  match foldPrerequisite world u tx with
  | some why => .error why
  | none =>
    match foldBatch (foldProjectedRegistry world)
        ((foldMembers world tx).map (foldLegacyRequest world.registry.config)) with
    | .error why => .error why
    | .ok result =>
      match foldRoutingRefusal world u tx result with
      | some why => .error why
      | none => .ok (foldEffect world tx result)

end Singular
