import Main.Economics

/-! Rejection transaction controls, recorded before the reference-read judgement
exists. The legacy witness executes the current admission and observed-spend
judgement. Every other row retains its submitted transaction and intended reason;
it is explicitly unevaluated until the new judgement can consume it.
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
  let mut w : World := ⟨second.state, [], []⟩
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
    { economicOutput b.request.contents.lovelace with role := .request, assets := [] })) ++
  w.terminations.map (fun b => (b.request.reference,
    { economicOutput b.request.contents.lovelace with role := .request, assets := [] })) ++
  [(⟨73, 0⟩, { economicOutput 2 with role := .request, assets := [] })]

def transaction (members : List RegistrationBooking) (interval : Interval) : Tx :=
  { inputs := members.map (fun b => input b.request.reference),
    referenceInputs := [{ input stateReference with role := .state }],
    outputs := [], mint := [], signers := [], refunds := [], validity := some interval }

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

def runRed : IO Unit := do
  let w ← match world with
    | .error reason => throw (IO.userError s!"SETUP-FAIL booking trace: {reason}")
    | .ok w => pure w
  for row in controls w do
    IO.println s!"COULD-NOT-EVALUATE {row.story}; expected={row.expected.getD "accepted"}; reference-read judgement absent"
  match legacyStateSpendingWitness with
  | .error reason => throw (IO.userError s!"SETUP-FAIL legacy witness: {reason}")
  | .ok (reason, spendsState) =>
    IO.println s!"LEGACY actual={reason.getD "accepted"} spendsState={spendsState} expected=reject-state-spent"
    if reason != some "reject-state-spent" && spendsState then
      throw (IO.userError "BEHAVIOR-RED: the legacy rejection accepts a transaction spending the state")
    else
      throw (IO.userError "CONTROL-INVALID: the intended legacy behavior was not reproduced")

end RejectionReadControls
