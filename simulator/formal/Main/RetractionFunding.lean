import Main.Refunds

/-! A requester funds a retraction's ledger fee while retaining the whole
request refund. These are model transactions, with production booking traces;
the amounts are illustrative and say nothing about ledger minimums. -/

open Singular

namespace RetractionFundingControls

def fundingReference : OutRef := ⟨74, 0⟩

def funded (world : World) : RefundControls.Control :=
  let original := RefundControls.retraction world
  { original with
    story := "ordinary wallet funding pays a positive retraction fee",
    unspent := original.unspent ++ [(fundingReference, RefundControls.payment 42 7)],
    transaction.transaction.inputs := original.transaction.transaction.inputs ++
      [RejectionReadControls.input fundingReference],
    transaction.transaction.fee := 7 }

def changeFunding (row : RefundControls.Control) (story : String)
    (change : EconomicOutput → EconomicOutput) (reason : String) : RefundControls.Control :=
  { row with
    story,
    unspent := row.unspent.map fun (reference, output) =>
      (reference, if reference == fundingReference then change output else output),
    expected := some reason }

def controls (world : World) : List RefundControls.Control :=
  let row := funded world
  let request := (RefundControls.registration 6 1 42).request
  let extra := RefundControls.withPayments row.transaction
    [RefundControls.payment 42 request.contents.lovelace, RefundControls.payment 42 3]
  let more := { row with
    story := "ordinary surplus returns to the requester as separate change",
    unspent := row.unspent.map fun (reference, output) =>
      (reference, if reference == fundingReference then RefundControls.payment 42 10 else output),
    transaction := extra }
  [row, more,
   { row with
     story := "funding may precede the pending registration",
     transaction.transaction.inputs := row.transaction.transaction.inputs.reverse },
   { row with
     story := "the ledger fee cannot exceed ordinary funding by one lovelace",
     transaction.transaction.fee := 8, expected := some "retract-fee-funding-short" },
   { row with
     story := "a claimed input amount does not fund the fee",
     transaction.transaction.inputs := row.transaction.transaction.inputs.map fun input =>
       { input with lovelace := 1000000 },
     transaction.transaction.fee := 8, expected := some "retract-fee-funding-short" },
   changeFunding row "funding holding a state token is refused"
     (fun output => { output with
       output.stateTokens := 1,
       output.stateToken := some world.registry.config.stateToken }) "retract-state-spent",
   changeFunding row "a state output without its token is still not funding"
     (fun output => { output with output.role := .state }) "retract-state-spent",
   changeFunding row "funding holding a trie-ready tag is refused"
     (fun output => { output with contents.trieReadyTags := request.contents.trieReadyTags })
     "retract-funding-trie-ready-tag",
   changeFunding row "funding holding an application tag is refused"
     (fun output => { output with contents.applicationTags := request.contents.applicationTags })
     "retract-funding-application-tag",
   changeFunding row "funding holding a singular tag is refused"
     (fun output => { output with singularTags := [world.registry.config.singularTag 5] })
     "retract-funding-singular-tag",
   changeFunding row "an untagged output at the request address is not funding"
     (fun output => { output with output.role := .request }) "retract-funding-request-address",
   changeFunding row "an output carrying another request datum is not funding"
     (fun output => { output with request := some (.registration request) })
     "retract-funding-request",
   changeFunding row "ordinary funding cannot carry an unrelated native asset"
     (fun output => { output with contents.otherAssets := [(⟨91, 92⟩, 1)] })
     "retract-foreign-asset",
   { more with
     story := "ordinary change cannot carry an unrelated native asset",
     transaction := RefundControls.withPayments more.transaction
       [RefundControls.payment 42 request.contents.lovelace,
        { RefundControls.payment 43 3 with contents.otherAssets := [(⟨91, 92⟩, 1)] }],
     expected := some "retract-foreign-asset" },
   { row with
     story := "ordinary funding may come from another wallet address",
     unspent := row.unspent.map fun (reference, output) =>
       (reference, if reference == fundingReference then
         { output with output.address := some 43 } else output) },
   { row with
     story := "two pending registrations cannot be retracted together",
     transaction.transaction.inputs := row.transaction.transaction.inputs ++
       [RejectionReadControls.input ⟨71, 3⟩], expected := some "retract-single-request" },
   { row with
     story := "a pending termination cannot accompany a retraction",
     transaction.transaction.inputs := row.transaction.transaction.inputs ++
       [RejectionReadControls.input ⟨72, 0⟩], expected := some "retract-registration-only" },
   { row with
     story := "duplicate ordinary funding cannot be counted twice",
     transaction.transaction.inputs := row.transaction.transaction.inputs ++
       [RejectionReadControls.input fundingReference], expected := some "retract-duplicate-input" },
   { row with
     story := "ordinary funding cannot also be a reference input",
     transaction.transaction.referenceInputs := [RejectionReadControls.input fundingReference],
     expected := some "retract-input-overlap" },
   { row with
     story := "a missing ordinary funding input is refused",
     unspent := row.unspent.filter fun entry => entry.1 != fundingReference,
     expected := some "spent-input-missing" },
   { more with
     story := "a balanced retraction cannot donate to the treasury",
     transaction := RefundControls.withPayments
       { more.transaction with transaction.donation := 3 }
       [RefundControls.payment 42 request.contents.lovelace],
     expected := some "retract-donation" },
   { more with
     story := "ordinary surplus may return to a fresh change address",
     transaction := RefundControls.withPayments more.transaction
       [RefundControls.payment 42 request.contents.lovelace, RefundControls.payment 43 3] },
   { more with
     story := "a payment to another address cannot take the request's declared tip",
     transaction := RefundControls.withPayments more.transaction
       [RefundControls.payment 42 (request.contents.lovelace - request.declaredTip),
        RefundControls.payment 43 (3 + request.declaredTip)],
     expected := some "retract-refund-short" },
   { row with
     story := "an unbalanced surplus refund is refused",
     transaction := RefundControls.withPayments row.transaction
       [RefundControls.payment 42 (request.contents.lovelace + 1)],
     expected := some "retract-unbalanced" },
   { row with
     story := "a funded retraction still returns the whole request value",
     transaction := RefundControls.withPayments row.transaction
       [RefundControls.payment 42 (request.contents.lovelace - 1)],
     expected := some "retract-refund-short" }]

