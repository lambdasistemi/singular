import Main.FoldFixtures

/-! The economic fold contract, recorded before its judgement exists. Missing
admission is reported separately for every transaction; the legacy fold and
an absent symbol are never used as a substitute behavioral refusal. -/

open Singular

namespace FoldControls

def controls : Except String (List Control) := do
  let w ← world
  let one ← lawful w "a registration inside its window routes every amount" [⟨71, 1⟩] 102
  let late ← lawful w "a booked termination folds at a later time without a window" [⟨72, 0⟩] 1000000
  let mixed ← lawful w "a registration and a booked termination fold together" [⟨71, 1⟩, ⟨72, 0⟩] 102
  let several ← lawful w "three registrations donate the cost of every key"
    [⟨71, 1⟩, ⟨71, 2⟩, ⟨71, 3⟩] 102
  let boundary ← lawful w "a registration may reach its excluded processing deadline" [⟨71, 1⟩] 111
  let tooLate ← lawful w "a registration past its processing deadline is refused" [⟨71, 1⟩] 112
  let omittedDonation := changeOrdinary
    { several with transaction.transaction.donation := several.transaction.transaction.donation - 17 } 17
  let feeFromRequest := changeOrdinary
    { one with transaction.transaction.inputs :=
        one.transaction.transaction.inputs.filter (fun i => i.ref != some fundingReference) } (-10)
  let shortCarrier := changeOrdinary (changeCarrier one (-1)) 1
  let longCarrier := changeOrdinary (changeCarrier one 1) (-1)
  let amount (c : Control) (d : Int) (story reason : String) :=
    { changeOrdinary c d with story, expected := some reason }
  let donatedTip := changeOrdinary
    { one with transaction.transaction.donation := one.transaction.transaction.donation + 1 } (-1)
  let liveTrie := withOutputs { one with transaction.trieReadyMint := [] }
    (one.transaction.outputs.map fun o =>
      if o.output.stateTokens == 0 && o.singularTags.isEmpty then
        { o with contents.trieReadyTags := (RejectionReadControls.registration 6 1).request.contents.trieReadyTags }
      else o)
  let liveApplication := withOutputs { one with transaction.applicationMint := [] }
    (one.transaction.outputs.map fun o =>
      if o.output.stateTokens == 0 && o.singularTags.isEmpty then
        { o with contents.applicationTags := (RejectionReadControls.registration 6 1).request.contents.applicationTags }
      else o)
  let liveSingular := withOutputs { late with transaction.singularMint := [] }
    (late.transaction.outputs.map fun o =>
      if o.output.stateTokens == 0 then
        { o with singularTags := w.terminations.flatMap (·.request.singularTags) }
      else o)
  let multiOrdinary := withOutputs one
    (one.transaction.outputs.filter (fun o => o.output.stateTokens > 0 || !o.singularTags.isEmpty) ++
      [ordinary 555 5, ordinary 999 7])
  let wrongDatum := withOutputs one (one.transaction.outputs.map fun o =>
    if !o.singularTags.isEmpty then { o with output.datumValue := some 900 } else o)
  let wrongAddress := withOutputs one (one.transaction.outputs.map fun o =>
    if !o.singularTags.isEmpty then { o with output.address := some 999 } else o)
  let wrongState := withOutputs one (one.transaction.outputs.map fun o =>
    if o.output.stateTokens > 0 then { o with output.config := some w.registry.config } else o)
  let stateLoss := changeOrdinary (withOutputs one (one.transaction.outputs.map fun o =>
    if o.output.stateTokens > 0 then
      { o with output.lovelace := o.output.lovelace - 1, contents.lovelace := o.contents.lovelace - 1 }
    else o)) 1
  let observedTag := (RejectionReadControls.registration 6 1).request.contents.applicationTags
  let forged := changeApplication one (observedTag.map fun tag => { tag with assetName := tag.assetName + 1 })
  pure [one, late, mixed, several, boundary,
    { multiOrdinary with
      story := "several ordinary outputs at different addresses share the reward" },
    { one with
      story := "the processor and destination may use the same address in separate outputs" },
    { tooLate with expected := some "not-phase1" },
    { mixed with
      story := "one expired registration refuses the mixed transaction",
      transaction.transaction.validity := some ⟨112, 113⟩, expected := some "not-phase1" },
    { omittedDonation with
      story := "one donation cannot be counted for several registrations",
      expected := some "fold-donation-mismatch" },
    { changeApplication one [] with
      story := "a missing observed application tag is refused",
      expected := some "request-observation-mismatch" },
    { forged with
      story := "a forged observed application tag is refused",
      expected := some "request-observation-mismatch" },
    amount one 1 "a fold cannot create lovelace" "fold-unbalanced",
    amount one (-1) "a fold cannot destroy lovelace" "fold-unbalanced",
    { feeFromRequest with
      story := "the ledger fee cannot come from the request",
      expected := some "fold-fee-funding-short" },
    { donatedTip with
      story := "the processor cannot donate part of the declared tip",
      expected := some "fold-donation-mismatch" },
    { shortCarrier with
      story := "the processor cannot take part of the declared carrier",
      expected := some "destination-carrier-mismatch" },
    { longCarrier with
      story := "the carrier cannot absorb processor change or part of the tip",
      expected := some "destination-carrier-mismatch" },
    { liveTrie with
      story := "a fold cannot carry a trie-ready tag out alive",
      expected := some "fold-tag-not-burned" },
    { liveApplication with
      story := "a fold cannot carry an application tag out alive",
      expected := some "fold-tag-not-burned" },
    { liveSingular with
      story := "a termination cannot keep its singular tag alive",
      expected := some "fold-singular-mismatch" },
    { one with
      story := "a tagged request cannot be spent through the sweep arm", sweep := true,
      transaction.transaction.inputs := [RejectionReadControls.input ⟨71, 1⟩],
      expected := some "request-tagged-sweep" },
    { one with
      story := "a request cannot be consumed twice",
      transaction.transaction.inputs := RejectionReadControls.input ⟨71, 1⟩ :: one.transaction.transaction.inputs,
      expected := some "fold-duplicate-input" },
    { one with
      story := "a fold must spend the registry state output",
      transaction.transaction.inputs := one.transaction.transaction.inputs.filter
        (fun i => i.ref != some RejectionReadControls.stateReference), expected := some "fold-state-missing" },
    { wrongDatum with
      story := "a destination must carry the booked datum", expected := some "fold-destination-mismatch" },
    { wrongAddress with
      story := "the singular tag must reach the booked destination", expected := some "fold-destination-mismatch" },
    { wrongState with
      story := "the continued state must contain the registry fold result", expected := some "fold-state-mismatch" },
    { stateLoss with
      story := "the processor cannot take state continuation value", expected := some "fold-state-value-mismatch" },
    { one with
      story := "a claimed funding amount cannot replace the observed funding",
      transaction.transaction.inputs := one.transaction.transaction.inputs.map fun i =>
        { i with lovelace := 999999 } },
    { late with
      story := "termination admission does not read an expiry clock",
      transaction.transaction.validity := some ⟨1000000000, 1000000001⟩ }]

