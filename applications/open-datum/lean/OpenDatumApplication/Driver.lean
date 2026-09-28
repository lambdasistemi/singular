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

def selectionToJson (sel : List (Edge × Key)) : Json :=
  Json.arr (sel.map fun s => Json.mkObj [("edge", toJson s.1), ("key", toJson s.2)]).toArray

def selectionFromJson (j : Json) : Except String (List (Edge × Key)) := do
  (← j.getArr?).toList.mapM fun s => do
    pure (← s.getObjValAs? Edge "edge", ← s.getObjValAs? Nat "key")

def actionToJson : AppAction → Json
  | .bookInsert r e sigs => Json.mkObj [("action", "bookInsert"), ("request", requestToJson r)
      , ("envelope", envelopeToJson e), ("signatures", toJson sigs)]
  | .bookTerminate r ref sigs => Json.mkObj [("action", "bookTerminate")
      , ("request", requestToJson r), ("ref", toJson ref), ("signatures", toJson sigs)]
  | .bookOther r sigs => Json.mkObj [("action", "bookOther"), ("request", requestToJson r)
      , ("signatures", toJson sigs)]
  | .update ref succs sigs => Json.mkObj [("action", "update"), ("ref", toJson ref)
      , ("successors", Json.arr (succs.map successorToJson).toArray), ("signatures", toJson sigs)]
  | .fold sel outs => Json.mkObj [("action", "fold"), ("selected", selectionToJson sel)
      , ("outputs", paymentsToJson outs)]
  | .reject edge key outs => Json.mkObj [("action", "reject"), ("edge", toJson edge)
      , ("key", toJson key), ("outputs", paymentsToJson outs)]
  | .withdraw ref outs => Json.mkObj [("action", "withdraw"), ("ref", toJson ref)
      , ("outputs", paymentsToJson outs)]

def actionFromJson (j : Json) : Except String AppAction := do
  match ← j.getObjValAs? String "action" with
  | "bookInsert" => pure (.bookInsert (← requestFromJson (← j.getObjVal? "request"))
      (← envelopeFromJson (← j.getObjVal? "envelope")) (← j.getObjValAs? (List Nat) "signatures"))
  | "bookTerminate" => pure (.bookTerminate (← requestFromJson (← j.getObjVal? "request"))
      (← j.getObjValAs? Nat "ref") (← j.getObjValAs? (List Nat) "signatures"))
  | "bookOther" => pure (.bookOther (← requestFromJson (← j.getObjVal? "request"))
      (← j.getObjValAs? (List Nat) "signatures"))
  | "update" => pure (.update (← j.getObjValAs? Nat "ref")
      (← (← j.getObjValAs? (Array Json) "successors").toList.mapM successorFromJson)
      (← j.getObjValAs? (List Nat) "signatures"))
  | "fold" => pure (.fold (← selectionFromJson (← j.getObjVal? "selected"))
      (← paymentsFromJson (← j.getObjVal? "outputs")))
  | "reject" => pure (.reject (← j.getObjValAs? Edge "edge") (← j.getObjValAs? Nat "key")
      (← paymentsFromJson (← j.getObjVal? "outputs")))
  | "withdraw" => pure (.withdraw (← j.getObjValAs? Nat "ref")
      (← paymentsFromJson (← j.getObjVal? "outputs")))
  | other => throw s!"unknown action: {other}"

def outputToJson (o : AppOutput) : Json :=
  Json.mkObj [("ref", toJson o.ref), ("address", toJson o.address), ("lovelace", toJson o.lovelace)
    , ("assets", assetsToJson o.assets), ("envelope", envelopeToJson o.envelope)
    , ("envelopeHash", toJson (envelopeHash o.envelope))]

/-- A world as each step publishes it: the registry, the live outputs, the
booked requests with the signers the registry requires of each, and the last
fold's mint. -/
def worldToJson (w : World) : Json :=
  Json.mkObj [("registry", toJson w.registry)
    , ("registryAsset", toJson w.registryAsset)
    , ("outputs", Json.arr (w.outputs.map outputToJson).toArray)
    , ("pending", Json.arr (w.pending.map fun p =>
        Json.mkObj [("request", requestToJson p.request)
          , ("requiredSigners", toJson (requiredSigners p.request))]).toArray)
    , ("nextRef", toJson w.nextRef)
    , ("lastMint", assetsToJson w.lastMint)]

