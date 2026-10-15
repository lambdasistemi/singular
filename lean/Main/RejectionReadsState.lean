import Main.Economics

/-! Rejection transaction controls, first recorded before the reference-read
judgement existed. The earlier test commit retains the RED instrument;
the corpus runner judges the recorded transactions with the economic model.
These controls establish model behavior only, never ledger acceptance. -/

open Singular

namespace RejectionReadControls

structure Control where
  story : String
  unspent : Utxo
  transaction : Tx
  members : List (OutRef × RejectReason)
  trieReadyBurns : List TokenId
  applicationBurns : List Approval
  carriedTags : List BookingContents := []
  sweep : Bool := false
  expected : Option String

def config : Config :=
  { cfg with
    registryId := 31, registrationCost := 17, minimumTip := 3,
    bookingWidth := 2, processTime := 10, retractTime := 5 }

def registration (key position : Nat) : RegistrationBooking :=
  let r : RegistrationRequest :=
    { reference := ⟨71, position⟩, registryId := config.registryId, key,
      refundAddress := 42, destination := 555, submittedAt := 102,
      registrationCost := 17, declaredTip := 3, carrierAda := 2,
      contents := { lovelace := 22, applicationTags := [], trieReadyTags := [] } }
  let application : Approval :=
    { policy := config.applicationPolicy, edge := .insertActive, key,
      owner := r.refundAddress, destination := r.destination,
      assetName := applicationTagAssetName key r.refundAddress r.destination r.nonce }
  { request := { r with contents := { r.contents with
      applicationTags := [application], trieReadyTags := [r.trieReadyTag config] } },
    interval := ⟨100, 102⟩, trieReadyTagsMinted := [r.trieReadyTag config],
    applicationTagsMinted := [application] }

/-- Both active keys are reached by actual registry steps. Every pending
registration and termination is then admitted by the production booking path. -/
def world : Except String World := do
  let first ← step { s0 with config } (req .insertActive 5 42 555)
  let second ← step first.state (req .insertActive 8 42 555)
  let mut w : World := ⟨second.state, [], [], 0⟩
  for b in [registration 5 0, registration 6 1, registration 7 2] do
    w ← book w b
  let t : TerminationRequest :=
    { reference := ⟨72, 0⟩, registryId := config.registryId, key := 8,
      destination := 555, declaredTip := 3, carrierAda := 2,
      singularTags := [config.singularTag 8],
      contents := { lovelace := 5, applicationTags := [], trieReadyTags := [] } }
  let tag := t.trieReadyTag config
  bookTermination w {
    request := { t with contents := { t.contents with trieReadyTags := [tag] } },
    custodyInputs := terminationCustody w.registry 8, trieReadyTagsMinted := [tag] }

def stateReference : OutRef := ⟨70, 0⟩

def stateOutput (w : World) : TxOutput :=
  { role := .state, datum := .inline, address := none, stateTokens := 1,
    stateToken := some w.registry.config.stateToken, config := some w.registry.config,
    commitment := none, assets := [] }

def input (ref : OutRef) : TxInput :=
  { economicInput ref with assets := [], lovelace := 0 }

def unspent (w : World) : Utxo :=
  [(stateReference, stateOutput w)] ++
  w.pending.map (fun b => (b.request.reference,
    { economicOutput b.request.contents.lovelace with role := .request, datum := .inline, assets := [] })) ++
  w.terminations.map (fun b => (b.request.reference,
    { economicOutput b.request.contents.lovelace with role := .request, datum := .inline, assets := [] })) ++
  [(⟨73, 0⟩, { economicOutput 2 with role := .request, assets := [] })]

def transaction (members : List RegistrationBooking) (interval : Interval) : Tx :=
  { inputs := members.map (fun b => input b.request.reference),
    referenceInputs := [{ input stateReference with role := .state }],
    outputs := members.map (fun b =>
      { economicOutput (b.request.contents.lovelace - b.request.declaredTip) with
        role := .owner, address := some b.request.refundAddress, assets := [] }),
    mint := [], signers := [], refunds := [], validity := some interval }

def lawful (w : World) (story : String) (members : List RegistrationBooking)
    (grounds : List RejectReason) (interval : Interval) : Control :=
  { story, unspent := unspent w, transaction := transaction members interval,
    members := (members.map (·.request.reference)).zip grounds,
    trieReadyBurns := members.flatMap (·.request.contents.trieReadyTags),
    applicationBurns := members.flatMap (·.request.contents.applicationTags), expected := none }

