import OpenDatumApplication.Model
import Singular.Driver

/-! # The application's driver, corpus and ledgers

One surface, `OpenDatumApplication.appStep`, reached through one generic
runner: a scenario names an application, a registry configuration and state
asset, and a list of actions; the runner starts from `genesis` and executes the
actions through `runActionsWith`, reporting each outcome in the law's own words
(`accepted`, or `refused` with the law's reason) and the world reached. Nothing
here restates the law; every outcome is computed.

The corpus below is the witness and adverse-input scenarios, each bound to the
statements it exhibits or attacks. Its outcomes are produced by running them,
never typed. The theorem ledger's proof status is computed from the compiled
statements, never typed; the semantic atoms are creator claims for independent
review, and neither is certified coverage. -/

namespace OpenDatumApplication.Driver

open Lean
open Singular
open OpenDatumApplication

/-! ## Codecs -/

partial def dataToJson : PlutusData → Json
  | .constr tag fields =>
    Json.mkObj [("tag", "constr"), ("index", toJson tag),
      ("fields", Json.arr (fields.map dataToJson).toArray)]
  | .map entries =>
    Json.mkObj [("tag", "map"), ("entries", Json.arr (entries.map fun p =>
      Json.arr #[dataToJson p.1, dataToJson p.2]).toArray)]
  | .list items => Json.mkObj [("tag", "list"), ("items", Json.arr (items.map dataToJson).toArray)]
  | .int value => Json.mkObj [("tag", "int"), ("value", toJson value)]
  | .bytes value => Json.mkObj [("tag", "bytes"), ("value", toJson (value.map (·.toNat)))]

partial def dataFromJson (j : Json) : Except String PlutusData := do
  let tag ← j.getObjValAs? String "tag"
  match tag with
  | "constr" =>
    let index ← j.getObjValAs? Nat "index"
    let fields ← (← j.getObjValAs? (Array Json) "fields").toList.mapM dataFromJson
    pure (.constr index fields)
  | "map" =>
    let entries ← (← j.getObjValAs? (Array Json) "entries").toList.mapM fun e => do
      let pair ← e.getArr?
      match pair.toList with
      | [k, v] => pure (← dataFromJson k, ← dataFromJson v)
      | _ => throw "a map entry is a two-element array"
    pure (.map entries)
  | "list" =>
    let items ← (← j.getObjValAs? (Array Json) "items").toList.mapM dataFromJson
    pure (.list items)
  | "int" => pure (.int (← j.getObjValAs? Int "value"))
  | "bytes" =>
    let bytes ← j.getObjValAs? (List Nat) "value"
    if bytes.all (· < 256) then pure (.bytes (bytes.map (·.toUInt8)))
    else throw "byte out of range"
  | other => throw s!"unknown Plutus data tag: {other}"

def envelopeToJson (e : Envelope) : Json :=
  Json.mkObj [("control", toJson e.control), ("payload", dataToJson e.payload)]

def envelopeFromJson (j : Json) : Except String Envelope := do
  pure { control := ← j.getObjValAs? Control "control"        , payload := ← dataFromJson (← j.getObjVal? "payload") }

def assetsToJson (assets : List (Asset × Int)) : Json :=
  Json.arr (assets.map fun a =>
    Json.mkObj [("kind", toJson a.1.1), ("key", toJson a.1.2), ("quantity", toJson a.2)]).toArray

def assetsFromJson (j : Json) : Except String (List (Asset × Int)) := do
  (← j.getArr?).toList.mapM fun a => do
    pure ((← a.getObjValAs? TokenKind "kind", ← a.getObjValAs? Nat "key"),
      ← a.getObjValAs? Int "quantity")

def successorFromJson (j : Json) : Except String Successor := do
  pure { address := ← j.getObjValAs? Nat "address", lovelace := ← j.getObjValAs? Nat "lovelace"        , assets := ← assetsFromJson (← j.getObjVal? "assets")        , envelope := ← envelopeFromJson (← j.getObjVal? "envelope") }

def successorToJson (s : Successor) : Json :=
  Json.mkObj [("address", toJson s.address), ("lovelace", toJson s.lovelace)
    , ("assets", assetsToJson s.assets), ("envelope", envelopeToJson s.envelope)]


instance : ToJson Envelope := ⟨envelopeToJson⟩
instance : FromJson Envelope := ⟨envelopeFromJson⟩
instance : ToJson Successor := ⟨successorToJson⟩
instance : FromJson Successor := ⟨successorFromJson⟩

deriving instance ToJson, FromJson for TxRole
 deriving instance ToJson, FromJson for TxInput
 deriving instance ToJson, FromJson for TxOutput
 deriving instance ToJson, FromJson for Tx
 deriving instance ToJson, FromJson for EconomicRequest
 deriving instance ToJson, FromJson for EconomicOutput
 deriving instance ToJson, FromJson for EconomicTransaction
 deriving instance ToJson, FromJson for Rejection
 instance : FromJson Request where
  fromJson? j := do
    let claimed ← (← j.getObjValAs? (List Json) "claimed").mapM fun d => do
      pure (← d.getObjValAs? TokenKind "kind", ← d.getObjValAs? Int "quantity")
    pure { edge := ← j.getObjValAs? Edge "edge", key := ← j.getObjValAs? Nat "key", owner := ← j.getObjValAs? Nat "owner", refundAddress := ← j.getObjValAs? Nat "refundAddress", deposit := ← j.getObjValAs? Nat "deposit", output := ← j.getObjValAs? Nat "output", tip := ← j.getObjValAs? Nat "tip", reference := ← j.getObjValAs? Nat "reference", submittedAt := ← j.getObjValAs? Nat "submittedAt", registryId := ← j.getObjValAs? Nat "registryId", approval := ← j.getObjValAs? (Option Approval) "approval", datum := ← datumOfJson j "datum", claimed }

deriving instance ToJson, FromJson for AppAction

def actionToJson : AppAction → Json := toJson
 def actionFromJson : Json → Except String AppAction := fromJson?

def outputToJson (o : AppOutput) : Json :=
  Json.mkObj [("ref", toJson o.ref), ("address", toJson o.address), ("lovelace", toJson o.lovelace),
    ("assets", assetsToJson o.assets), ("envelope", envelopeToJson o.envelope),
    ("registrationSnapshot", envelopeToJson o.registered)]

def worldToJson (w : World) : Json :=
  Json.mkObj [("registry", toJson w.registry), ("registryAsset", toJson w.registryAsset),
    ("outputs", toJson (w.outputs.map outputToJson)), ("nextRef", toJson w.nextRef),
    ("registrations", toJson w.economic.pending), ("terminations", toJson w.economic.terminations),
    ("treasury", toJson w.economic.treasury), ("envelopes", toJson (w.pending.map fun p =>
      Json.mkObj [("reference", toJson p.reference), ("envelope", toJson p.envelope)]))]

structure Scenario where
  name : String
  kind : String
  statements : List String
  app : App
  config : Config
  asset : StateAsset
  actions : List AppAction

def scenarioToJson (s : Scenario) : Json :=
  Json.mkObj [("name", toJson s.name), ("kind", toJson s.kind)
    , ("statements", toJson s.statements), ("app", toJson s.app), ("config", toJson s.config)
    , ("asset", toJson s.asset), ("actions", Json.arr (s.actions.map actionToJson).toArray)]

def scenarioFromJson (j : Json) : Except String Scenario := do
  pure { name := ← j.getObjValAs? String "name", kind := ← j.getObjValAs? String "kind"        , statements := ← j.getObjValAs? (List String) "statements"        , app := ← j.getObjValAs? App "app", config := ← j.getObjValAs? Config "config"        , asset := ← j.getObjValAs? StateAsset "asset"        , actions := ← (← j.getObjValAs? (Array Json) "actions").toList.mapM actionFromJson }

/-- Executable observation of each independent invariant clause. No reachability
flag is used to manufacture consistency. The occurrence switch isolates the
historical duplicated-output counterexample. -/
def appConsistentBWith (checkOccurrences : Bool) (w : World) : Bool :=
  Singular.Driver.consistentB (foldProjectedRegistry w.economic) &&
  (!checkOccurrences || decide (w.outputs.map (·.ref)).Nodup) &&
  w.outputs.all (fun o => o.address == appAddress w.app &&
    o.assets == [((.active, o.envelope.control.key), 1)] &&
    o.envelope.control == o.registered.control && o.envelope.control.registry == w.registryAsset &&
    decide (o.envelope.control.deposit ≤ o.lovelace ∧ o.ref < w.nextRef)) &&
  w.outputs.all (fun a => w.outputs.all fun b =>
    !(a.envelope.control.key == b.envelope.control.key || a.ref == b.ref) || a == b) &&
  w.outputs.all (fun o => w.registry.held.contains (rootHolding w o)) &&
  w.registry.held.all (fun h => w.outputs.any (fun o => rootHolding w o == h)) &&
  decide (w.pending.map (·.reference)).Nodup &&
  decide ((w.economic.pending.map (·.request.reference)) ++
    w.economic.terminations.map (·.request.reference)).Nodup &&
  w.pending.all (fun p => w.economic.pending.any (fun b =>
    b.request.reference == p.reference && insertionBinding Law.standard w b.request p.envelope)) &&
  w.economic.pending.all (fun b => w.pending.any (fun p => p.reference == b.request.reference)) &&
  w.economic.pending.all (fun b => (registrationBookingRefusal w.registry.config b).isNone) &&
  w.economic.terminations.all (fun b => terminationExactContents w.registry.config b.request &&
    b.custodyInputs.length == 1 && b.custodyInputs.all (fun h => h.key == b.request.key && h.kind == .active))

def appConsistentB : World → Bool := appConsistentBWith true

def stepToJson : Except String World → Json
  | .ok w => Json.mkObj [("outcome", "accepted"), ("consistent", toJson (appConsistentB w)), ("world", worldToJson w)]
  | .error why => Json.mkObj [("outcome", "refused"), ("reason", toJson why)]

def runScenarioWith (law : Law) (s : Scenario) : Json :=
  Json.mkObj [("scenario", scenarioToJson s),
    ("genesisConsistent", toJson (appConsistentB (genesis s.app s.config s.asset))),
    ("steps", toJson ((runActionsWith law (genesis s.app s.config s.asset) s.actions).map stepToJson))]

def runScenario : Scenario → Json := runScenarioWith Law.standard

/-! Fixtures provide observations, never acceptance results. Folds are assembled
from selected pending requests with ordinary fee funding and separate carriers.
The generic runner serializes these actions and recomputes every outcome. -/
def app0 : App := { registry := { policy := 50, assetName := 0 }, policy := 7 }
def cfg0 : Config :=
  { root := rootOf [], minimumTip := 1, processTime := 10, retractTime := 10,     bookingWidth := 5, registrationCost := 1000000, registryId := 50,     applicationPolicy := 7, activePolicy := 8, absentPolicy := 9, terminalPolicy := 10 }
def controller : Nat := 42
def stranger : Nat := 43
def payload0 : PlutusData := .constr 0 [.int 1, .bytes [0xca, 0xfe], .map [(.bytes [1], .list [.int (-3), .int 7])]]
def payload1 : PlutusData := .list [.bytes [0xbe, 0xef], .int 2]
def payload2 : PlutusData := .map [(.int 0, .constr 3 []), (.bytes [], .bytes [0xff])]
def insertDeposit : Nat := 3000000

def envelopeFor (key : Key) (payload : PlutusData) : Envelope :=
  { control := { version := envelopeVersion, registry := app0.registry, activePolicy := 8,       key, controller, deposit := insertDeposit }, payload }

def registration (key nonce : Nat) (e : Envelope) : RegistrationBooking := Id.run do
  let r : RegistrationRequest :=
    { reference := ⟨10 + nonce, key⟩, registryId := cfg0.registryId, key, refundAddress := controller,       destination := destinationOf app0 e, submittedAt := 1, registrationCost := cfg0.registrationCost,       declaredTip := 2000000, carrierAda := e.control.deposit, datum := some (envelopeHash e), nonce,       contents := { lovelace := cfg0.registrationCost + 2000000 + e.control.deposit,         applicationTags := [], trieReadyTags := [] } }
  let tag : Approval := { policy := app0.policy, edge := .insertActive, key,     owner := r.refundAddress, destination := r.destination,     assetName := applicationTagAssetName key r.refundAddress r.destination nonce }
  let r := { r with contents := { r.contents with applicationTags := [tag], trieReadyTags := [r.trieReadyTag cfg0] } }
  return { request := r, interval := ⟨0, 1⟩, trieReadyTagsMinted := r.contents.trieReadyTags,     applicationTagsMinted := r.contents.applicationTags }

def bookInsertKey (key : Nat) (nonce : Nat := 0) : AppAction :=
  let e := envelopeFor key payload0
  .bookInsert (registration key nonce e) e [controller]

def successorOf (key : Key) (payload : PlutusData) (lovelace : Nat) : Successor :=
  { address := appAddress app0, lovelace, assets := [((.active, key), 1)], envelope := envelopeFor key payload }

def reachWorld (actions : List AppAction) : World :=
  actions.foldl (fun w a => (appStep w a).toOption.getD w) (genesis app0 cfg0 app0.registry)

/-- No statement uses this fixture's fallback as evidence: witness checks require
all prerequisite actions to succeed, and the generic run publishes refusals. -/
def termination (w : World) (key ref added tip : Nat) : TerminationBooking :=
  let o := (outputAt w ref).getD { ref, address := appAddress app0, lovelace := 0,     assets := [], envelope := envelopeFor key payload0, registered := envelopeFor key payload0 }
  let r : TerminationRequest :=
    { reference := ⟨100 + ref, key⟩, registryId := cfg0.registryId, key, destination := 0,       declaredTip := tip, carrierAda := o.lovelace + added - tip,       singularTags := [cfg0.singularTag key], contents := { lovelace := o.lovelace + added,         applicationTags := [], trieReadyTags := [] } }
  let r := { r with contents := { r.contents with trieReadyTags := [r.trieReadyTag cfg0] } }
  { request := r, custodyInputs := [rootHolding w o], trieReadyTagsMinted := r.contents.trieReadyTags }

def bare (amount : Nat) (address : Nat := controller) : EconomicOutput :=
  { output := { role := .owner, datum := .none, address := some address, stateTokens := 0,       config := none, commitment := none, assets := [], lovelace := amount },     contents := { lovelace := amount, applicationTags := [], trieReadyTags := [] } }

def stateObservation (c : Config) : EconomicOutput :=
  { bare 3000000 with output := { (bare 3000000).output with role := .state,       datum := .inline, address := none, stateTokens := 1, stateToken := some c.stateToken, config := some c } }

def registrationObservation (b : RegistrationBooking) : EconomicOutput :=
  { output := { (bare b.request.contents.lovelace).output with role := .request, datum := .inline },     contents := b.request.contents, request := some (.registration b.request) }

def terminationObservation (b : TerminationBooking) : EconomicOutput :=
  { output := { (bare b.request.contents.lovelace).output with role := .request, datum := .inline },     contents := b.request.contents, singularTags := b.request.singularTags, request := some (.termination b.request) }

def observations (w : World) : EconomicUtxo :=
  [(⟨1000, 0⟩, stateObservation w.registry.config), (⟨1001, 0⟩, bare 1000000)] ++
    w.economic.pending.map (fun b => (b.request.reference, registrationObservation b)) ++
    w.economic.terminations.map (fun b => (b.request.reference, terminationObservation b))

def input (reference : OutRef) : TxInput :=
  { ref := some reference, role := .request, datum := .inline, stateTokens := 0, approvals := 0, lovelace := 0 }

def foldTransaction (w : World) (refs : List OutRef) (interval : Interval := ⟨1, 2⟩) : EconomicTransaction := Id.run do
  let members := refs.filterMap (foldMemberAt w.economic)
  let result := foldBatch (foldProjectedRegistry w.economic) (members.map (foldLegacyRequest w.registry.config))
  let c := (result.toOption.map (·.state.config)).getD w.registry.config
  let carriers := members.filterMap fun m => match m with
    | .registration b => some { bare b.request.carrierAda b.request.destination with         output := { (bare b.request.carrierAda b.request.destination).output with           role := .destination, datum := datumFormOf b.request.datum, datumValue := b.request.datum },         singularTags := [w.registry.config.singularTag b.request.key] }
    | .termination _ => none
  let outs := [stateObservation c] ++ carriers ++ [bare (1000000 + (foldObligations members).tips - 100000)]
  let spent := refs.filterMap (economicLookup (observations w))
  return { transaction := { inputs := ((([⟨1000, 0⟩, ⟨1001, 0⟩] : List OutRef)) ++ refs).map input,       outputs := outs.map (·.output), mint := [], signers := [], refunds := [], validity := some interval,       fee := 100000, donation := (foldObligations members).donation },     identity := 2000, outputs := outs,     trieReadyMint := (spent.flatMap (·.contents.trieReadyTags)).map (·, -1),     applicationMint := ((spent.flatMap (·.contents.applicationTags)).map applicationTagIdentity).map (·, -1),     singularMint := foldMint w.registry.config members }

def foldAction (actions : List AppAction) (refs : List OutRef) (interval : Interval := ⟨1, 2⟩) : AppAction :=
  let w := reachWorld actions
  .fold (observations w) (foldTransaction w refs interval)

/-- Coincident addresses do not merge a carrier with an ordinary output. -/
def coincidentFold (actions : List AppAction) (refs : List OutRef) : AppAction :=
  let w := reachWorld actions
  let tx := foldTransaction w refs
  let address := (tx.outputs.find? (fun o => !o.singularTags.isEmpty)).bind (·.output.address)
  let outputs := tx.outputs.map fun o => if foldOrdinary o then
    { o with output := { o.output with address } } else o
  .fold (observations w) { tx with outputs, transaction := { tx.transaction with outputs := outputs.map (·.output) } }

def insertKey (key : Key) (nonce : Nat := 0) : List AppAction :=
  let actions := [bookInsertKey key nonce]
  actions ++ [foldAction actions [⟨10 + nonce, key⟩]]

def rejectAction (actions : List AppAction) (refs : List OutRef) : AppAction := Id.run do
  let w := reachWorld actions
  let u := observations w
  let spent := refs.filterMap (economicLookup u)
  let outs := (refundObligations (rejectedRequests w.economic (refs.map (·, .expired))) false).map
    fun (address, amount) => bare amount address
  let tx : EconomicTransaction := { transaction := { inputs := refs.map input, outputs := outs.map (·.output),       referenceInputs := [input ⟨1000, 0⟩], validity := some ⟨21, 22⟩, mint := [], signers := [], refunds := [] },     identity := 2000, outputs := outs, trieReadyMint := (spent.flatMap (·.contents.trieReadyTags)).map (·, -1),     applicationMint := ((spent.flatMap (·.contents.applicationTags)).map applicationTagIdentity).map (·, -1) }
  return .reject u { transaction := tx, stateReference := ⟨1000, 0⟩, members := refs.map (·, .expired) }

def scenario (name kind : String) (statements : List String) (actions : List AppAction)
    (asset : StateAsset := app0.registry) : Scenario :=
  { name, kind, statements, app := app0, config := cfg0, asset, actions }

def updatedActions : List AppAction := insertKey 5 ++ [.update 0 [successorOf 5 payload1 4000000] [controller]]
def bookedTerminationActions (added : Nat) : List AppAction :=
  updatedActions ++ [.bookTerminate (termination (reachWorld updatedActions) 5 1 added 2000000) 1 added [controller]]
def lifecycleActions (added : Nat) : List AppAction :=
  let as := bookedTerminationActions added
  as ++ [foldAction as [⟨101, 5⟩] ⟨1000000, 1000001⟩]

def bookingNoDatum : AppAction :=
  let e := envelopeFor 5 payload0
  let b := registration 5 0 e
  .bookInsert { b with request := { b.request with datum := none } } e [controller]

def corpus : List Scenario := Id.run do
  let term := bookedTerminationActions 0
  let mixed0 := insertKey 5 ++ [bookInsertKey 6]
  let mixed1 := mixed0 ++ [foldAction mixed0 [⟨10, 6⟩]]
  let mixed2 := mixed1 ++ [.bookTerminate (termination (reachWorld mixed1) 5 0 0 2000000) 0 0 [controller]]
  let mixed3 := mixed2 ++ [.bookTerminate (termination (reachWorld mixed2) 6 1 0 2000000) 1 0 [controller], bookInsertKey 7]
  let reg := [bookInsertKey 5]
  let rejectBesideTermination := term ++ [bookInsertKey 6]
  let dup := insertKey 5 ++ [bookInsertKey 5 1]
  let resurrect := lifecycleActions 0 ++ [bookInsertKey 5 1]
  let b := registration 5 0 (envelopeFor 5 payload0)
  let short := termination (reachWorld updatedActions) 5 1 0 2000000
  let short := { short with request := { short.request with carrierAda := 1000000,     contents := { short.request.contents with lovelace := 3000000 } } }
  return [
    scenario "lifecycle-tip-from-held" "witness" ["update_requires_controller","bookInsert_inversion","bookTerminate_inversion","update_inversion","fold_inversion","appStep_fold","selectRow_inversion","genesis_consistent","appStep_preserves_consistent","reachable_consistent","bookInsert_preserves_consistent","bookTerminate_preserves_consistent","update_preserves_consistent","fold_preserves_consistent","update_keeps_registry","update_preserves_custody","insertion_requires_registry_identity","insertion_binds_envelope","insertion_holding_inline","bookTerminate_transfers_custody","termination_fold_burns_atomically","only_termination_booking_transfers_custody","fold_routes_economics","fold_consumed_requests_disappear","fold_requires_no_application_signature","registration_tag_binds_nonce","termination_has_no_application_tag_or_clock","termination_booking_has_no_controller_payout","termination_booking_value_transfer","application_root_world_correspondence","application_supply_spans_custody_and_pending","termination_fold_donates_held_minus_tip","termination_has_no_expiry","selected_request_refs_distinct","registration_allocations_are_distinct","termination_fold_timing_equivalent_root","application_fold_decision_equivalent_root"] (lifecycleActions 0),
    scenario "lifecycle-optional-addition" "witness" ["termination_booking_value_transfer", "termination_fold_donates_held_minus_tip"] (lifecycleActions 1000000),
    scenario "two-terminations-and-registration" "witness" ["fold_routes_economics", "selected_request_refs_distinct"] (mixed3 ++ [coincidentFold mixed3 [⟨100, 5⟩, ⟨101, 6⟩, ⟨10, 7⟩]]),
    scenario "payload-b" "witness" ["update_payload_free"] (insertKey 5 ++ [.update 0 [successorOf 5 payload2 insertDeposit] [controller]]),
    scenario "update-unsigned" "adverse-input" ["update_requires_controller"] (insertKey 5 ++ [.update 0 [successorOf 5 payload1 insertDeposit] [stranger]]),
    scenario "update-control" "adverse-input" ["update_preserves_custody"] (insertKey 5 ++ [.update 0
      [{ successorOf 5 payload1 insertDeposit with envelope := { envelopeFor 5 payload1 with control := { (envelopeFor 5 payload1).control with controller := stranger } } }] [controller]]),
    scenario "update-escape" "adverse-input" ["update_preserves_custody"] (insertKey 5 ++ [.update 0
      [{ successorOf 5 payload1 insertDeposit with address := stranger }] [controller]]),
    scenario "update-floor" "adverse-input" ["update_preserves_custody"] (insertKey 5 ++ [.update 0 [successorOf 5 payload1 1] [controller]]),
    scenario "update-drops-token" "adverse-input" ["update_preserves_custody"] (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with assets := [] }] [controller]]),
    scenario "withdraw" "adverse-input" ["withdraw_inversion"] (insertKey 5 ++ [.withdraw 0 []]),
    scenario "pending-cannot-update" "adverse-input" ["pending_termination_cannot_be_rebooked_or_updated"] (term ++ [.update 1 [successorOf 5 payload2 insertDeposit] [controller]]),
    scenario "pending-cannot-rebook" "adverse-input" ["pending_termination_cannot_be_rebooked_or_updated"] (term ++ [.bookTerminate (termination (reachWorld updatedActions) 5 1 0 2000000) 1 0 [controller]]),
    scenario "termination-rejection-refused" "adverse-input" ["termination_has_no_expiry","application_rejection_decision_equivalent_root"] (term ++ [rejectAction term [⟨101, 5⟩]]),
    scenario "registration-rejection-beside-pending-termination" "witness" ["rejection_preserves_pending_terminations", "reject_preserves_consistent"] (rejectBesideTermination ++ [rejectAction rejectBesideTermination [⟨10, 6⟩]]),
    scenario "registration-expired-rejection" "witness" ["reject_inversion", "reject_preserves_consistent", "rejection_preserves_pending_terminations"] (reg ++ [rejectAction reg [⟨10, 5⟩]]),
    scenario "duplicate-insertion" "adverse-input" ["duplicate_refused_by_registry"] (dup ++ [foldAction dup [⟨11, 5⟩]]),
    scenario "resurrection" "adverse-input" ["resurrection_refused_by_registry"] (resurrect ++ [foldAction resurrect [⟨11, 5⟩]]),
    scenario "registry-asset-other-name" "adverse-input" ["insertion_requires_registry_identity"] reg { policy := 50, assetName := 52 },
    scenario "registry-asset-other-policy" "adverse-input" ["insertion_requires_registry_identity"] reg { policy := 60, assetName := 51 },
    scenario "booking-no-datum" "adverse-input" ["insertion_binds_envelope"] [bookingNoDatum],
    scenario "booking-unsigned" "adverse-input" ["bookInsert_inversion"] [.bookInsert b (envelopeFor 5 payload0) [stranger]],
    scenario "termination-unsigned" "adverse-input" ["bookTerminate_inversion"] (updatedActions ++ [.bookTerminate (termination (reachWorld updatedActions) 5 1 0 2000000) 1 0 [stranger]]),
    scenario "termination-diverts-surplus" "adverse-input" ["termination_booking_value_transfer"] (updatedActions ++ [.bookTerminate short 1 0 [controller]]),
    scenario "other-edge" "adverse-input" ["bookOther_refused"] [.bookOther { edge := .deleteActive, key := 5 } [controller]] ]

def ordinaryWorld : World := reachWorld (insertKey 5)
def duplicatedWorld : World := { ordinaryWorld with outputs := ordinaryWorld.outputs ++ ordinaryWorld.outputs }
def boundaryUpdate : AppAction := .update 0 [successorOf 5 payload1 insertDeposit] [controller]
structure BoundaryWorld where
  name : String
  reached : Bool
  statements : List String
  world : World

def boundaryWorlds : List BoundaryWorld :=
  [⟨"ordinary-after-insert", true, ["consistent_occurrences_distinct", "appConsistentB_iff"], ordinaryWorld⟩,
   ⟨"identical-duplicate-occurrence", false, ["duplicate_occurrence_outside_invariant"], duplicatedWorld⟩]

def bookedWorld : World := reachWorld [bookInsertKey 5]
def unnamedPendingWorld : World := { bookedWorld with economic := { bookedWorld.economic with   pending := bookedWorld.economic.pending.map fun b => { b with request := { b.request with datum := none } } } }
def selectionFold : AppAction := foldAction [bookInsertKey 5] [⟨10, 5⟩]
structure SelectionWorld where
  name : String
  reached : Bool
  statements : List String
  world : World

def selectionWorlds : List SelectionWorld :=
  [⟨"booked-insertion-names-datum", true, ["selectRow_requires_named_datum"], bookedWorld⟩,
   ⟨"pending-insertion-names-no-datum", false, ["selectRow_requires_named_datum"], unnamedPendingWorld⟩]

def selectionWorldToJson (s : SelectionWorld) : Json :=
  Json.mkObj [("name", toJson s.name), ("reached", toJson s.reached), ("statements", toJson s.statements),
    ("world", worldToJson s.world), ("fold", stepToJson (appStep s.world selectionFold))]
def boundaryToJson (b : BoundaryWorld) : Json :=
  Json.mkObj [("name", toJson b.name), ("reached", toJson b.reached), ("statements", toJson b.statements),
    ("world", worldToJson b.world), ("consistent", toJson (appConsistentB b.world)),
    ("consistentWithoutOccurrenceClause", toJson (appConsistentBWith false b.world)),
    ("update", stepToJson (appStep b.world boundaryUpdate))]

def corpusWith (law : Law) : Json :=
  Json.mkObj [("scenarios", toJson (corpus.map (runScenarioWith law))),
    ("invariantBoundary", toJson (boundaryWorlds.map boundaryToJson)),
    ("selectionBoundary", toJson (selectionWorlds.map selectionWorldToJson))]
def corpusJson : Json := corpusWith Law.standard
/-! ## SHA-256

FIPS 180-4, over bytes. It binds each ledger row to the exact text of its
declaration header, so a statement that moves makes its row stale. -/

private def sha256K : Array UInt32 :=
  #[0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

private def rotr (x n : UInt32) : UInt32 := (x >>> n) ||| (x <<< (32 - n))

/-- The SHA-256 digest of a byte string. -/
def sha256 (msg : ByteArray) : ByteArray := Id.run do
  let mut padded := msg.push 0x80
  while padded.size % 64 != 56 do
    padded := padded.push 0
  let bits := msg.size * 8
  for i in [0:8] do
    padded := padded.push ((bits >>> (8 * (7 - i))) % 256).toUInt8
  let mut h : Array UInt32 :=
    #[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
  for blk in [0:padded.size / 64] do
    let byte := fun (i : Nat) => (padded.get! (blk * 64 + i)).toUInt32
    let mut w : Array UInt32 := #[]
    for t in [0:16] do
      w := w.push ((byte (4 * t) <<< 24) ||| (byte (4 * t + 1) <<< 16) |||
        (byte (4 * t + 2) <<< 8) ||| byte (4 * t + 3))
    for t in [16:64] do
      let s0 := rotr w[t - 15]! 7 ^^^ rotr w[t - 15]! 18 ^^^ (w[t - 15]! >>> 3)
      let s1 := rotr w[t - 2]! 17 ^^^ rotr w[t - 2]! 19 ^^^ (w[t - 2]! >>> 10)
      w := w.push (w[t - 16]! + s0 + w[t - 7]! + s1)
    let mut a := h[0]!
    let mut b := h[1]!
    let mut c := h[2]!
    let mut d := h[3]!
    let mut e := h[4]!
    let mut f := h[5]!
    let mut g := h[6]!
    let mut hh := h[7]!
    for t in [0:64] do
      let s1 := rotr e 6 ^^^ rotr e 11 ^^^ rotr e 25
      let ch := (e &&& f) ^^^ ((~~~e) &&& g)
      let t1 := hh + s1 + ch + sha256K[t]! + w[t]!
      let s0 := rotr a 2 ^^^ rotr a 13 ^^^ rotr a 22
      let maj := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)
      let t2 := s0 + maj
      hh := g
      g := f
      f := e
      e := d + t1
      d := c
      c := b
      b := a
      a := t1 + t2
    h := #[h[0]! + a, h[1]! + b, h[2]! + c, h[3]! + d, h[4]! + e, h[5]! + f, h[6]! + g,
      h[7]! + hh]
  let mut out := ByteArray.empty
  for word in h do
    for s in [24, 16, 8, 0] do
      out := out.push ((word >>> s.toUInt32) &&& 0xff).toUInt8
  return out

