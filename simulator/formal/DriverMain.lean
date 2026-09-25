import Singular.Driver

/-! # The driver corpus producer

Executes every scenario through `Singular.Driver.runSurface` and prints the
corpus the model check replays. The scenarios are the registration-to-retirement
lifecycle the registry implements today, each bound to the theorem it is about,
with the mutant beside each witness, and the two exits that fold nothing: a
reject of a registration the law refuses, and a retract.

A retraction is admitted before it is paid, so every retraction row carries the
witness its admission reads, under a registry whose processing and retraction
times make phase 2 a real interval. Beside the retraction of a pending
registration stand one refused retraction for each reason admission gives, each
the admitted one with one field changed.

Retirement is reached by registering first. Its setup trace is a real
`insertActive` run through the law, not a state typed into this file with the
key already active: a constructed starting state would make the retirement row
evidence for a lifecycle nobody executed.

The statement digests are the ones `lean/theorem-debt.json` records. They are
claims about the manifest, checked against it by `tools/check_model.py`, so a
theorem whose statement moves makes this binding stale rather than silently
fine. -/

open Lean
open Singular
open Singular.Driver

/-- The pinned application policy every approval in this corpus is minted
under. -/
def policy : Nat := 7

def cfg0 : Config :=
  { root := rootOf [], maxFee := 0, processTime := 0, retractTime := 0
  , applicationPolicy := policy, activePolicy := 8, absentPolicy := 9
  , terminalPolicy := 10 }

/-- The empty registry: no leaves, no custody, no held tokens. -/
def s0 : RegistryState := { config := cfg0, trie := [], custody := [], held := [] }

/-- The empty registry with a processing time of 1000 ms and a retraction time of
500 ms after it: a request submitted at `t` can be retracted from `t + 1000`,
included, until `t + 1500`. -/
def sTimed : RegistryState :=
  { s0 with config := { cfg0 with processTime := 1000, retractTime := 500 } }

/-- A request carrying the approval scoped exactly to itself, so an accepted row
is accepted for the authorization the model requires and not for a missing
check. `approved := false` drops the approval and nothing else. -/
def request (e : Edge) (key owner out refund deposit : Nat) (approved : Bool := true) : Request :=
  let base : Request :=
    { edge := e, key := key, owner := owner, output := out
    , refundAddress := refund, deposit := deposit }
  let dest := requestDestination base
  let ap : Approval :=
    { policy := policy, edge := e, key := key, owner := owner
    , destination := dest
    , assetName := approvalAssetName e key owner dest }
  { base with approval := if approved then some ap else none }

def lovelace : Nat := 5

def insertAbsentTheorem : String := "Singular.Statements.insert_absent_transaction_row"
def insertAbsentDigest : String :=
  "8c63e568b81b4e4a81cf3832c88d324ef910925e2733b6593c8e337c81357b3f"
def insertActiveTheorem : String := "Singular.Statements.insert_active_transaction_row"
def insertActiveDigest : String :=
  "f1f50ac910b0ff0f5abb8d371bd82ce5007e8bfe861939c5972d62e8c85e8508"
def updateTerminalTheorem : String := "Singular.Statements.update_terminal_transaction_row"
def updateTerminalDigest : String :=
  "6792444e9887f9e579975eae2cca2be00048db6d5a7a8c147b72fe6462eb3068"
def insertAbsentInversion : String := "Singular.Statements.insert_absent_inversion"
def insertAbsentInversionDigest : String :=
  "b2ca14e3aa29caef0841c246964e5e64b600eef9ff64c0865677a1219d31525d"
def insertActiveInversion : String := "Singular.Statements.insert_active_inversion"
def insertActiveInversionDigest : String :=
  "8b5794d17bf859cb01ceae53f2c487cbb22a251464c51364778234f978a9f98b"
def updateTerminalInversion : String := "Singular.Statements.update_terminal_inversion"
def updateTerminalInversionDigest : String :=
  "55610f5a33da76d49c9f8e5eee2170af33700b0222530d6548629960133bc470"
def noExitStrandsTheDeposit : String := "Singular.Statements.no_exit_strands_the_deposit"
def noExitStrandsTheDepositDigest : String :=
  "d8e6d7f1148b6f328d7dcb5cbf9f32d760b0dcd4809257f2947946031353eaa5"
def onlyRetractOwesTheTip : String := "Singular.Statements.only_retract_owes_the_tip"
def onlyRetractOwesTheTipDigest : String :=
  "df27296176ea7a88ac2d8fcaf3047e5521838fe9dabe493183ef26ac21dd624f"
