import Singular.Economics.Rejection

/-! A registration's refund address may reclaim it inside its booked window.
This judges observed transactions and never calls the legacy retraction. -/

namespace Singular

def retractionInputsRefusal (u : EconomicUtxo) (tx : EconomicTransaction) : Option String :=
  if (spentOutputs u.ledger tx.transaction).any (fun o => o.stateTokens > 0 || o.role == .state)
  then some "retract-state-spent"
  else if (u.filter fun p => inputsContainReference tx.transaction.referenceInputs p.1).any
      (fun p => p.2.output.stateTokens > 0 || p.2.output.role == .state)
  then some "retract-state-read"
  else if ¬ (tx.transaction.inputs.map (·.ref)).Nodup then some "retract-duplicate-input"
  else if !disjointInputs tx.transaction then some "retract-input-overlap"
  else inputPresenceRefusal u.ledger tx.transaction

def retractionRequest (world : World) (tx : EconomicTransaction) :
    Except String RegistrationRequest := do
  let [input] := tx.transaction.inputs | throw "retract-single-request"
  let some reference := input.ref | throw "spent-input-missing"
  match world.pending.find? (fun b => b.request.reference == reference) with
  | some booking => pure booking.request
  | none =>
    if world.terminations.any (fun b => b.request.reference == reference)
    then throw "retract-registration-only"
    else throw "retract-request-not-pending"

def retractionRefusal (world : World) (u : EconomicUtxo)
    (tx : EconomicTransaction) : Option String := do
  if let some why := retractionInputsRefusal u tx then return why
  if let some why := economicObservationRefusal world u tx then return why
  match retractionRequest world tx with
  | .error why => return why
  | .ok request =>
    if !(tx.transaction.signers.contains request.refundAddress) then return "retract-owner"
    let some interval := tx.transaction.validity | return "retract-interval-missing"
    if ¬ interval.valid then return "retract-interval-empty"
    if interval.lower < request.submittedAt + world.registry.config.processTime ||
        request.submittedAt + world.registry.config.processTime + world.registry.config.retractTime <
          interval.upper then return "retract-window"
    if !requestTagsBurned u tx then return "retract-tag-not-burned"
    if !rejectionSupplyUnchanged u tx then return "retract-registry-supply"
    if let some why := refundRefusal tx (refundObligations [request] true) "retract-refund-short"
      then return why
    none

def retractionEffect (world : World) (tx : EconomicTransaction) : World :=
  { world with pending := world.pending.filter fun b =>
      !inputsContainReference tx.transaction.inputs b.request.reference }

def retractionAccepted (world : World) (u : EconomicUtxo)
    (tx : EconomicTransaction) : Except String World :=
  match retractionRefusal world u tx with
  | some why => .error why
  | none => .ok (retractionEffect world tx)

theorem retractionAccepted_effect {world after : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : retractionAccepted world u tx = .ok after) :
    after = retractionEffect world tx := by
  unfold retractionAccepted at accepted
  split at accepted
  · contradiction
  · cases accepted; rfl

end Singular
