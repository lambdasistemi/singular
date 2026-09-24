import Singular.Driver

/-! # The driver corpus producer

Executes every scenario through `Singular.Driver.runSurface` and prints the
corpus the model check replays. The scenarios are the registration-to-retirement
lifecycle the registry implements today, each bound to the theorem it is about,
with the mutant beside each witness, and the two exits that fold nothing: a
reject of a registration the law refuses, and a retract.

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
  "cbe444a5bddadef89cba2f1459a597a010531e396a90be4a798fdccc5633fb46"
def insertActiveTheorem : String := "Singular.Statements.insert_active_transaction_row"
def insertActiveDigest : String :=
  "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
def updateTerminalTheorem : String := "Singular.Statements.update_terminal_transaction_row"
def updateTerminalDigest : String :=
  "c85a4eb0a61907d71a0861658097e7ab839655023e39bfc4e11a8209553e31c2"
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

/-- The active registration this corpus retires: key 42, owner 42, routed to
output 555. One request, reused as the retirement row's setup so the two rows
share an actual history. -/
def registerActive : Request := request .insertActive 42 42 555 0 0

/-- A second registration of key 42, by owner 43 with deposit 55 and tip 7: the
law refuses it once 42 is registered, so a folder rejects it and the owner is
paid the deposit back. -/
def registerTaken : Request := { request .insertActive 42 43 556 0 55 with tip := 7 }

/-- A registration of key 7 by owner 77 with deposit 55 and tip 7, retracted by
its owner: everything it held, deposit and tip, goes back. -/
def registerRetracted : Request := { request .insertActive 7 77 777 0 55 with tip := 7 }

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
    , request := request .updateTerminal 42 42 555 0 0, lovelace := lovelace }
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
    , request := request .updateTerminal 42 42 555 0 0, lovelace := lovelace }
  , { id := "DR07-reject-registered-twice"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive]
    , exit := .reject, request := registerTaken, lovelace := lovelace }
  , { id := "DR08-retract-registration"
    , theoremName := onlyRetractOwesTheTip, statementSha256 := onlyRetractOwesTheTipDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := []
    , exit := .retract, request := registerRetracted, lovelace := lovelace }
  ]

/-- The digest the surface carries is over the declared names themselves, so a
silently widened or narrowed surface changes it. -/
def surfaceDefinition : String :=
  String.intercalate "|"
    (declaredOperations ++ declaredObservations ++ declaredUnobservable)

def corpus : Json :=
  Json.mkObj
    [ ("schema", toJson "singular-driver-corpus-v1")
    , ("surface", surfaceJson surface (toString (hash surfaceDefinition)))
    , ("scenarios", Json.arr ((scenarios.map scenarioJson).toArray)) ]

def main : IO Unit := IO.println corpus.pretty