/-- Lower-case hexadecimal of a byte string. -/
def hexOf (bytes : ByteArray) : String :=
  bytes.foldl (fun acc b =>
    let digit := fun (n : Nat) => "0123456789abcdef".get ⟨n⟩
    (acc.push (digit (b.toNat / 16))).push (digit (b.toNat % 16))) ""

/-- The SHA-256 of a text's UTF-8 bytes, in hexadecimal. -/
def sha256Hex (text : String) : String := hexOf (sha256 text.toUTF8)

/-! ## Ledgers: compiled proof status, not coverage

The theorem ledger's `status` is never typed. The generator receives the
statements the compiled environment actually declares
(`OpenDatumApplication.Audit.compiledStatements`: each public theorem of
`OpenDatumApplication.Statements`, the axioms the kernel reports it depending
on, and its declaration header as written), reconciles them with the ledger's
statement extent in both directions, and derives each row's status and header
hash from them. `PROVED` means the standard axioms alone; `STATED` means
`sorryAx` and nothing non-standard besides; any other axiom is refused. A proved
statement is a property of the model; its row's `scenarios` and `boundary` say
which published cases exhibit it, not that any product claim was executed. The
semantic atoms remain creator claims for review. -/

def statementNames : List (String × String) :=
  [ ("bookInsert_inversion", "inversion")
  , ("bookTerminate_inversion", "inversion")
  , ("bookOther_refused", "inversion")
  , ("update_inversion", "inversion")
  , ("selectRow_inversion", "inversion")
  , ("fold_inversion", "inversion")
  , ("appStep_fold", "inversion")
  , ("reject_inversion", "inversion")
  , ("withdraw_inversion", "inversion")
  , ("genesis_consistent", "invariant")
  , ("appStep_preserves_consistent", "invariant")
  , ("reachable_consistent", "invariant")
  , ("consistent_occurrences_distinct", "invariant")
  , ("duplicate_occurrence_outside_invariant", "invariant")
  , ("appConsistentB_iff", "requirement")
  , ("bookInsert_preserves_consistent", "invariant")
  , ("bookTerminate_preserves_consistent", "invariant")
  , ("update_preserves_consistent", "invariant")
  , ("fold_preserves_consistent", "invariant")
  , ("reject_preserves_consistent", "invariant")
  , ("update_requires_controller", "requirement")
  , ("update_preserves_custody", "requirement")
  , ("update_payload_free", "requirement")
  , ("update_keeps_registry", "requirement")
  , ("insertion_requires_registry_identity", "requirement")
  , ("insertion_binds_envelope", "requirement")
  , ("selectRow_requires_named_datum", "requirement")
  , ("insertion_holding_inline", "requirement")
  , ("bookTerminate_transfers_custody", "requirement")
  , ("termination_fold_burns_atomically", "requirement")
  , ("only_termination_booking_transfers_custody", "requirement")
  , ("fold_routes_economics", "requirement")
  , ("fold_consumed_requests_disappear", "requirement")
  , ("duplicate_refused_by_registry", "requirement")
  , ("resurrection_refused_by_registry", "requirement")
  , ("fold_requires_no_application_signature", "requirement")
  , ("registration_tag_binds_nonce", "requirement")
  , ("termination_has_no_application_tag_or_clock", "requirement")
  , ("termination_booking_has_no_controller_payout", "requirement")
  , ("termination_booking_value_transfer", "requirement")
  , ("pending_termination_cannot_be_rebooked_or_updated", "requirement")
  , ("application_root_world_correspondence", "requirement")
  , ("application_supply_spans_custody_and_pending", "requirement")
  , ("termination_fold_donates_held_minus_tip", "requirement")
  , ("termination_has_no_expiry", "requirement")
  , ("selected_request_refs_distinct", "requirement")
  , ("rejection_preserves_pending_terminations", "requirement")
  , ("registration_allocations_are_distinct", "requirement")
  , ("termination_fold_timing_equivalent_root", "requirement")
  , ("application_fold_decision_equivalent_root", "requirement")
  , ("application_rejection_decision_equivalent_root", "requirement") ]