def controls (w : World) : List Control :=
  let mismatch := lawful w "a mismatching registration is rejected" [registration 5 0]
    [.mismatch (trieGet w.registry.trie 5)] ⟨102, 103⟩
  let expiry := lawful w "an expired registration is rejected at the threshold"
    [registration 6 1] [.expired] ⟨117, 118⟩
  let mixed := lawful w "one transaction rejects a mismatch and an expiry"
    [registration 5 0, registration 6 1]
    [.mismatch (trieGet w.registry.trie 5), .expired] ⟨117, 118⟩
  let tamperState (story : String) (output : TxOutput) (reason : String) : Control :=
    { mismatch with
     story, unspent := mismatch.unspent.map fun (ref, old) =>
        (ref, if ref = stateReference then output else old), expected := some reason }
  let stateSpend := { input stateReference with
    role := .state, stateTokens := 1,
    stateToken := some config.stateToken }
  let sweep : Control := { mismatch with
    story := "an untagged output is swept freely",
    transaction := { mismatch.transaction with inputs := [input ⟨73, 0⟩], referenceInputs := [] },
    members := [], trieReadyBurns := [], applicationBurns := [], sweep := true }
  [mismatch, expiry, mixed,
   { mismatch with
     story := "a batch of one uses the same judgement" },
   { mismatch with
     story := "the old state-spending rejection is refused",
     transaction := { mismatch.transaction with
       inputs := stateSpend :: mismatch.transaction.inputs, referenceInputs := [] },
     expected := some "reject-state-spent" },
   tamperState "a fake state token name is refused"
     { stateOutput w with stateToken := some ⟨config.registryId, 1⟩ } "reject-state-token-name",
   tamperState "another registry's state token is refused"
     { stateOutput w with stateToken := some ⟨config.registryId + 1, 0⟩ } "reject-foreign-state",
   tamperState "a referenced stale root is refused"
     { stateOutput w with config := some { w.registry.config with root := rootOf [] } }
     "reject-stale-state",
   { mismatch with
     story := "a state reference already spent is refused",
     unspent := mismatch.unspent.filter (fun p => p.1 != stateReference),
     expected := some "reference-input-missing" },
   { mismatch with
     story := "an overlapping state spend is refused",
     transaction := { mismatch.transaction with inputs := stateSpend :: mismatch.transaction.inputs },
     expected := some "reject-state-overlap" },
   { lawful w "a live member refuses the whole batch"
       [registration 5 0, registration 6 1]
       [.mismatch (trieGet w.registry.trie 5), .mismatch (trieGet w.registry.trie 6)] ⟨102, 103⟩ with
     expected := some "reject-compatible" },
   { lawful w "a repeated input refuses the whole batch"
       [registration 5 0, registration 5 0]
       [.mismatch (trieGet w.registry.trie 5), .mismatch (trieGet w.registry.trie 5)] ⟨102, 103⟩ with
     expected := some "reject-duplicate-input" },
   sweep,
   { mismatch with
     story := "a tagged registration cannot use the sweep arm", sweep := true,
     expected := some "request-tagged-sweep" },
   { mismatch with
     story := "a trie-ready tag carried out alive is refused",
     trieReadyBurns := [], carriedTags := [(registration 5 0).request.contents],
     expected := some "reject-tag-not-burned" },
   { mismatch with
     story := "an application tag carried out alive is refused",
     applicationBurns := [], carriedTags := [(registration 5 0).request.contents],
     expected := some "reject-tag-not-burned" },
   { mismatch with
     story := "a genuine termination cannot be rejected for mismatch",
     transaction := { mismatch.transaction with inputs := [input ⟨72, 0⟩] },
     members := [(⟨72, 0⟩, .mismatch (trieGet w.registry.trie 8))],
     trieReadyBurns := w.terminations.flatMap (·.request.contents.trieReadyTags),
     applicationBurns := [], expected := some "reject-compatible" },
   { mismatch with
     story := "a genuine termination has no expiry",
     transaction := { mismatch.transaction with inputs := [input ⟨72, 0⟩], validity := some ⟨117, 118⟩ },
     members := [(⟨72, 0⟩, .expired)],
     trieReadyBurns := w.terminations.flatMap (·.request.contents.trieReadyTags),
     applicationBurns := [], expected := some "reject-termination-no-expiry" }]

