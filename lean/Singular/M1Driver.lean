import Singular.Driver
import Singular.M1

/-! Executable observation surface of the fixed permanent contract. Setup and
exits both use M1; refused setup is unsupported, not validator evidence. Shared
serialization, settlement and observation definitions remain the broader ones. -/
namespace Singular.M1Driver
open Lean Singular.Driver

def runSetup : RegistryState → List Request → (List SetupStep × RegistryState × Bool)
  | s, [] => ([], s, true)
  | s, r :: rest =>
    match M1.step s r with
    | .error why =>
      ([{ request := r, accepted := false, reason := some why, state := s }], s, false)
    | .ok res =>
      let (steps, final, ok) := runSetup res.state rest
      ({ request := r, accepted := true, reason := none, state := res.state } :: steps, final, ok)

def runSurface (sc : Scenario) : List SetupStep × DriverResult :=
  let (steps, s, reached) := runSetup sc.start sc.setup
  if !reached then
    (steps, { outcome := .unsupported, reason := some "setup-refused"
            , premiseChecked := false, observations := none })
  else if !consistentB s then
    (steps, { outcome := .unsupported, reason := some "premise-does-not-hold"
            , premiseChecked := false, observations := none })
  else
    match admissionWitness sc with
    | none =>
      (steps, { outcome := .unsupported, reason := some "retraction-without-witness"
              , premiseChecked := true, observations := none })
    | some witness =>
    match M1.admittedExitStep s sc.exit sc.request witness with
    | .error why =>
      (steps, { outcome := .refused, reason := some why
              , premiseChecked := true, observations := none })
    | .ok res =>
      match M1.admittedTxOfExit s sc.exit sc.request witness sc.lovelace with
      | .error why =>
        (steps, { outcome := .unsupported, reason := some ("transaction-unbuildable: " ++ why)
                , premiseChecked := true, observations := none })
      | .ok tx =>
        (steps, { outcome := .accepted, reason := none, premiseChecked := true
                , observations := some (observationsJson s.config sc.request res tx) })

def scenarioJson (sc : Scenario) : Json :=
  let (steps, result) := runSurface sc
  Json.mkObj <|
    [ ("id", toJson sc.id)
    , ("theorem", toJson sc.theoremName)
    , ("statementSha256", toJson sc.statementSha256)
    , ("kind", toJson sc.kind)
    , ("mutates", match sc.mutates with | none => Json.null | some m => toJson m)
    , ("operation", toJson (exitName sc.exit))
    , ("requiresReachableState", toJson sc.requiresReachableState)
    , ("start", toJson sc.start)
    , ("request", toJson sc.request)
    , ("lovelace", toJson sc.lovelace) ]
    ++ (match sc.witness with | none => [] | some w => [("witness", toJson w)])
    ++
    [ ("setup", Json.arr ((steps.map setupStepJson).toArray))
    , ("outcome", toJson (outcomeName result.outcome))
    , ("reason", match result.reason with | none => Json.null | some why => toJson why)
    , ("premise", Json.mkObj
        [ ("declaration", toJson premiseDeclaration)
        , ("checked", toJson result.premiseChecked) ])
    , ("observations", match result.observations with | none => Json.null | some o => o) ]
    ++ (match sc.outputs, result.outcome with
        | some outputs, .accepted =>
          [ ("outputs", Json.arr ((outputs.map judgedOutputJson).toArray))
          , ("settle", match judgeSurface sc [] outputs with
              | none => Json.null
              | some why => toJson why) ]
        | _, _ => [])

def reachBatchStart (start : RegistryState) (setup : List Request) :
    List SetupStep × Except DriverResult RegistryState :=
  let (steps, s, reached) := runSetup start setup
  if !reached then
    (steps, .error { outcome := .unsupported, reason := some "setup-refused"
                   , premiseChecked := false, observations := none })
  else if !consistentB s then
    (steps, .error { outcome := .unsupported, reason := some "premise-does-not-hold"
                   , premiseChecked := false, observations := none })
  else (steps, .ok s)

