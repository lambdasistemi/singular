import Singular.Economics.Rejection

/-! The request address's spend prerequisite. Full economic fold and
retraction admission is not implemented here. Their named arms check tag
disposal only; they never return an accepted world. -/

namespace Singular

inductive RequestExit where
  | fold | retraction | rejection
  deriving BEq, DecidableEq

/-- An absent trie-ready tag makes this output freely spendable at the request
address. A tagged output requires an exit and the whole transaction's exact
tag burns. This is a validator prerequisite, not full exit or ledger admission. -/
def requestAddressSpend (u : EconomicUtxo) (tx : EconomicTransaction)
    (reference : OutRef) (exit : Option RequestExit) : Option String :=
  if !inputsContainReference tx.transaction.inputs reference then some "request-input-missing"
  else match economicLookup u reference with
  | none => some "spent-input-missing"
  | some output =>
    if output.output.role != .request then some "not-request-address"
    else if output.contents.trieReadyTags.isEmpty then none
    else if exit.isNone then some "request-tagged-sweep"
    else if !requestTagsBurned u tx then some "request-tag-not-burned"
    else none

/-- Sweeping cannot remove a booked request from either pool. The observed
unspent set must agree with all pending requests before the sweep is judged.
Ledger balance and other scripts remain obligations outside this address gate. -/
def sweepAccepted (world : World) (u : EconomicUtxo)
    (tx : EconomicTransaction) : Except String World := do
  if let some why := inputPresenceRefusal u.ledger tx.transaction then throw why
  if let some why := economicObservationRefusal world u tx then throw why
  if ¬ (tx.transaction.inputs.map (·.ref)).Nodup then throw "request-duplicate-input"
  if !disjointInputs tx.transaction then throw "request-input-overlap"
  for input in tx.transaction.inputs do
    let some ref := input.ref | throw "spent-input-missing"
    if let some why := requestAddressSpend u tx ref none then throw why
  pure world

end Singular
