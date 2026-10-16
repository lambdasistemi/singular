import DriverMain.Fixtures

/-! Protected-rejection truth table and evidence controls. -/

open Lean
open Singular
open Singular.Driver

/-- Truth table for the two admitted edges, plus one row per excluded tag at unknown. -/
def rejectionTable : List (Scenario × Bool) :=
  [ (protectedScenario "PR-table-insertActive-unknown" s0 [] rejInsertUnknown
      (some (rejectionFor s0 rejInsertUnknown (.mismatch .unknown) 0 1)), false)
  , (protectedScenario "PR-table-insertActive-absent" absentState [] rejInsertAbsent
      (some (rejectionFor absentState rejInsertAbsent (.mismatch (.known .absent)) 0 1)), true)
  , (protectedScenario "PR-table-insertActive-active" s0 rejActiveSetup (request .insertActive 5 42 99 0 55)
      (some (rejectionFor rejActiveState (request .insertActive 5 42 99 0 55) (.mismatch (.known .active)) 0 1)), true)
  , (protectedScenario "PR-table-insertActive-terminal" s0 rejTerminalSetup (request .insertActive 5 42 99 0 55)
      (some (rejectionFor rejTerminalState (request .insertActive 5 42 99 0 55) (.mismatch (.known .terminal)) 0 1)), true)
  , (protectedScenario "PR-table-updateTerminal-unknown" s0 [] rejUpdateUnknown
      (some (rejectionFor s0 rejUpdateUnknown (.mismatch .unknown) 0 1)), true)
  , (protectedScenario "PR-table-updateTerminal-absent" absentState [] rejUpdateAbsent
      (some (rejectionFor absentState rejUpdateAbsent (.mismatch (.known .absent)) 0 1)), true)
  , (protectedScenario "PR-table-updateTerminal-active" s0 rejActiveSetup (request .updateTerminal 5 42 99 0 55)
      (some (rejectionFor rejActiveState (request .updateTerminal 5 42 99 0 55) (.mismatch (.known .active)) 0 1)), false)
  , (protectedScenario "PR-table-updateTerminal-terminal" s0 rejTerminalSetup (request .updateTerminal 5 42 99 0 55)
      (some (rejectionFor rejTerminalState (request .updateTerminal 5 42 99 0 55) (.mismatch (.known .terminal)) 0 1)), true)
  , (protectedScenario "PR-table-insertAbsent-unknown" s0 [] (request .insertAbsent 5 42 99 0 55)
      (some (rejectionFor s0 (request .insertAbsent 5 42 99 0 55) (.mismatch .unknown) 0 1)), true)
  , (protectedScenario "PR-table-updateActive-unknown" s0 [] (request .updateActive 5 42 99 0 55)
      (some (rejectionFor s0 (request .updateActive 5 42 99 0 55) (.mismatch .unknown) 0 1)), true)
  , (protectedScenario "PR-table-deleteAbsent-unknown" s0 [] (request .deleteAbsent 5 42 99 0 55)
      (some (rejectionFor s0 (request .deleteAbsent 5 42 99 0 55) (.mismatch .unknown) 0 1)), true)
  , (protectedScenario "PR-table-deleteActive-unknown" s0 [] (request .deleteActive 5 42 99 0 55)
      (some (rejectionFor s0 (request .deleteActive 5 42 99 0 55) (.mismatch .unknown) 0 1)), true)
  , (protectedScenario "PR-table-witnessTerminal-unknown" s0 [] (request .witnessTerminal 5 42 99 0 55)
      (some (rejectionFor s0 (request .witnessTerminal 5 42 99 0 55) (.mismatch .unknown) 0 1)), true) ]

def expiryReq : Request := { request .insertActive 5 42 99 0 55 with submittedAt := 10000 }

/-- Three time positions with the one-instant boundary either side of expiry. -/
def rejectionTimes : List (Scenario × Option String) :=
  [ (protectedScenario "PR-expiry-before-processing" sTimed [] expiryReq
      (some (rejectionFor sTimed expiryReq .expired 10500 10501)), some "reject-not-expired")
  , (protectedScenario "PR-expiry-inside-reclaim" sTimed [] expiryReq
      (some (rejectionFor sTimed expiryReq .expired 11200 11201)), some "reject-not-expired")
  , (protectedScenario "PR-expiry-one-before" sTimed [] expiryReq
      (some (rejectionFor sTimed expiryReq .expired 11499 11500)), some "reject-not-expired")
  , (protectedScenario "PR-expiry-at-threshold" sTimed [] expiryReq
      (some (rejectionFor sTimed expiryReq .expired 11500 11501)), none) ]

def mismatchReq : Request := request .insertActive 5 42 99 0 55
def mismatchState : RegistryState := rejActiveState
def mismatchGood : RejectWitness := rejectionFor mismatchState mismatchReq (.mismatch (.known .active)) 0 1

/-- Every refusal reason with its binding failure. -/
def rejectionControls : List (Scenario × Option String) :=
  [ (protectedScenario "PR-refuse-registry" s0 rejActiveSetup mismatchReq
      (some { mismatchGood with evidence := { mismatchGood.evidence with registry := s0.config } }),
      some "reject-registry-mismatch")
  , (protectedScenario "PR-refuse-request" s0 rejActiveSetup mismatchReq
      (some { mismatchGood with evidence := { mismatchGood.evidence with request := { mismatchReq with reference := 99 } } }),
      some "reject-request-mismatch")
  , (protectedScenario "PR-refuse-interval" s0 rejActiveSetup mismatchReq
      (some (rejectionFor mismatchState mismatchReq (.mismatch (.known .active)) 1 1)),
      some "reject-invalid-interval")
  , (protectedScenario "PR-refuse-leaf" s0 rejActiveSetup mismatchReq
      (some (rejectionFor mismatchState mismatchReq (.mismatch .unknown) 0 1)),
      some "reject-leaf-mismatch") ]

#guard rejectionTable.length == 13
#guard rejectionTable.all fun (sc, expected) =>
  let result := (runSurface sc).2
  result.premiseChecked && result.outcome == (if expected then .accepted else .refused) &&
    result.reason == (if expected then none else some "reject-compatible")
#guard rejectionTimes.all fun (sc, reason) =>
  let result := (runSurface sc).2
  result.premiseChecked && result.reason == reason &&
    result.outcome == (if reason.isNone then .accepted else .refused)
#guard rejectionControls.all fun (sc, reason) =>
  let result := (runSurface sc).2
  result.premiseChecked && result.reason == reason &&
    result.outcome == (if reason.isNone then .accepted else .refused)