/-! ## Scenarios and the runner -/

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
  pure { name := ← j.getObjValAs? String "name", kind := ← j.getObjValAs? String "kind"
       , statements := ← j.getObjValAs? (List String) "statements"
       , app := ← j.getObjValAs? App "app", config := ← j.getObjValAs? Config "config"
       , asset := ← j.getObjValAs? StateAsset "asset"
       , actions := ← (← j.getObjValAs? (Array Json) "actions").toList.mapM actionFromJson }

/-- The executable observation of `AppConsistent` at the invariant boundary,
conjunct by conjunct: the registry through the root driver's own finite
`Singular.Driver.consistentB`, then the output, occurrence, key and booking
clauses. Its correspondence with `AppConsistent` is a stated obligation
(`appConsistentB_iff`), not an assumption. `checkOccurrences := false` is the
weakened observation the check's control uses to show the occurrence clause is
what excludes a duplicated inventory. -/
def appConsistentBWith (checkOccurrences : Bool) (w : World) : Bool :=
  Singular.Driver.consistentB w.registry &&
  (!checkOccurrences ||
    (w.outputs.map (·.ref)).eraseDups.length == w.outputs.length) &&
  w.outputs.all (fun o =>
    o.address == appAddress w.app &&
    o.assets == [((.active, o.envelope.control.key), 1)] &&
    o.envelope.control.registry == w.registryAsset &&
    decide (o.envelope.control.deposit ≤ o.lovelace) &&
    trieGet w.registry.trie o.envelope.control.key == .known .active &&
    decide (o.ref < w.nextRef)) &&
  w.outputs.all (fun o₁ => w.outputs.all fun o₂ =>
    !(o₁.envelope.control.key == o₂.envelope.control.key || o₁.ref == o₂.ref) || o₁ == o₂) &&
  w.pending.all (fun p =>
    match p.request.edge, p.envelope with
    | .insertActive, some e =>
      p.request.output == destinationOf w.app e && e.control.deposit == p.request.deposit &&
        e.control.key == p.request.key && e.control.registry == w.registryAsset
    | .updateTerminal, none => true
    | _, _ => false)

/-- The invariant observation itself. -/
def appConsistentB : World → Bool := appConsistentBWith true

def stepToJson : Except String World → Json
  | .ok w => Json.mkObj [("outcome", "accepted"), ("consistent", toJson (appConsistentB w))
      , ("world", worldToJson w)]
  | .error why => Json.mkObj [("outcome", "refused"), ("reason", toJson why)]

/-- The one surface: run a scenario's actions through the law from genesis,
publishing every step's outcome and, for an accepted step, the world it reached. -/
def runScenarioWith (law : Law) (s : Scenario) : Json :=
  Json.mkObj [("scenario", scenarioToJson s)
    , ("genesisConsistent", toJson (appConsistentB (genesis s.app s.config s.asset)))
    , ("steps", Json.arr ((runActionsWith law (genesis s.app s.config s.asset) s.actions).map
        stepToJson).toArray)]

def runScenario : Scenario → Json := runScenarioWith Law.standard

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

def payload2 : PlutusData := .map [(.int 0, .constr 3 []), (.bytes [], .bytes [0xff])]

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

def bookInsertKey (key : Key) : AppAction :=
  let e := envelopeFor key payload0
  .bookInsert (insertRequest key e) e [controller]

def insertKey (key : Key) : List AppAction :=
  [bookInsertKey key, .fold [(.insertActive, key)] []]

def successorOf (key : Key) (payload : PlutusData) (lovelace : Nat) : Successor :=
  { address := appAddress app0, lovelace := lovelace, assets := [((.active, key), 1)]
  , envelope := envelopeFor key payload }

/-- A payment output at the controller's key. -/
def paid (amount : Nat) : List TxOutput := [ownerOutput controller amount]

def scenario (name kind : String) (statements : List String) (actions : List AppAction)
    (asset : StateAsset := app0.registry) : Scenario :=
  { name, kind, statements, app := app0, config := cfg0, asset, actions }

/-- An envelope naming a registry other than the one the world carries. -/
def otherRegistryEnvelope : Envelope :=
  { envelopeFor 5 payload0 with
    control := { (envelopeFor 5 payload0).control with registry := { policy := 50, assetName := 52 } } }

/-- Book and fold the termination of key 5, whose output reference is `ref`. -/
def terminate5 (ref : Nat) (outs : List TxOutput) : List AppAction :=
  [.bookTerminate (terminateRequest 5) ref [controller], .fold [(.updateTerminal, 5)] outs]

