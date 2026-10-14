import DriverMain.Rejection

/-! Single-request driver scenarios and their controls. -/

open Lean
open Singular
open Singular.Driver

/-- An owner output paying `lovelace` to `owner`'s key, as a caller observes it. -/
def ownerPaid (owner lovelace : Nat) : TxOutput :=
  { role := .owner, datum := .none, address := some owner, stateTokens := 0, config := none
  , commitment := none, assets := [], lovelace := lovelace }

/-- An active registration of key 5 for owner 42, routed to output 99 with no
deposit, whose request carries the datum 7. -/
def zeroDepositCarryingDatum : Request :=
  { request .insertActive 5 42 99 0 0 with datum := some 7 }

/-- The token carrier of that registration as a caller observed it: at output 99,
carrying the datum 8 inline rather than the request's 7. -/
def foreignCarrier : TxOutput :=
  { role := .destination, datum := .inline, address := some 99, stateTokens := 0
  , config := none, commitment := none, assets := [], lovelace := 0, datumValue := some 8 }

/-- The registration folded with a carrier bearing a foreign datum: the deposit is
zero, so no floor is short, and the delivery is still refused `destination`. -/
def foreignDatumDelivery : Scenario :=
  { id := "DR16-deliver-foreign-datum-without-deposit"
  , theoremName := foldRefusesForeignDatum, statementSha256 := foldRefusesForeignDatumDigest
  , kind := "witness", mutates := none, requiresReachableState := false
  , start := s0, setup := [], exit := .fold .insertActive
  , request := zeroDepositCarryingDatum, lovelace := lovelace
  , outputs := some [foreignCarrier] }

/-- Its twin with no carrier at all: nothing reaches the destination. -/
def carrierlessDelivery : Scenario :=
  { foreignDatumDelivery with
    id := "DR17-deliver-without-carrier-or-deposit", outputs := some [] }

-- A delivery whose carrier bears another datum, and one with no carrier at all,
-- is refused `destination` whatever the deposit, as the cage refuses it.
#guard [foreignDatumDelivery, carrierlessDelivery].all fun sc =>
  judgeSurface sc [] (sc.outputs.getD []) == some "destination"

def existingScenarios : List Scenario :=
  [ { id := "DR02-register-active"
    , theoremName := insertActiveTheorem, statementSha256 := insertActiveDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := [], exit := .fold .insertActive
    , request := registerActive, lovelace := lovelace }
  , { id := "DR03-retire-registered"
    , theoremName := updateTerminalTheorem, statementSha256 := updateTerminalDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive], exit := .fold .updateTerminal
    , request := retireRegistered, lovelace := lovelace }
  , { id := "DR05-register-active-twice"
    , theoremName := insertActiveInversion, statementSha256 := insertActiveInversionDigest
    , kind := "mutant", mutates := some "DR02-register-active"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , exit := .fold .insertActive, request := registerActive, lovelace := lovelace }
  , { id := "DR06-retire-unregistered"
    , theoremName := updateTerminalInversion, statementSha256 := updateTerminalInversionDigest
    , kind := "mutant", mutates := some "DR03-retire-registered"
    , requiresReachableState := false, start := s0, setup := []
    , exit := .fold .updateTerminal
    , request := retireRegistered, lovelace := lovelace }
  , { id := "DR07-reject-registered-twice"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive]
    , exit := .reject, request := registerTaken, lovelace := lovelace
    , rejection := some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTaken (.mismatch (.known .active)) 0 1) }
  , { id := "DR08-retract-registration"
    , theoremName := onlyRetractOwesTheTip, statementSha256 := onlyRetractOwesTheTipDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := sTimed, setup := []
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with signatories := [77] } }
  , { id := "DR09-retract-pending"
    , theoremName := retractAdmittedIff, statementSha256 := retractAdmittedIffDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some retractionWitness }
  , { id := "DR10-retract-update-request"
    , theoremName := retractRefusalFirstFailing
    , statementSha256 := retractRefusalFirstFailingDigest
    , kind := "mutant", mutates := some "DR09-retract-pending"
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := updateRetracted, lovelace := lovelace
    , witness := some retractionWitness }
  , { id := "DR11-retract-unsigned-by-owner"
    , theoremName := retractRefusalFirstFailing
    , statementSha256 := retractRefusalFirstFailingDigest
    , kind := "mutant", mutates := some "DR09-retract-pending"
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with signatories := [3] } }
  , { id := "DR12-retract-before-phase2"
    , theoremName := retractRefusalFirstFailing
    , statementSha256 := retractRefusalFirstFailingDigest
    , kind := "mutant", mutates := some "DR09-retract-pending"
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with validFrom := 10999 } }
    -- The pending-request retraction, valid until 11501: one past phase 2's excluded upper
    -- bound, submission 10000 plus processing 1000 plus retraction 500, so the
    -- model refuses it as outside phase 2.
  , { id := "DR13-retract-after-phase2"
    , theoremName := retractRefusalFirstFailing
    , statementSha256 := retractRefusalFirstFailingDigest
    , kind := "mutant", mutates := some "DR09-retract-pending"
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with validTo := 11501 } }
  , { id := "PR-retract-forged-time"
    , theoremName := retractRefusalFirstFailing
    , statementSha256 := retractRefusalFirstFailingDigest
    , kind := "mutant", mutates := some "DR09-retract-pending"
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with submittedAt := 11000, validFrom := 12000, validTo := 12001 } }
  , { id := "PR-retract-ignores-witness-time"
    , theoremName := retractAdmittedIff, statementSha256 := retractAdmittedIffDigest
    , kind := "witness", mutates := none
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with submittedAt := 0 } }
    -- The active registration claiming the token its edge mints: the single step a
    -- one-request batch must fold exactly as.
  , { id := "DR14-register-active-claimed"
    , theoremName := insertActiveTheorem, statementSha256 := insertActiveDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := [], exit := .fold .insertActive
    , request := registerActiveClaimed, lovelace := lovelace }
    -- An active registration whose request carries a datum: the destination output
    -- carries that very datum, inline.
  , { id := "DR15-register-active-carrying-datum"
    , theoremName := deliveredDatumIsRequestDatum
    , statementSha256 := deliveredDatumIsRequestDatumDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := [], exit := .fold .insertActive
    , request := { request .insertActive 43 42 556 0 55 with datum := some 7 }
    , lovelace := lovelace }
  , foreignDatumDelivery
  , carrierlessDelivery
  , historicalScenario
  ] ++ rejectionTable.map Prod.fst ++ rejectionTimes.map Prod.fst ++ rejectionControls.map Prod.fst

#guard (runSurface historicalScenario).2.outcome == .refused
#guard (runSurface historicalScenario).2.reason == some "reject-evidence-missing"

#guard existingScenarios.any fun sc => sc.id == "PR-retract-forged-time" &&
  (runSurface sc).2.reason == some "not-phase2"
#guard existingScenarios.any fun sc => sc.id == "PR-retract-ignores-witness-time" &&
  (runSurface sc).2.outcome == .accepted
