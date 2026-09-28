import OpenDatumApplication.Model

/-! # The application's driver, corpus and ledgers

One surface, `OpenDatumApplication.appStep`, reached through one generic
runner: a scenario names an application, a registry configuration and state
asset, and a list of actions; the runner starts from `genesis` and executes the
actions through `runActions`, reporting each outcome in the law's own words
(`accepted`, or `refused` with the law's reason) and the world reached. Nothing
here restates the law; every outcome is computed.

The corpus below is the witness and mutant scenarios, each bound to the
statement it exhibits or attacks. Its outcomes are produced by running them,
never typed. The theorem and semantic-atom ledgers are creator claims for
independent review, not certified coverage. -/

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
  pure { control := ← j.getObjValAs? Control "control"
       , payload := ← dataFromJson (← j.getObjVal? "payload") }

def assetsToJson (assets : List (Asset × Int)) : Json :=
  Json.arr (assets.map fun a =>
    Json.mkObj [("kind", toJson a.1.1), ("key", toJson a.1.2), ("quantity", toJson a.2)]).toArray

def assetsFromJson (j : Json) : Except String (List (Asset × Int)) := do
  (← j.getArr?).toList.mapM fun a => do
    pure ((← a.getObjValAs? TokenKind "kind", ← a.getObjValAs? Nat "key"),
      ← a.getObjValAs? Int "quantity")

def successorFromJson (j : Json) : Except String Successor := do
  pure { address := ← j.getObjValAs? Nat "address", lovelace := ← j.getObjValAs? Nat "lovelace"
       , assets := ← assetsFromJson (← j.getObjVal? "assets")
       , envelope := ← envelopeFromJson (← j.getObjVal? "envelope") }

def successorToJson (s : Successor) : Json :=
  Json.mkObj [("address", toJson s.address), ("lovelace", toJson s.lovelace)
    , ("assets", assetsToJson s.assets), ("envelope", envelopeToJson s.envelope)]

def optNat (j : Json) (field : String) : Nat :=
  (j.getObjValAs? Nat field).toOption.getD 0

/-- A request as a scenario states it: no approval and no claim, which the
application's booking supplies. -/
def requestFromJson (j : Json) : Except String Request := do
  pure { edge := ← j.getObjValAs? Edge "edge", key := ← j.getObjValAs? Nat "key"
       , owner := optNat j "owner", refundAddress := optNat j "refundAddress"
       , deposit := optNat j "deposit", output := optNat j "output", tip := optNat j "tip" }

def requestToJson (r : Request) : Json :=
  Json.mkObj [("edge", toJson r.edge), ("key", toJson r.key), ("owner", toJson r.owner)
    , ("refundAddress", toJson r.refundAddress), ("deposit", toJson r.deposit)
    , ("output", toJson r.output), ("tip", toJson r.tip)]

def exitToJson : Exit → Json
  | .fold e => Json.mkObj [("exit", "fold"), ("edge", toJson e)]
  | .reject => Json.mkObj [("exit", "reject")]
  | .retract => Json.mkObj [("exit", "retract")]

def exitFromJson (j : Json) : Except String Exit := do
  match ← j.getObjValAs? String "exit" with
  | "fold" => pure (.fold (← j.getObjValAs? Edge "edge"))
  | "reject" => pure .reject
  | "retract" => pure .retract
  | other => throw s!"unknown exit: {other}"

/-- A payment output at a key, the only output kind a release is judged on. -/
def ownerOutput (key lovelace : Nat) : TxOutput :=
  { role := .owner, datum := .none, address := some key, stateTokens := 0, config := none
  , commitment := none, assets := [], lovelace := lovelace }

def paymentsFromJson (j : Json) : Except String (List TxOutput) := do
  (← j.getArr?).toList.mapM fun o => do
    pure (ownerOutput (← o.getObjValAs? Nat "owner") (← o.getObjValAs? Nat "lovelace"))

def paymentsToJson (outs : List TxOutput) : Json :=
  Json.arr (outs.map fun o =>
    Json.mkObj [("owner", toJson (o.address.getD 0)), ("lovelace", toJson o.lovelace)]).toArray

def actionToJson : AppAction → Json
  | .bookInsert r e sigs => Json.mkObj [("action", "bookInsert"), ("request", requestToJson r)
      , ("envelope", envelopeToJson e), ("signatures", toJson sigs)]
  | .foldInsert key => Json.mkObj [("action", "foldInsert"), ("key", toJson key)]
  | .update ref succs sigs => Json.mkObj [("action", "update"), ("ref", toJson ref)
      , ("successors", Json.arr (succs.map successorToJson).toArray), ("signatures", toJson sigs)]
  | .bookTerminate r ref sigs => Json.mkObj [("action", "bookTerminate")
      , ("request", requestToJson r), ("ref", toJson ref), ("signatures", toJson sigs)]
  | .foldRelease keys exit outs => Json.mkObj [("action", "foldRelease"), ("keys", toJson keys)
      , ("exit", exitToJson exit), ("outputs", paymentsToJson outs)]
  | .withdraw ref outs => Json.mkObj [("action", "withdraw"), ("ref", toJson ref)
      , ("outputs", paymentsToJson outs)]

def actionFromJson (j : Json) : Except String AppAction := do
  match ← j.getObjValAs? String "action" with
  | "bookInsert" => pure (.bookInsert (← requestFromJson (← j.getObjVal? "request"))
      (← envelopeFromJson (← j.getObjVal? "envelope")) (← j.getObjValAs? (List Nat) "signatures"))
  | "foldInsert" => pure (.foldInsert (← j.getObjValAs? Nat "key"))
  | "update" => pure (.update (← j.getObjValAs? Nat "ref")
      (← (← j.getObjValAs? (Array Json) "successors").toList.mapM successorFromJson)
      (← j.getObjValAs? (List Nat) "signatures"))
  | "bookTerminate" => pure (.bookTerminate (← requestFromJson (← j.getObjVal? "request"))
      (← j.getObjValAs? Nat "ref") (← j.getObjValAs? (List Nat) "signatures"))
  | "foldRelease" => pure (.foldRelease (← j.getObjValAs? (List Nat) "keys")
      (← exitFromJson (← j.getObjVal? "exit")) (← paymentsFromJson (← j.getObjVal? "outputs")))
  | "withdraw" => pure (.withdraw (← j.getObjValAs? Nat "ref")
      (← paymentsFromJson (← j.getObjVal? "outputs")))
  | other => throw s!"unknown action: {other}"

def outputToJson (o : AppOutput) : Json :=
  Json.mkObj [("ref", toJson o.ref), ("address", toJson o.address), ("lovelace", toJson o.lovelace)
    , ("assets", assetsToJson o.assets), ("envelope", envelopeToJson o.envelope)
    , ("envelopeHash", toJson (envelopeHash o.envelope))]

def worldToJson (w : World) : Json :=
  Json.mkObj [("registry", toJson w.registry)
    , ("outputs", Json.arr (w.outputs.map outputToJson).toArray)
    , ("pending", Json.arr (w.pending.map fun p => requestToJson p.request).toArray)]

/-! ## Scenarios and the runner -/

structure Scenario where
  name : String
  kind : String
  statement : String
  mutates : Option String
  app : App
  config : Config
  asset : StateAsset
  actions : List AppAction

def scenarioToJson (s : Scenario) : Json :=
  Json.mkObj [("name", toJson s.name), ("kind", toJson s.kind), ("statement", toJson s.statement)
    , ("mutates", toJson s.mutates), ("app", toJson s.app), ("config", toJson s.config)
    , ("asset", toJson s.asset), ("actions", Json.arr (s.actions.map actionToJson).toArray)]

def scenarioFromJson (j : Json) : Except String Scenario := do
  pure { name := ← j.getObjValAs? String "name", kind := ← j.getObjValAs? String "kind"
       , statement := ← j.getObjValAs? String "statement"
       , mutates := (j.getObjValAs? String "mutates").toOption
       , app := ← j.getObjValAs? App "app", config := ← j.getObjValAs? Config "config"
       , asset := ← j.getObjValAs? StateAsset "asset"
       , actions := ← (← j.getObjValAs? (Array Json) "actions").toList.mapM actionFromJson }

def outcomeToJson : Except String Unit → Json
  | .ok () => Json.mkObj [("outcome", "accepted")]
  | .error why => Json.mkObj [("outcome", "refused"), ("reason", toJson why)]

/-- The one surface: run a scenario's actions through `appStep` from genesis. -/
def runScenario (s : Scenario) : Json :=
  let (outcomes, final) := runActions (genesis s.app s.config s.asset) s.actions
  Json.mkObj [("scenario", scenarioToJson s)
    , ("outcomes", Json.arr (outcomes.map outcomeToJson).toArray)
    , ("final", worldToJson final)]

/-! ## The corpus -/

def app0 : App := { registry := { policy := 50, assetName := 51 }, policy := 7 }

def cfg0 : Config :=
  { root := rootOf [], maxFee := 0, processTime := 0, retractTime := 0
  , applicationPolicy := 7, activePolicy := 8, absentPolicy := 9, terminalPolicy := 10 }

def controller : Nat := 42
def stranger : Nat := 43

def payload0 : PlutusData :=
  .constr 0 [.int 1, .bytes [0xca, 0xfe], .map [(.bytes [1], .list [.int (-3), .int 7])]]

def payload1 : PlutusData := .list [.bytes [0xbe, 0xef], .int 2]

def insertDeposit : Nat := 3000000
def terminateDeposit : Nat := 2000000

def envelopeFor (key : Key) (payload : PlutusData) : Envelope :=
  { control := { version := envelopeVersion, registry := app0.registry, activePolicy := 8
               , key := key, controller := controller, deposit := insertDeposit }
  , payload := payload }

def insertRequest (key : Key) (e : Envelope) : Request :=
  { edge := .insertActive, key := key, owner := controller, deposit := insertDeposit
  , output := destinationOf app0 e }

def terminateRequest (key : Key) : Request :=
  { edge := .updateTerminal, key := key, owner := controller, deposit := terminateDeposit }

def insertKey (key : Key) : List AppAction :=
  let e := envelopeFor key payload0
  [.bookInsert (insertRequest key e) e [controller], .foldInsert key]

def successorOf (key : Key) (payload : PlutusData) (lovelace : Nat) : Successor :=
  { address := appAddress app0, lovelace := lovelace, assets := [((.active, key), 1)]
  , envelope := envelopeFor key payload }

/-- The controller's payment covering both floors of one release. -/
def paid (amount : Nat) : List TxOutput := [ownerOutput controller amount]

def scenario (name kind statement : String) (mutates : Option String)
    (actions : List AppAction) (asset : StateAsset := app0.registry) : Scenario :=
  { name, kind, statement, mutates, app := app0, config := cfg0, asset, actions }

/-- Book and fold the termination of key 5, whose output reference is `ref`. -/
def terminate5 (ref : Nat) (outs : List TxOutput) : List AppAction :=
  [.bookTerminate (terminateRequest 5) ref [controller],
   .foldRelease [5] (.fold .updateTerminal) outs]

def corpus : List Scenario :=
  [ scenario "lifecycle" "witness" "insertion_binds_envelope" none
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 insertDeposit] [controller]] ++
        terminate5 1 (paid (insertDeposit + terminateDeposit)))
  , scenario "update-between-booking-and-fold" "witness" "release_settles_additively" none
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller],
        .update 0 [successorOf 5 payload1 insertDeposit] [controller],
        .foldRelease [5] (.fold .updateTerminal) (paid (insertDeposit + terminateDeposit))])
  , scenario "update-unsigned" "mutant" "update_requires_controller" (some "signatures")
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 insertDeposit] [stranger]])
  , scenario "update-alters-control" "mutant" "update_preserves_custody" (some "control.deposit")
      (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with
        envelope := { envelopeFor 5 payload1 with
          control := { (envelopeFor 5 payload1).control with deposit := 1 } } }] [controller]])
  , scenario "update-token-escape" "mutant" "update_preserves_custody" (some "successor.address")
      (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with address := stranger }]
        [controller]])
  , scenario "update-short-deposit" "mutant" "update_preserves_custody" (some "successor.lovelace")
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 (insertDeposit - 1)] [controller]])
  , scenario "update-drops-token" "mutant" "update_preserves_custody" (some "successor.assets")
      (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with assets := [] }]
        [controller]])
  , scenario "early-withdrawal" "mutant" "withdraw_inversion" (some "no release")
      (insertKey 5 ++ [.withdraw 0 (paid insertDeposit)])
  , scenario "release-by-reject" "mutant" "release_only_updateTerminal" (some "exit")
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller],
        .foldRelease [5] .reject (paid (insertDeposit + terminateDeposit))])
  , scenario "release-by-deleteActive" "mutant" "release_only_updateTerminal" (some "exit")
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller],
        .foldRelease [5] (.fold .deleteActive) (paid (insertDeposit + terminateDeposit))])
  , scenario "release-without-booking" "mutant" "foldRelease_inversion" (some "booking")
      (insertKey 5 ++ [.foldRelease [5] (.fold .updateTerminal) (paid (insertDeposit + terminateDeposit))])
  , scenario "release-each-floor-not-sum" "mutant" "release_settles_additively"
      (some "outputs: max of the two floors")
      (insertKey 5 ++ terminate5 0 (paid insertDeposit))
  , scenario "release-unrelated-registry" "mutant" "foldRelease_inversion" (some "registry asset")
      (insertKey 5 ++ terminate5 0 (paid (insertDeposit + terminateDeposit)))
      { policy := 50, assetName := 52 }
  , scenario "two-releases-one-controller" "witness" "release_settles_additively" none
      (insertKey 5 ++ insertKey 6 ++
        [.bookTerminate (terminateRequest 5) 0 [controller],
         .bookTerminate (terminateRequest 6) 1 [controller],
         .foldRelease [5, 6] (.fold .updateTerminal)
           (paid (2 * (insertDeposit + terminateDeposit)))])
  , scenario "two-releases-short-by-one" "mutant" "release_settles_additively" (some "outputs")
      (insertKey 5 ++ insertKey 6 ++
        [.bookTerminate (terminateRequest 5) 0 [controller],
         .bookTerminate (terminateRequest 6) 1 [controller],
         .foldRelease [5, 6] (.fold .updateTerminal)
           (paid (2 * (insertDeposit + terminateDeposit) - 1))])
  , scenario "booking-unsigned" "mutant" "bookInsert_inversion" (some "signatures")
      [.bookInsert (insertRequest 5 (envelopeFor 5 payload0)) (envelopeFor 5 payload0) [stranger]]
  , scenario "booking-other-destination" "mutant" "bookInsert_inversion" (some "request.output")
      [.bookInsert { insertRequest 5 (envelopeFor 5 payload0) with output := 99 }
        (envelopeFor 5 payload0) [controller]]
  , scenario "booking-deposit-mismatch" "mutant" "bookInsert_inversion" (some "request.deposit")
      [.bookInsert { insertRequest 5 (envelopeFor 5 payload0) with deposit := insertDeposit + 1 }
        (envelopeFor 5 payload0) [controller]]
  , scenario "terminate-booking-by-stranger" "mutant" "bookTerminate_inversion" (some "owner")
      (insertKey 5 ++ [.bookTerminate { terminateRequest 5 with owner := stranger } 0 [stranger]])
  , scenario "duplicate-insertion" "mutant" "duplicate_refused_by_registry" (some "leaf Active")
      (insertKey 5 ++ insertKey 5)
  , scenario "resurrection" "mutant" "resurrection_refused_by_registry" (some "leaf Terminal")
      (insertKey 5 ++ terminate5 0 (paid (insertDeposit + terminateDeposit)) ++ insertKey 5)
  ]