/-- A statement's qualified name. -/
def qualified (name : String) : String := s!"OpenDatumApplication.Statements.{name}"

/-- The axioms a proof may rest on and still be called proved. -/
def standardAxioms : List String := ["propext", "Classical.choice", "Quot.sound"]

/-- One compiled statement: its qualified name, the axioms the kernel reports
it depending on, and its declaration header as written. -/
abbrev AuditedStatement := String × List String × String

/-- A ledger row's computed proof status. -/
structure StatementStatus where
  name : String
  status : String
  axioms : List String
  statementSha256 : String

/-- The status the axioms establish: `PROVED` on the standard axioms alone,
`STATED` when `sorryAx` is the only other one; any other axiom is refused. -/
def statusOf (name : String) (axioms : List String) : Except String String :=
  if axioms.all standardAxioms.contains then .ok "PROVED"
  else if axioms.contains "sorryAx" &&
      axioms.all (fun a => a == "sorryAx" || standardAxioms.contains a) then .ok "STATED"
  else .error s!"custom-axiom: {name} depends on {axioms.filter (!standardAxioms.contains ·)}"

/-- Reconcile the compiled statements with the ledger's extent, in both
directions, and compute each row's status and header hash. -/
def reconcileStatements (audited : List AuditedStatement) :
    Except String (List StatementStatus) := do
  let names := audited.map (·.1)
  let expected := statementNames.map (qualified ·.1)
  if names.eraseDups.length != names.length then
    throw s!"duplicate-report: {names.filter fun n => (names.filter (· == n)).length > 1}"
  for n in expected do
    unless names.contains n do throw s!"missing-report: {n} has no compiled statement"
  for n in names do
    unless expected.contains n do throw s!"extra-report: {n} is not a ledger statement"
  audited.mapM fun (name, axioms, header) => do
    let status ← statusOf name axioms
    pure { name, status, axioms, statementSha256 := sha256Hex header }