/-- Execute the existing sweep arm; explicitly report every missing economic
fold judgement. Returning failure records an unevaluated contract, not a claim
that its future economic refusal has executed. -/
def runRed : IO Unit := do
  let rows ← match controls with
    | .error why => throw (IO.userError s!"fold booking trace failed: {why}")
    | .ok rows => pure rows
  let stdout ← IO.getStdout
  let mut missing := 0
  let mut mismatches := 0
  for row in rows do
    if row.sweep then
      let actual := match sweepAccepted row.world row.unspent row.transaction with
        | .error why => some why | .ok _ => none
      unless actual == row.expected do mismatches := mismatches + 1
      stdout.putStrLn s!"EXECUTED {row.story}: expected={repr row.expected} actual={repr actual}"
    else
      missing := missing + 1
      stdout.putStrLn s!"COULD-NOT-EVALUATE {row.story}: expected={repr row.expected}; economic fold judgement absent"
    if row.expected.isNone then
      unless balanced row.unspent.ledger row.transaction.transaction do
        throw (IO.userError s!"lawful fixture does not conserve its ledger projection: {row.story}")
  stdout.putStrLn s!"fold controls: {rows.length} transactions; {missing} unevaluated; {mismatches} executed mismatches"
  if missing > 0 || mismatches > 0 then
    throw (IO.userError "economic fold contract is not implemented")

end FoldControls