def corpus : List Scenario :=
  [ scenario "lifecycle" "witness"
      [ "bookInsert_inversion", "fold_inversion", "appStep_fold", "insertion_binds_envelope"
      , "insertion_requires_registry_identity", "update_inversion", "update_keeps_registry"
      , "update_preserves_custody", "bookTerminate_inversion", "bookTerminate_keeps_locked"
      , "release_burns_atomically", "fold_settles_additively", "fold_signers_unchanged"
      , "genesis_consistent", "appStep_preserves_consistent", "reachable_consistent"
      , "consistent_occurrences_distinct", "bookInsert_preserves_consistent"
      , "fold_preserves_consistent", "update_preserves_consistent"
      , "bookTerminate_preserves_consistent" ]
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 insertDeposit] [controller]] ++
        terminate5 1 (paid (insertDeposit + terminateDeposit)))
  , scenario "update-payload-a" "witness" ["update_payload_free"]
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 insertDeposit] [controller]])
  , scenario "update-payload-b" "witness" ["update_payload_free"]
      (insertKey 5 ++ [.update 0 [successorOf 5 payload2 insertDeposit] [controller]])
  , scenario "update-between-booking-and-fold" "witness"
      ["fold_settles_additively", "update_preserves_custody", "release_burns_atomically"]
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller],
        .update 0 [successorOf 5 payload1 insertDeposit] [controller],
        .fold [(.updateTerminal, 5)] (paid (insertDeposit + terminateDeposit))])
  , scenario "mixed-batch-one-controller" "witness"
      ["fold_settles_additively", "release_burns_atomically", "insertion_binds_envelope"
      , "fold_preserves_consistent"]
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller], bookInsertKey 6,
        .fold [(.updateTerminal, 5), (.insertActive, 6)] (paid (insertDeposit + terminateDeposit))])
  , scenario "mixed-batch-short-by-one" "adverse-input" ["fold_settles_additively"]
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller], bookInsertKey 6,
        .fold [(.updateTerminal, 5), (.insertActive, 6)]
          (paid (insertDeposit + terminateDeposit - 1))])
  , scenario "two-releases-one-controller" "witness" ["fold_settles_additively", "release_burns_atomically"]
      (insertKey 5 ++ insertKey 6 ++
        [.bookTerminate (terminateRequest 5) 0 [controller],
         .bookTerminate (terminateRequest 6) 1 [controller],
         .fold [(.updateTerminal, 5), (.updateTerminal, 6)]
           (paid (2 * (insertDeposit + terminateDeposit)))])
  , scenario "two-releases-short-by-one" "adverse-input" ["fold_settles_additively"]
      (insertKey 5 ++ insertKey 6 ++
        [.bookTerminate (terminateRequest 5) 0 [controller],
         .bookTerminate (terminateRequest 6) 1 [controller],
         .fold [(.updateTerminal, 5), (.updateTerminal, 6)]
           (paid (2 * (insertDeposit + terminateDeposit) - 1))])
  , scenario "release-each-floor-not-sum" "adverse-input" ["fold_settles_additively"]
      (insertKey 5 ++ terminate5 0 (paid insertDeposit))
  , scenario "update-unsigned" "adverse-input" ["update_requires_controller", "update_inversion"]
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 insertDeposit] [stranger]])
  , scenario "update-alters-control" "adverse-input" ["update_preserves_custody", "update_inversion"]
      (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with
        envelope := { envelopeFor 5 payload1 with
          control := { (envelopeFor 5 payload1).control with deposit := 1 } } }] [controller]])
  , scenario "update-token-escape" "adverse-input" ["update_preserves_custody", "update_inversion"]
      (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with address := stranger }]
        [controller]])
  , scenario "update-short-deposit" "adverse-input" ["update_preserves_custody", "update_inversion"]
      (insertKey 5 ++ [.update 0 [successorOf 5 payload1 (insertDeposit - 1)] [controller]])
  , scenario "update-drops-token" "adverse-input" ["update_preserves_custody", "update_inversion"]
      (insertKey 5 ++ [.update 0 [{ successorOf 5 payload1 insertDeposit with assets := [] }]
        [controller]])
  , scenario "early-withdrawal" "adverse-input" ["withdraw_inversion", "only_fold_releases"]
      (insertKey 5 ++ [.withdraw 0 (paid insertDeposit)])
  , scenario "reject-keeps-locked" "witness"
      ["reject_inversion", "only_fold_releases", "withdraw_inversion", "reject_preserves_consistent"]
      (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller],
        .reject .updateTerminal 5 (paid terminateDeposit), .withdraw 0 (paid insertDeposit)])
  , scenario "book-deleteActive" "adverse-input" ["bookOther_refused"]
      (insertKey 5 ++ [.bookOther { terminateRequest 5 with edge := .deleteActive } [controller]])
  , scenario "release-without-booking" "adverse-input" ["fold_inversion"]
      (insertKey 5 ++ [.fold [(.updateTerminal, 5)] (paid (insertDeposit + terminateDeposit))])
  , scenario "registry-asset-other-name" "adverse-input" ["insertion_requires_registry_identity"]
      (insertKey 5) { policy := 50, assetName := 52 }
  , scenario "registry-asset-other-policy" "adverse-input" ["insertion_requires_registry_identity"]
      (insertKey 5) { policy := 60, assetName := 51 }
  , scenario "envelope-names-other-registry" "adverse-input" ["insertion_requires_registry_identity"]
      [.bookInsert (insertRequest 5 otherRegistryEnvelope) otherRegistryEnvelope [controller]]
  , scenario "booking-unsigned" "adverse-input" ["bookInsert_inversion"]
      [.bookInsert (insertRequest 5 (envelopeFor 5 payload0)) (envelopeFor 5 payload0) [stranger]]
  , scenario "booking-other-destination" "adverse-input" ["bookInsert_inversion"]
      [.bookInsert { insertRequest 5 (envelopeFor 5 payload0) with output := 99 }
        (envelopeFor 5 payload0) [controller]]
  , scenario "booking-deposit-mismatch" "adverse-input" ["bookInsert_inversion"]
      [.bookInsert { insertRequest 5 (envelopeFor 5 payload0) with deposit := insertDeposit + 1 }
        (envelopeFor 5 payload0) [controller]]
  , scenario "terminate-booking-by-stranger" "adverse-input" ["bookTerminate_inversion"]
      (insertKey 5 ++ [.bookTerminate { terminateRequest 5 with owner := stranger } 0 [stranger]])
  , scenario "duplicate-insertion" "adverse-input" ["duplicate_refused_by_registry"]
      (insertKey 5 ++ insertKey 5)
  , scenario "resurrection" "adverse-input" ["resurrection_refused_by_registry"]
      (insertKey 5 ++ terminate5 0 (paid (insertDeposit + terminateDeposit)) ++ insertKey 5)
  ]

