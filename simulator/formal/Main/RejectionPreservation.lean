import Main.RejectionTransactions

/-! Production traces for the preservation statements. These execute the
existing fold judgement and the actual economic rejection, never a stand-in. -/

open Singular

namespace RejectionReadControls

def preservationTrace : Except String Unit := do
  let before ← world
  let row := lawful before "reject a mismatch before a disjoint fold" [registration 5 0]
    [.mismatch (.known .active)] ⟨102, 103⟩
  let u := observedUnspent before row.unspent
  let tx := observedTransaction row
  let request := { req .insertActive 6 42 555 with submittedAt := 102, claimed := [(.active, 1)] }
  let witness : FoldWitness := ⟨110⟩
  let foldBefore ← admittedFoldBatch before.registry [request] witness
  let after ← rejectionAccepted before u ⟨tx, stateReference, row.members⟩
  let foldAfter ← admittedFoldBatch after.registry [request] witness
  if foldBefore != foldAfter then throw "rejection-changed-valid-fold"
  let updated := applyEconomicTransaction u tx
  for ref in [stateReference, (registration 6 1).request.reference] do
    let some output := economicLookup u ref | throw "fold-input-absent-before"
    if economicLookup updated ref != some output then throw "rejection-consumed-fold-input"
  if (economicLookup updated (registration 5 0).request.reference).isSome then
    throw "rejected-input-survived"
  -- Booking after rejection exercises the new world path without inventing
  -- an economic fold constructor that belongs to the subsequent design slice.
  let booked ← book after (registration 7 4)
  if booked.registry != before.registry || booked.terminations != before.terminations then
    throw "booking-after-rejection-changed-registry"
  pure ()

def sweepTrace : Except String Unit := do
  let before ← world
  let row : Control := {
    story := "an application tag alone does not make a stray output a request",
    unspent := unspent before,
    transaction := { transaction [] ⟨102, 103⟩ with inputs := [input ⟨73, 0⟩], referenceInputs := [] },
    members := [], trieReadyBurns := [], applicationBurns := [], sweep := true, expected := none }
  let u := (observedUnspent before row.unspent).map fun (ref, output) =>
    (ref, if ref = (⟨73, 0⟩ : OutRef) then
      { output with contents.applicationTags := (registration 5 0).request.contents.applicationTags }
      else output)
  let after ← sweepAccepted before u (observedTransaction row)
  if after != before then throw "sweep-changed-pools"
  pure ()

def runPreservationControls : IO (List Lean.Json) := do
  let rows := [
    ("a rejection preserves a valid fold and every needed output, and booking can follow", preservationTrace),
    ("a stray output with an application tag and no trie-ready tag can be swept", sweepTrace)]
  let mut output := []
  for (story, result) in rows do
    if let .error why := result then throw (IO.userError s!"{story}: {why}")
    let actual : Option String := match result with | .ok _ => none | .error why => some why
    output := output ++ [Lean.Json.mkObj [
      ("story", Lean.toJson story), ("expectedReason", Lean.toJson (none : Option String)),
      ("actualReason", Lean.toJson actual), ("matched", Lean.toJson actual.isNone)]]
  pure output

end RejectionReadControls