def corpusJson : Json := Json.arr (corpus.map runScenario).toArray

/-! ## Ledgers: creator claims, not certified coverage -/

def statementNames : List (String × String) :=
  [ ("bookInsert_inversion", "inversion"), ("foldInsert_inversion", "inversion")
  , ("update_inversion", "inversion"), ("bookTerminate_inversion", "inversion")
  , ("foldRelease_inversion", "inversion"), ("withdraw_inversion", "inversion")
  , ("update_requires_controller", "authorization"), ("update_preserves_custody", "custody")
  , ("update_payload_free", "payload"), ("update_keeps_registry", "composition")
  , ("insertion_binds_envelope", "evidence-binding"), ("bookTerminate_keeps_locked", "custody")
  , ("release_is_terminal_fold", "terminality"), ("release_only_updateTerminal", "refusal")
  , ("release_settles_additively", "value"), ("duplicate_refused_by_registry", "refusal")
  , ("resurrection_refused_by_registry", "terminality"), ("fold_signers_unchanged", "authorization") ]

def theoremLedger : Json :=
  Json.arr (statementNames.map fun (name, cls) =>
    Json.mkObj [("statement", toJson s!"OpenDatumApplication.Statements.{name}")
      , ("class", toJson cls), ("status", "stated-unproved")
      , ("scenarios", toJson ((corpus.filter (·.statement == name)).map (·.name)))]).toArray

def atoms : List (String × String × String) :=
  [ ("A1", "authorization", "only the controller's signature admits an update or a booking")
  , ("A2", "evidence-binding", "the insertion approval's destination binds this contract and the envelope hash")
  , ("A3", "value", "the protected deposit equals the insertion request's deposit and is never below it at the contract")
  , ("A4", "custody", "the token stays at the contract through updates and termination booking")
  , ("A5", "refusal", "no spend other than update and release is accepted")
  , ("A6", "terminality", "release happens only in the registry's accepted updateTerminal fold of the same key")
  , ("A7", "value", "each controller receives the sum of registry payments and released deposits")
  , ("A8", "composition", "duplicate insertion and resurrection are refused by the registry fold, not the application")
  , ("A9", "composition", "payload updates leave the registry state unchanged") ]

def atomLedger : Json :=
  Json.arr (atoms.map fun (id, cls, text) =>
    Json.mkObj [("atom", toJson id), ("class", toJson cls), ("claim", toJson text)]).toArray

end OpenDatumApplication.Driver