/-- F04 `runFoldBatch`: the `foldBatch` question. From the state the setup trace
reaches, with the premise checked, the batch is `Singular.foldBatch` verbatim:
refused for its reason, or accepted with the declared batch boundary. Beside the
answer it returns the batch's step trace, each request through `Singular.step`
from the state the previous left until the first one the law refuses, so a
reader can see which request a refusal came from. -/
def runFoldBatch (start : RegistryState) (setup batch : List Request) :
    List SetupStep × List SetupStep × DriverResult :=
  match reachBatchStart start setup with
  | (steps, .error result) => (steps, [], result)
  | (steps, .ok s) =>
    let (folded, _, _) := runSetup s batch
    match M1.foldBatch s batch with
    | .error why =>
      (steps, folded, { outcome := .refused, reason := some why
                      , premiseChecked := true, observations := none })
    | .ok res =>
      (steps, folded, { outcome := .accepted, reason := none, premiseChecked := true
                      , observations := some (batchObservationsJson s.config (batchKeys batch) res) })

/-- F05 `runRejectBatch`: the `rejectBatch` question. From the state the setup
trace reaches, with the premise checked, a non-empty batch of rejects is stepped
by `rejectBatchStep` and answered with the declared batch boundary; an empty
batch, and one naming a fold or a retract, is `unsupported`. -/
def runRejectBatch (start : RegistryState) (setup : List Request) (batch : List (Exit × Request)) :
    List SetupStep × DriverResult :=
  match reachBatchStart start setup with
  | (steps, .error result) => (steps, result)
  | (steps, .ok s) =>
    match batchRejects batch with
    | none =>
      (steps, { outcome := .unsupported
              , reason := some (if batch.isEmpty then "empty-reject-batch"
                                else "reject-batch-names-another-exit")
              , premiseChecked := true, observations := none })
    | some requests =>
      match rejectBatchStep s requests with
      | .error why =>
        (steps, { outcome := .refused, reason := some why
                , premiseChecked := true, observations := none })
      | .ok res =>
        (steps, { outcome := .accepted, reason := none, premiseChecked := true
                , observations := some (batchObservationsJson s.config (batchKeys requests) res) })

def batchScenarioJson (sc : BatchScenario) : Json :=
  let (steps, folded, result, requests, settled) :
      List SetupStep × Option (List SetupStep) × DriverResult × Json × Option Json :=
    match sc.question with
    | .foldBatch batch =>
      let (steps, folded, result) := runFoldBatch sc.start sc.setup batch
      (steps, some folded, result, Json.arr (batch.map toJson).toArray, none)
    | .rejectBatch batch =>
      let (steps, result) := runRejectBatch sc.start sc.setup batch
      let settled : Option Json :=
        match sc.outputs, result.outcome, batchRejects batch with
        | some outputs, .accepted, some rejects =>
          some (match judgeRejectBatch rejects outputs with
                | none => Json.null
                | some why => toJson why)
        | _, _, _ => none
      (steps, none, result,
        Json.arr (batch.map fun (p : Exit × Request) =>
          Json.mkObj [("exit", toJson (exitName p.1)), ("request", toJson p.2)]).toArray,
        settled)
  Json.mkObj <|
    [ ("id", toJson sc.id)
    , ("theorem", toJson sc.theoremName)
    , ("statementSha256", toJson sc.statementSha256)
    , ("kind", toJson sc.kind)
    , ("mutates", match sc.mutates with | none => Json.null | some m => toJson m)
    , ("question", toJson (batchQuestionName sc.question))
    , ("requiresReachableState", toJson sc.requiresReachableState)
    , ("start", toJson sc.start)
    , ("requests", requests)
    , ("setup", Json.arr ((steps.map setupStepJson).toArray)) ]
    ++ (match folded with
        | none => []
        | some f => [("folded", Json.arr ((f.map setupStepJson).toArray))])
    ++ (match sc.outputs with
        | none => []
        | some outputs => [("outputs", Json.arr ((outputs.map judgedOutputJson).toArray))])
    ++ (match settled with | none => [] | some j => [("settle", j)])
    ++
    [ ("outcome", toJson (outcomeName result.outcome))
    , ("reason", match result.reason with | none => Json.null | some why => toJson why)
    , ("premise", Json.mkObj
        [ ("declaration", toJson premiseDeclaration)
        , ("checked", toJson result.premiseChecked) ])
    , ("observations", match result.observations with | none => Json.null | some o => o) ]

end Singular.M1Driver