def theoremLedgerOf (rows : List StatementStatus) : Json :=
  Json.arr (statementNames.map fun (name, cls) =>
    let row := rows.find? (·.name == qualified name)
    Json.mkObj [("statement", toJson (qualified name))
      , ("class", toJson cls)
      , ("status", toJson ((row.map (·.status)).getD "missing"))
      , ("axioms", toJson ((row.map (·.axioms)).getD []))
      , ("statementSha256", toJson ((row.map (·.statementSha256)).getD ""))
      , ("scenarios", toJson ((corpus.filter (·.statements.contains name)).map (·.name)))
      , ("boundary", toJson ((boundaryWorlds.filter (·.statements.contains name)).map (·.name) ++
          (selectionWorlds.filter (·.statements.contains name)).map (·.name)))]).toArray

def atoms : List (String × String × String) :=
  [ ("A1", "authorization", "the controller signs each booking and payload update")
  , ("A2", "binding", "registration binds the whole envelope, registry identity and nonce-bound root application tag")
  , ("A3", "value", "registration carrier equals the protected floor; live updates preserve at least that floor")
  , ("A4", "custody", "termination booking consumes the actual output and transfers its genuine singular tag and all actual value")
  , ("A5", "refusal", "arbitrary withdrawal and uncertified booking edges are refused")
  , ("A6", "terminality", "the root fold burns a pending termination's singular and trie-ready tags and makes its leaf Terminal")
  , ("A7", "value", "held equals actual output value plus optional additions equals tip plus carrier; donation is held minus tip, without a protected-floor minimum")
  , ("A8", "composition", "the frozen root fold refuses duplicate registration and resurrection")
  , ("A9", "payload", "arbitrary payload updates preserve control, assets, snapshot and root economic world")
  , ("A10", "custody", "references and live keys are unique; supply spans application custody and pending termination")
  , ("A11", "value", "root fold routes costs and termination donations to treasury, carriers separately and tips to exact gross ordinary allocation with ordinary-funded fees")
  , ("A12", "refusal", "root registration rejection is available; pending termination has no expiry, rejection or application retraction action") ]

