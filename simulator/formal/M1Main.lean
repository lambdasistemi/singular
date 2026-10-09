import Singular.M1
import Singular.M1Driver

open Lean Singular Singular.Driver

namespace PermanentCorpus

def config : Config :=
  { root := rootOf [], maxFee := 0, processTime := 1000, retractTime := 500
  , applicationPolicy := 7, activePolicy := 8, absentPolicy := 9, terminalPolicy := 10 }

def initial : RegistryState := { config := config, trie := [], custody := [], held := [] }

def request (edge : Edge) (key : Nat := 5) : Request :=
  let base : Request :=
    { edge := edge, key := key, owner := 42, output := 99, refundAddress := 42
    , deposit := 10, tip := 1, reference := key, datum := some 13, claimed := delta edge }
  let dest := requestDestination base
  let approval : Approval :=
    { policy := config.applicationPolicy, edge := edge, key := key, owner := base.owner
    , destination := dest, assetName := approvalAssetName edge key base.owner dest }
  { base with approval := some approval }

def witness : RetractWitness :=
  { submittedAt := 0, validFrom := 1000, validTo := 1500, signatories := [42] }

def scenario (name : String) (exit : Exit) (setup : List Request := []) : Scenario :=
  { id := name, theoremName := "Singular.M1.Statements." ++
      (match exit with
        | .reject => "reject_unchanged"
        | .retract => "retract_unchanged"
        | .fold edge => if M1.allowed edge then "allowed_step_unchanged" else "excluded_fold")
  , statementSha256 := "", kind := "witness", mutates := none
  , requiresReachableState := !setup.isEmpty, start := initial, setup := setup
  , exit := exit, request := request (match exit with | .fold e => e | _ => .insertActive)
  , lovelace := 20, witness := match exit with | .retract => some witness | _ => none }

def cases : List Scenario :=
  [scenario "Register an active key" (.fold .insertActive)
  , scenario "Terminate the registered key permanently" (.fold .updateTerminal) [request .insertActive]
  , scenario "Refuse an absent insertion" (.fold .insertAbsent)
  , scenario "Refuse activation of an absent key" (.fold .updateActive)
  , scenario "Refuse deletion of an absent key" (.fold .deleteAbsent)
  , scenario "Refuse deletion of an active key" (.fold .deleteActive) [request .insertActive]
  , scenario "Refuse terminal witnessing without approval" (.fold .witnessTerminal)
      [request .insertActive, request .updateTerminal]
  , scenario "Reject a pending registration" .reject
  , scenario "Retract a pending registration in its owner's window" .retract
  , { scenario "An excluded setup is unsupported" (.fold .updateActive) [request .insertAbsent]
      with kind := "unsupported" }].map fun sc =>
      if sc.request.edge == .witnessTerminal then { sc with request := { sc.request with approval := none } }
      else sc

def batches : List (String × List Request × Except String Result) :=
  let allowed := [request .insertActive, request .updateTerminal]
  let excluded := request .witnessTerminal
  [("Register then terminate in one atomic batch", allowed, M1.foldBatch initial allowed)
  , ("Refuse a mixed batch's excluded final member", allowed ++ [excluded],
      M1.foldBatch initial (allowed ++ [excluded]))
  , ("Refuse an excluded first member", [excluded, request .insertActive],
      M1.foldBatch initial [excluded, request .insertActive])
  , ("Refuse an empty batch", [], M1.foldBatch initial [])]

def batchJson (item : String × List Request × Except String Result) : Json :=
  let (name, requests, result) := item
  Json.mkObj [("requirement", toJson name), ("requests", toJson requests)
    , ("outcome", toJson (match result with | .ok _ => "accepted" | .error _ => "refused"))
    , ("reason", match result with | .ok _ => Json.null | .error why => toJson why)
    , ("observations", match result with
        | .ok res => batchObservationsJson config (batchKeys requests) res
        | .error _ => Json.null)]

def corpus : Json := Json.mkObj
  [("contract", toJson "permanent-m1")
  , ("declaration", toJson "Singular.M1Driver.runSurface")
  , ("observations", toJson declaredObservations)
  , ("unobservable", toJson declaredUnobservable)
  , ("scenarios", toJson (cases.map M1Driver.scenarioJson))
  , ("batches", toJson (batches.map batchJson))]

def check : IO Unit := do
  for sc in cases do
    let (_, result) := M1Driver.runSurface sc
    let expected := if sc.kind == "unsupported" then Outcome.unsupported
      else match sc.exit with
        | .fold edge => if M1.allowed edge then .accepted else .refused
        | _ => .accepted
    unless result.outcome == expected do
      throw (IO.userError s!"{sc.id}: {outcomeName result.outcome}, expected {outcomeName expected}")
  for (name, _, result) in batches do
    let expected := name == "Register then terminate in one atomic batch"
    unless (match result with | .ok _ => true | .error _ => false) == expected do
      throw (IO.userError s!"batch: {name}")

end PermanentCorpus

def main (args : List String) : IO Unit := do
  PermanentCorpus.check
  if args == ["--check"] then IO.println "Permanent M1: 10 driver scenarios and 4 batch cases checked"
  else IO.println PermanentCorpus.corpus.pretty