/-- Execute the legacy admission and spend judgement on its actual accepted
transaction. This witnesses the missing state-spend prohibition on that path;
the retained legacy behavior is not to be repaired or claimed as the new rule. -/
def legacyStateSpendingWitness : Except String (Option String × Bool) := do
  let state ← step { s0 with config } (req .insertActive 5 42 555)
  let r := { req .insertActive 5 42 555 with
    registryId := config.registryId, submittedAt := 102 }
  let witness : RejectWitness :=
    { evidence := {
        registry := state.state.config, request := r,
        reason := .mismatch (trieGet state.state.trie r.key) }, validFrom := 102, validTo := 103 }
  let reclaim : RetractWitness := ⟨0, 102, 103, []⟩
  let tx ← admittedTxOfExit state.state .reject r reclaim 22 (some witness)
  pure (exitRefusal state.state .reject r reclaim tx.inputs tx.outputs (some witness),
    tx.inputs.any (fun i => i.stateTokens > 0))

/-- Attach output observations from the admitted booking trace. The submitted
ledger projection is kept, including any adversarial state-output change. -/
def observedUnspent (w : World) (u : Utxo) : EconomicUtxo :=
  u.map fun (ref, output) =>
    let empty : BookingContents :=
      { lovelace := output.lovelace, applicationTags := [], trieReadyTags := [] }
    let observation : EconomicOutput := { output, contents := empty }
    match w.pending.find? (fun b => b.request.reference == ref) with
    | some b => (ref, { observation with
        contents := b.request.contents, request := some (.registration b.request) })
    | none => match w.terminations.find? (fun b => b.request.reference == ref) with
      | some b => (ref, { observation with
          contents := b.request.contents, singularTags := b.request.singularTags,
          request := some (.termination b.request) })
      | none => (ref, observation)

def observedTransaction (row : Control) : EconomicTransaction :=
  let refunds := row.transaction.outputs.map fun output =>
    { output, contents := {
        lovelace := output.lovelace, applicationTags := [], trieReadyTags := [] } : EconomicOutput }
  let outputs := refunds ++ row.carriedTags.map fun contents =>
    { output := { economicOutput contents.lovelace with assets := [] }, contents : EconomicOutput }
  { transaction := { row.transaction with outputs := outputs.map (·.output) },
    identity := 90, outputs,
    trieReadyMint := row.trieReadyBurns.map (·, -1),
    applicationMint := row.applicationBurns.map (fun tag => (applicationTagIdentity tag, -1)) }

def actual (w : World) (row : Control) : Except String World :=
  let u := observedUnspent w row.unspent
  let tx := observedTransaction row
  if row.sweep then sweepAccepted w u tx
  else rejectionAccepted w u ⟨tx, stateReference, row.members⟩

def run : IO (List Lean.Json) := do
  let w ← match world with
    | .error reason => throw (IO.userError s!"rejection booking trace failed: {reason}")
    | .ok w => pure w
  let mut rows := []
  for row in controls w do
    let result := actual w row
    let reason := match result with | .error why => some why | .ok _ => none
    unless reason == row.expected do
      throw (IO.userError s!"{row.story}: expected {repr row.expected}, actual {repr reason}")
    if let .ok after := result then
      unless after.registry == w.registry && after.terminations == w.terminations do
        throw (IO.userError s!"{row.story}: accepted exit changed the registry or terminations")
      if row.sweep then
        unless after == w do throw (IO.userError "sweep changed the world")
      else
        unless after.pending.length + row.members.length == w.pending.length do
          throw (IO.userError s!"{row.story}: not every member consumed once")
        let u := observedUnspent w row.unspent
        let updated := applyEconomicTransaction u (observedTransaction row)
        unless economicLookup updated stateReference == economicLookup u stateReference do
          throw (IO.userError s!"{row.story}: the referenced state did not survive")
    rows := rows ++ [Lean.Json.mkObj [
      ("story", Lean.toJson row.story), ("expectedReason", Lean.toJson row.expected),
      ("actualReason", Lean.toJson reason), ("matched", Lean.toJson (reason == row.expected))]]
  pure rows

end RejectionReadControls