def atomLedger : Json :=
  Json.arr (atoms.map fun (id, cls, text) =>
    Json.mkObj [("atom", toJson id), ("class", toJson cls), ("claim", toJson text)]).toArray

def ledgersJsonOf (rows : List StatementStatus) : Json :=
  Json.mkObj [("theorems", theoremLedgerOf rows), ("atoms", atomLedger)]

/-! ## The checks and their own controls -/

/-- The recorded scenario rows of a corpus. -/
def scenarioRows (recorded : Json) : Except String (Array Json) :=
  recorded.getObjValAs? (Array Json) "scenarios"

/-- Rerun every recorded scenario from its own JSON; the names that differ. -/
def replayDiffs (recorded : Json) : Except String (List String) := do
  let rows ← scenarioRows recorded
  rows.toList.filterMapM fun row => do
    let s ← scenarioFromJson (← row.getObjVal? "scenario")
    pure (if runScenario s == row then none else some s.name)

/-- The recorded corpus with its first recorded outcome replaced: the
controlled alteration every check must notice. -/
def alterFirstOutcome (recorded : Json) : Except String Json := do
  let rows ← scenarioRows recorded
  let some first := rows[0]? | throw "empty corpus"
  let steps ← first.getObjValAs? (Array Json) "steps"
  let altered := steps.modify 0 fun _ => Json.mkObj [("outcome", "refused"), ("reason", "altered")]
  pure (recorded.setObjVal! "scenarios"
    (Json.arr (rows.modify 0 fun _ => first.setObjVal! "steps" (Json.arr altered))))