/-! ## The invariant boundary

The occurrence clause of `AppConsistent` excludes an inventory holding one
output twice. The two worlds below exhibit it: the ordinary world reached by
inserting key 5, and the same world with its one output occurrence duplicated —
a world no action reaches, which the previous invariant admitted. On each the
boundary publishes the invariant observation and the outcome of the same signed
update: on the duplicate the update is accepted and leaves two different outputs
of one key, the old counterexample, now outside the preservation domain because
its starting world is not consistent. -/

/-- The world reached by these actions from this corpus's genesis, keeping the
world through a refused action. -/
def reachWorld (actions : List AppAction) : World :=
  actions.foldl (fun w a => match appStep w a with
    | .ok w' => w'
    | .error _ => w) (genesis app0 cfg0 app0.registry)

def ordinaryWorld : World := reachWorld (insertKey 5)

def duplicatedWorld : World :=
  { ordinaryWorld with outputs := ordinaryWorld.outputs ++ ordinaryWorld.outputs }

def boundaryUpdate : AppAction := .update 0 [successorOf 5 payload1 insertDeposit] [controller]

/-- One boundary world: whether actions reach it, its invariant observation,
the weakened observation without the occurrence clause, and the update. -/
structure BoundaryWorld where
  name : String
  reached : Bool
  statements : List String
  world : World

def boundaryWorlds : List BoundaryWorld :=
  [ { name := "ordinary-after-insert", reached := true, world := ordinaryWorld
    , statements := ["consistent_occurrences_distinct", "appConsistentB_iff", "update_preserves_consistent"] }
  , { name := "identical-duplicate-occurrence", reached := false, world := duplicatedWorld
    , statements := ["duplicate_occurrence_outside_invariant", "appConsistentB_iff"] } ]