def retractAdmittedIff : String := "Singular.Statements.retract_admitted_iff"
def retractAdmittedIffDigest : String :=
  "6c9c65f00e1b9054319ae2151908af4336717df5642f31aace963aa80cb29f57"
def retractRefusalFirstFailing : String := "Singular.Statements.retract_refusal_first_failing"
def retractRefusalFirstFailingDigest : String :=
  "506966483299dfa897bb988c179646373d3dfcf7a1a20728fdf0cae217197ffc"

/-- The active registration this corpus retires: key 42, owner 42, routed to
output 555 with deposit 55, which goes there with the token. One request, reused
as the retirement row's setup so the two rows share an actual history. -/
def registerActive : Request := request .insertActive 42 42 555 0 55

/-- The retirement of key 42 by owner 42, deposit 55: it delivers nothing, so the
deposit goes back to the owner. -/
def retireRegistered : Request := request .updateTerminal 42 42 555 0 55

/-- A second registration of key 42, by owner 43 with deposit 55 and tip 7: the
law refuses it once 42 is registered, so a folder rejects it and the owner is
paid the deposit back. -/
def registerTaken : Request := { request .insertActive 42 43 556 0 55 with tip := 7 }

/-- A registration of key 7 by owner 77 with deposit 55 and tip 7, retracted by
its owner: everything it held, deposit and tip, goes back. -/
def registerRetracted : Request := { request .insertActive 7 77 777 0 55 with tip := 7 }

/-- The retraction of a request submitted at 10000 by its owner 77 and a second
party 3, valid over the whole of phase 2 under `sTimed`: from 11000, included, to
11500, which the excluded upper bound reaches. -/
def retractionWitness : RetractWitness :=
  { submittedAt := 10000, validFrom := 11000, validTo := 11500, signatories := [3, 77] }

/-- An update of key 7 by owner 77: pending like the registration, and not one its
owner can take back. -/
def updateRetracted : Request := { request .updateActive 7 77 777 0 55 with tip := 7 }

def scenarios : List Scenario :=
  [ { id := "DR01-register-absent"
    , theoremName := insertAbsentTheorem, statementSha256 := insertAbsentDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := [], exit := .fold .insertAbsent
    , request := request .insertAbsent 5 91 0 91 55, lovelace := lovelace }
  , { id := "DR02-register-active"
    , theoremName := insertActiveTheorem, statementSha256 := insertActiveDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := [], exit := .fold .insertActive
    , request := registerActive, lovelace := lovelace }
  , { id := "DR03-retire-registered"
    , theoremName := updateTerminalTheorem, statementSha256 := updateTerminalDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive], exit := .fold .updateTerminal
    , request := retireRegistered, lovelace := lovelace }
  , { id := "DR04-register-absent-unapproved"
    , theoremName := insertAbsentInversion, statementSha256 := insertAbsentInversionDigest
    , kind := "mutant", mutates := some "DR01-register-absent"
    , requiresReachableState := false, start := s0, setup := []
    , exit := .fold .insertAbsent
    , request := request .insertAbsent 5 91 0 91 55 (approved := false)
    , lovelace := lovelace }
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
    , exit := .reject, request := registerTaken, lovelace := lovelace }
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
    -- DR09's retraction, valid until 11501: one past phase 2's excluded upper
    -- bound, submission 10000 plus processing 1000 plus retraction 500, so the
    -- model refuses it as outside phase 2.
  , { id := "DR13-retract-after-phase2"
    , theoremName := retractRefusalFirstFailing
    , statementSha256 := retractRefusalFirstFailingDigest
    , kind := "mutant", mutates := some "DR09-retract-pending"
    , requiresReachableState := true, start := sTimed, setup := [registerActive]
    , exit := .retract, request := registerRetracted, lovelace := lovelace
    , witness := some { retractionWitness with validTo := 11501 } }
  ]

/-- The digest the surface carries is over the declared names themselves, so a
silently widened or narrowed surface changes it. -/
def surfaceDefinition : String :=
  String.intercalate "|"
    (declaredOperations ++ declaredObservations ++ declaredUnobservable ++ declaredJudgements)

def corpus : Json :=
  Json.mkObj
    [ ("schema", toJson "singular-driver-corpus-v1")
    , ("surface", surfaceJson surface (toString (hash surfaceDefinition)))
    , ("scenarios", Json.arr ((scenarios.map scenarioJson).toArray)) ]

def main : IO Unit := IO.println corpus.pretty