/-- The definition mutants: each switches one guard of the law off. -/
def mutants : List (String × Law) :=
  [ ("no-update-signer", { checkUpdateSigner := false })
  , ("no-registry-asset", { checkRegistryAsset := false })
  , ("divert-application-value", { checkTransferredValue := false })
  , ("no-booking-signer", { checkBookingSigner := false })
  , ("change-update-control", { checkUpdateControl := false })
  , ("escape-update-address", { checkUpdateAddress := false })
  , ("drop-update-floor", { checkUpdateFloor := false })
  , ("rewrite-registration-snapshot", { preserveSnapshot := false })
  , ("keep-booked-custody", { removeBookedCustody := false }) ]

/-- The scenarios a law runs differently from the recorded corpus. -/
def differingUnder (law : Law) (recorded : Json) : Except String (List String) := do
  let rows ← scenarioRows recorded
  rows.toList.filterMapM fun row => do
    let s ← scenarioFromJson (← row.getObjVal? "scenario")
    pure (if runScenarioWith law s == row then none else some s.name)

/-- The scenarios with a genesis or an accepted step whose world the invariant
observation rejects. -/
def inconsistentReached : List String :=
  (corpus.filter fun s =>
    !(appConsistentB (genesis s.app s.config s.asset) &&
      (runActionsWith Law.standard (genesis s.app s.config s.asset) s.actions).all fun r =>
        match r with
        | .ok w => appConsistentB w
        | .error _ => true)).map (·.name)

/-- The accepted constructors each scenario's reached steps exercise. -/
def constructorName : AppAction → String
  | .bookInsert .. => "bookInsert"
  | .bookTerminate .. => "bookTerminate"
  | .bookOther .. => "bookOther"
  | .update .. => "update"
  | .fold .. => "fold"
  | .reject .. => "reject"
  | .withdraw .. => "withdraw"

/-- Every constructor that at least one scenario takes to an accepted step. -/
def acceptedConstructors : List String :=
  (corpus.flatMap fun s =>
    ((s.actions.zip (runActionsWith Law.standard (genesis s.app s.config s.asset) s.actions)).filterMap
      fun (a, r) => match r with
        | .ok _ => some (constructorName a)
        | .error _ => none)).eraseDups

end OpenDatumApplication.Driver