def boundaryUpdateJson (w : World) : Json :=
  match appStep w boundaryUpdate with
  | .ok w' => Json.mkObj [("outcome", "accepted"), ("consistentAfter", toJson (appConsistentB w'))
      , ("world", worldToJson w')]
  | .error why => Json.mkObj [("outcome", "refused"), ("reason", toJson why)]

def boundaryToJson (b : BoundaryWorld) : Json :=
  Json.mkObj [("name", toJson b.name), ("reached", toJson b.reached)
    , ("statements", toJson b.statements)
    , ("consistent", toJson (appConsistentB b.world))
    , ("consistentWithoutOccurrenceClause", toJson (appConsistentBWith false b.world))
    , ("world", worldToJson b.world), ("update", boundaryUpdateJson b.world)]

def corpusWith (law : Law) : Json :=
  Json.mkObj [("scenarios", Json.arr (corpus.map (runScenarioWith law)).toArray)
    , ("invariantBoundary", Json.arr (boundaryWorlds.map boundaryToJson).toArray)]

def corpusJson : Json := corpusWith Law.standard

/-! ## Ledgers: creator claims, not certified coverage -/

def statementNames : List (String × String) :=
  [ ("bookInsert_inversion", "inversion"), ("bookTerminate_inversion", "inversion")
  , ("bookOther_refused", "inversion"), ("update_inversion", "inversion")
  , ("fold_inversion", "inversion"), ("appStep_fold", "inversion")
  , ("reject_inversion", "inversion"), ("withdraw_inversion", "inversion")
  , ("genesis_consistent", "invariant"), ("appStep_preserves_consistent", "invariant")
  , ("reachable_consistent", "invariant"), ("consistent_occurrences_distinct", "invariant")
  , ("duplicate_occurrence_outside_invariant", "invariant"), ("appConsistentB_iff", "invariant")
  , ("bookInsert_preserves_consistent", "invariant"), ("bookTerminate_preserves_consistent", "invariant")
  , ("update_preserves_consistent", "invariant"), ("fold_preserves_consistent", "invariant")
  , ("reject_preserves_consistent", "invariant")
  , ("update_requires_controller", "authorization"), ("update_preserves_custody", "custody")
  , ("update_payload_free", "payload"), ("update_keeps_registry", "composition")
  , ("insertion_requires_registry_identity", "evidence-binding")
  , ("insertion_binds_envelope", "evidence-binding"), ("bookTerminate_keeps_locked", "custody")
  , ("release_burns_atomically", "terminality"), ("only_fold_releases", "refusal")
  , ("fold_settles_additively", "value"), ("duplicate_refused_by_registry", "refusal")
  , ("resurrection_refused_by_registry", "terminality"), ("fold_signers_unchanged", "authorization") ]

def theoremLedger : Json :=
  Json.arr (statementNames.map fun (name, cls) =>
    Json.mkObj [("statement", toJson s!"OpenDatumApplication.Statements.{name}")
      , ("class", toJson cls), ("status", "stated-unproved")
      , ("scenarios", toJson ((corpus.filter (·.statements.contains name)).map (·.name)))
      , ("boundary", toJson ((boundaryWorlds.filter (·.statements.contains name)).map (·.name)))]).toArray

def atoms : List (String × String × String) :=
  [ ("A1", "authorization", "only the controller's signature admits an update or a booking")
  , ("A2", "evidence-binding", "the insertion approval's destination binds this contract and the envelope hash; the envelope and the application name the actual registry state asset")
  , ("A3", "value", "the protected deposit equals the insertion request's deposit and is never below it at the contract")
  , ("A4", "custody", "the token stays at the contract through updates, termination booking and rejects")
  , ("A5", "refusal", "no spend other than update and fold is accepted, and no uncertified edge is booked")
  , ("A6", "terminality", "a release happens only in the registry's accepted fold of the same key's updateTerminal, whose own mint burns exactly that key's active token")
  , ("A7", "value", "each recipient receives the sum of every selected request's registry payment and every released deposit owed to it")
  , ("A8", "composition", "duplicate insertion and resurrection are refused by the registry fold, not the application")
  , ("A9", "composition", "payload updates leave the registry and the bookings unchanged")
  , ("A10", "custody", "the inventory holds each output occurrence once: references are pairwise distinct and no key has two live outputs") ]

def atomLedger : Json :=
  Json.arr (atoms.map fun (id, cls, text) =>
    Json.mkObj [("atom", toJson id), ("class", toJson cls), ("claim", toJson text)]).toArray

def ledgersJson : Json := Json.mkObj [("theorems", theoremLedger), ("atoms", atomLedger)]

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
  , ("per-floor-settlement", { additiveSettlement := false }) ]

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