def evaluate : IO (List Lean.Json × Nat) := do
  let world ← match RefundControls.world with
    | .error why => throw (IO.userError s!"retraction booking trace failed: {why}")
    | .ok world => pure world
  let mut rows := []
  let mut failures := 0
  for row in controls world ++ (RefundControls.controls world).filter (·.retract) do
    let result := retractionAccepted row.world row.unspent row.transaction
    let actual := match result with | .error why => some why | .ok _ => none
    let matched := actual == row.expected
    unless matched do failures := failures + 1
    if let .ok after := result then
      unless after.registry == row.world.registry && after.terminations == row.world.terminations &&
          after.treasury == row.world.treasury && after.pending.length + 1 == row.world.pending.length do
        throw (IO.userError s!"{row.story}: wrong world effect")
    if row.expected.isNone then
      unless balanced row.unspent.ledger row.transaction.transaction do
        throw (IO.userError s!"{row.story}: positive fixture does not balance")
    rows := rows ++ [Lean.Json.mkObj [
      ("story", Lean.toJson row.story), ("expectedReason", Lean.toJson row.expected),
      ("actualReason", Lean.toJson actual), ("matched", Lean.toJson matched)]]
  pure (rows, failures)

def run : IO (List Lean.Json) := do
  let (rows, failures) ← evaluate
  unless failures == 0 do
    throw (IO.userError s!"funded retraction controls: {failures} mismatches")
  pure rows

end RetractionFundingControls
