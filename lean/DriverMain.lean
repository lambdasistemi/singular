import Singular.Driver

/-! # The driver corpus producer

Executes every scenario through `Singular.Driver.runSurface` and prints the
corpus the model check replays. The scenarios are the registration-to-retirement
lifecycle the registry implements today, each bound to the theorem it is about,
with the mutant beside each witness, and the two exits that fold nothing: a
reject of a registration the law refuses, and a retract. Beside them stand the
batch questions: folds of several requests at once and rejects of several, each
batch of one beside the single request it must answer as.

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

def insertActiveTheorem : String := "Singular.Statements.insert_active_transaction_row"
def insertActiveDigest : String :=
  "6073c296c90657ef193368669ef07ce6d97eddaa9d2059771e23fe156b61b868"
def updateTerminalTheorem : String := "Singular.Statements.update_terminal_transaction_row"
def updateTerminalDigest : String :=
  "d2402d0c08b3df1258ddf354ef7e4855ceec1dae5f1fe763e0f0189aacb0b560"
def insertActiveInversion : String := "Singular.Statements.insert_active_inversion"
def insertActiveInversionDigest : String :=
  "df737501c3c51c4968eb5adcc658f74473984613c591b4886fa092c15e35dc9d"
def updateTerminalInversion : String := "Singular.Statements.update_terminal_inversion"
def updateTerminalInversionDigest : String :=
  "55610f5a33da76d49c9f8e5eee2170af33700b0222530d6548629960133bc470"
def noExitStrandsTheDeposit : String := "Singular.Statements.no_exit_strands_the_deposit"
def noExitStrandsTheDepositDigest : String :=
  "a2e9655f8a61d303518851ef9907dcfca817d1d05a8071f7104974c2c522230a"
def onlyRetractOwesTheTip : String := "Singular.Statements.only_retract_owes_the_tip"
def onlyRetractOwesTheTipDigest : String :=
  "df27296176ea7a88ac2d8fcaf3047e5521838fe9dabe493183ef26ac21dd624f"
def retractAdmittedIff : String := "Singular.Statements.retract_admitted_iff"
def retractAdmittedIffDigest : String :=
  "30f9c66828032bcc4337dc96e5c7e9c8dec6514b0f5c9ad3c0969846e19ce55c"
def retractRefusalFirstFailing : String := "Singular.Statements.retract_refusal_first_failing"
def retractRefusalFirstFailingDigest : String :=
  "a91793ff8a3c12a3bf4a12632c53a53f4e0d25ff42f40766443a6e4b1d417f71"
def deliveredDatumIsRequestDatum : String :=
  "Singular.Statements.delivered_datum_is_request_datum"
def deliveredDatumIsRequestDatumDigest : String :=
  "76247fab5884aefffb7639b05675206c16b48c191fb0bd8c63ce87afba58c4a5"
def foldRefusesForeignDatum : String := "Singular.Statements.fold_refuses_foreign_datum"
def foldRefusesForeignDatumDigest : String :=
  "fd23c815f71328cb0595763ea280845bfd28b4aa5b78022080afd43fb12f4aba"
def bookedAtMostOnce : String := "Singular.Statements.booked_at_most_once"
def bookedAtMostOnceDigest : String :=
  "1c8b3268586a2ca2aaf930c3a45b0f8fde24c061f0ff63bf8962afbb42eb1ec2"
def claimedMintByKindKey : String := "Singular.Statements.fold_batch_claimed_mint_by_kind_key"
def claimedMintByKindKeyDigest : String :=
  "9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988"
def emptyFoldError : String := "Singular.Statements.empty_fold_error"
def emptyFoldErrorDigest : String :=
  "8bd6ec570fbda5220c7d841d4396605cf637e094bdeb275d7495f7169a4a1f06"
def foldBatchCons : String := "Singular.Statements.fold_batch_cons"
def foldBatchConsDigest : String :=
  "a0992d97ae5b6f86503bdc5247b4b2602ec74a5516713e274c4919aa53d5d26f"
def foldBatchOfOne : String := "Singular.Statements.fold_batch_of_one_is_step"
def foldBatchOfOneDigest : String :=
  "b6226a82c352b27b0fac2034592963f240da8696a44e088baeaca770d9e7c665"
def rejectBatchOfOne : String := "Singular.Statements.reject_batch_of_one_is_reject"
def rejectBatchOfOneDigest : String :=
  "9f0e815f13a2ce1e41ecd3d19792aa741ade3187fb951fbce6b3fa4b87b1f42c"

def rejectTheorem : String := "Singular.Statements.rejection_admitted_iff"
def rejectDigest : String :=
  "cdd9b2e62391bc21750ed601e8e3045ce271467db5af493c8925ca2037091350"

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

/-- The historical unguarded rejection: an empty registry and an approved insertion of key 5 for owner 42, destination 99, deposit 2000000, tip 1000000, rejected with no signers. On the base it is accepted; after the change it must be refused with its evidence missing. -/
def historicalRequest : Request := { request .insertActive 5 42 99 0 2000000 with tip := 1000000, reference := 7, submittedAt := 10000, claimed := [(.active, 1)] }

def historicalWitness : RetractWitness := { submittedAt := 10000, validFrom := 10001, validTo := 10002, signatories := [] }

def historicalScenario : Scenario := { id := "historical-unguarded-rejection", theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest, kind := "witness", mutates := none, requiresReachableState := false, start := s0, setup := [], exit := .reject, request := historicalRequest, lovelace := lovelace }

/-- A registration of key 7 by owner 77 with deposit 55 and tip 7, retracted by
its owner: everything it held, deposit and tip, goes back. -/
def registerRetracted : Request :=
  { request .insertActive 7 77 777 0 55 with tip := 7, submittedAt := 10000 }

/-- The retraction of a request submitted at 10000 by its owner 77 and a second
party 3, valid over the whole of phase 2 under `sTimed`: from 11000, included, to
11500, which the excluded upper bound reaches. -/
def retractionWitness : RetractWitness :=
  { submittedAt := 10000, validFrom := 11000, validTo := 11500, signatories := [3, 77] }

/-- An update of key 7 by owner 77: pending like the registration, and not one its
owner can take back. -/
def updateRetracted : Request :=
  { request .updateActive 7 77 777 0 55 with tip := 7, submittedAt := 10000 }

/-- A request claiming exactly the mint its own edge makes: the lawful claim a
batch's mint guard compares with what the batch folds. -/
def claiming (r : Request) : Request := { r with claimed := delta r.edge }

/-- The active registration of key 42, claiming its token. -/
def registerActiveClaimed : Request := claiming registerActive

/-- A second owner, 44, also asking for key 42 with deposit 40 and tip 3: once 42
is registered the law refuses it too, so a folder rejects it beside owner 43's. -/
def registerTakenAgain : Request := { request .insertActive 42 44 557 0 40 with tip := 3 }

/-- Owner 43 asking for key 42 a second time, with deposit 40: two requests of one
owner, owed back together. -/
def registerTakenTwice : Request := { request .insertActive 42 43 558 0 40 with tip := 3 }

/-- The synthetic absent state at key 5: known absent with its custody entry, so the premise
holds and the leaf differs from unknown. -/
def absentState : RegistryState :=
  let trie : Trie := [(5, .known .absent)]
  { config := { cfg0 with root := rootOf trie }
  , trie := trie
  , custody := [{ key := 5, refundAddress := 91, value := 55 }]
  , held := [] }

/-- Explicit producer evidence; the driver itself never creates a proof. -/
def rejectionFor (s : RegistryState) (r : Request) (reason : RejectReason) (lo hi : Nat) : RejectWitness :=
  { evidence := { registry := s.config, request := r, reason := reason }, validFrom := lo, validTo := hi }

def protectedScenario (id : String) (start : RegistryState) (setup : List Request) (r : Request)
    (rejection : Option RejectWitness) : Scenario :=
  { id, theoremName := rejectTheorem, statementSha256 := rejectDigest
  , kind := "witness", mutates := none, requiresReachableState := !setup.isEmpty
  , start, setup, exit := .reject, request := r, lovelace := lovelace, rejection }

def rejInsertUnknown : Request := request .insertActive 5 42 99 0 55
def rejInsertAbsent : Request := request .insertActive 5 42 99 0 55
def rejUpdateUnknown : Request := request .updateTerminal 5 42 99 0 55
def rejUpdateAbsent : Request := request .updateTerminal 5 42 99 0 55

def rejActiveSetup : List Request := [request .insertActive 5 42 99 0 55]
def rejTerminalSetup : List Request := [request .insertActive 5 42 99 0 55, request .updateTerminal 5 42 99 0 55]

def rejActiveState : RegistryState := (runSetup s0 rejActiveSetup).2.1
def rejTerminalState : RegistryState := (runSetup s0 rejTerminalSetup).2.1

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

#guard scenarios.any fun sc => sc.id == "PR-retract-forged-time" &&
  (runSurface sc).2.reason == some "not-phase2"
#guard scenarios.any fun sc => sc.id == "PR-retract-ignores-witness-time" &&
  (runSurface sc).2.outcome == .accepted

/-- The batch questions: a lawful two-request fold and its refused mutants — a
crossed claim, an empty batch, a later request the law refuses — a batch of one
beside the single step it preserves; two rejects judged paid, short, and short in
sum for one owner, a reject of one beside the single reject, and the batches the
driver does not answer. -/
def existingBatchScenarios : List BatchScenario :=
  [ { id := "BR01-fold-two-registrations"
    , theoremName := bookedAtMostOnce, statementSha256 := bookedAtMostOnceDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := []
    , question := .foldBatch
        [registerActiveClaimed, claiming (request .insertActive 5 91 556 0 55)] }
    -- Two registrations whose claims balance per kind and cross per key: key 42
    -- claims both active tokens, key 43 none.
  , { id := "BR02-fold-crossed-claim"
    , theoremName := claimedMintByKindKey, statementSha256 := claimedMintByKindKeyDigest
    , kind := "mutant", mutates := some "BR01-fold-two-registrations"
    , requiresReachableState := false, start := s0, setup := []
    , question := .foldBatch
        [ { registerActive with claimed := [(.active, 2)] }
        , request .insertActive 43 43 556 0 55 ] }
  , { id := "BR03-fold-empty"
    , theoremName := emptyFoldError, statementSha256 := emptyFoldErrorDigest
    , kind := "mutant", mutates := some "BR01-fold-two-registrations"
    , requiresReachableState := false, start := s0, setup := []
    , question := .foldBatch [] }
    -- The registration of key 42 twice in one batch: the first folds, the law
    -- refuses the second, and the whole batch is refused for it.
  , { id := "BR04-fold-later-request-refused"
    , theoremName := foldBatchCons, statementSha256 := foldBatchConsDigest
    , kind := "mutant", mutates := some "BR01-fold-two-registrations"
    , requiresReachableState := false, start := s0, setup := []
    , question := .foldBatch [registerActiveClaimed, registerActiveClaimed] }
  , { id := "BR05-fold-one-registration"
    , theoremName := foldBatchOfOne, statementSha256 := foldBatchOfOneDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := []
    , question := .foldBatch [registerActiveClaimed] }
  , { id := "BR06-reject-two-paid"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken), (.reject, registerTakenAgain)]
    , rejections := [some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTaken (.mismatch (.known .active)) 0 1), some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTakenAgain (.mismatch (.known .active)) 0 1)]
    , outputs := some [ownerPaid 43 55, ownerPaid 44 40] }
  , { id := "BR07-reject-two-short"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken), (.reject, registerTakenAgain)]
    , rejections := [some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTaken (.mismatch (.known .active)) 0 1), some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTakenAgain (.mismatch (.known .active)) 0 1)]
    , outputs := some [ownerPaid 43 55, ownerPaid 44 39] }
    -- Two rejects owed to owner 43, 55 and 40, paid by one output of 55: each
    -- deposit alone is covered, their sum is not.
  , { id := "BR08-reject-one-owner-short-in-sum"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken), (.reject, registerTakenTwice)]
    , rejections := [some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTaken (.mismatch (.known .active)) 0 1), some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTakenTwice (.mismatch (.known .active)) 0 1)]
    , outputs := some [ownerPaid 43 55] }
  , { id := "BR09-reject-one"
    , theoremName := rejectBatchOfOne, statementSha256 := rejectBatchOfOneDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken)]
    , rejections := [some (rejectionFor ((runSetup s0 [registerActive]).2.1) registerTaken (.mismatch (.known .active)) 0 1)]
    , outputs := some [ownerPaid 43 55] }
  , { id := "BR10-reject-mixed-with-fold"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken), (.fold .insertActive, registerTakenAgain)] }
  , { id := "BR11-reject-empty"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [] }
  , { id := "BR12-reject-retract"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [(.retract, registerTaken)] }
  , { id := "BR13-fold-register-then-terminate"
    , theoremName := foldBatchCons, statementSha256 := foldBatchConsDigest
    , kind := "mutant", mutates := some "BR01-fold-two-registrations"
    , requiresReachableState := false, start := s0, setup := []
    , question := .foldBatch [registerActiveClaimed, claiming retireRegistered] }
  , { id := "BR14-fold-terminate-then-register"
    , theoremName := foldBatchCons, statementSha256 := foldBatchConsDigest
    , kind := "mutant", mutates := some "BR01-fold-two-registrations"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .foldBatch [claiming retireRegistered, registerActiveClaimed] }
  , { id := "BR15-fold-terminate-twice"
    , theoremName := foldBatchCons, statementSha256 := foldBatchConsDigest
    , kind := "mutant", mutates := some "BR01-fold-two-registrations"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .foldBatch [claiming retireRegistered, claiming retireRegistered] }
  , { id := "BR16-fold-live-holding-and-distinct-registration"
    , theoremName := foldBatchCons, statementSha256 := foldBatchConsDigest
    , kind := "witness", mutates := none
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .foldBatch [claiming retireRegistered, claiming (request .insertActive 5 91 556 0 55)] }
  ]

/-- Two separately booked requests, with deadlines 61000 and 80000. -/
def windowState : RegistryState := { s0 with config := { cfg0 with processTime := 60000 } }
def windowFirst : Request := { claiming registerActive with submittedAt := 1000 }
def windowSecond : Request :=
  { claiming (request .insertActive 43 43 556 0 55) with submittedAt := 20000 }

def windowScenario (id : String) (r : Request) (bound : Option Nat) : Scenario :=
  { id, theoremName := "Singular.Statements.fold_admitted_up_to_the_deadline"
  , statementSha256 := "e1540c2791bdcd7319fbcd172dc75e1ec5fdea744b321d7635a0b598bb758710", kind := "witness", mutates := none
  , requiresReachableState := false, start := windowState, setup := []
  , exit := .fold r.edge, request := r, lovelace
  , foldWitness := bound.map fun validTo => { validTo } }

def windowBatch (id : String) (rs : List Request) (bound : Option Nat) : BatchScenario :=
  { id, theoremName := "Singular.Statements.fold_admission_judges_each_request_by_its_own_time"
  , statementSha256 := "ed9bd208afb40f17952dd07e3636b21be857d39418839a26eef57968a1e3d0e2", kind := "witness", mutates := none
  , requiresReachableState := false, start := windowState, setup := []
  , question := .foldBatch rs, foldWitness := bound.map fun validTo => { validTo } }

/-- These expectations state the window rule; the exported answers are always
computed by runSurface, never copied from this list. -/
def windowScenarios : List (Scenario × Outcome × Option String) :=
  [ (windowScenario "DR18-fold-at-deadline" windowFirst (some 61000), .accepted, none)
  , (windowScenario "DR19-fold-past-deadline" windowFirst (some 61001), .refused, some "not-phase1")
  , (windowScenario "DR20-later-request-in-window" windowSecond (some 61001), .accepted, none)
  , (windowScenario "DR21-fold-without-witness" windowFirst none, .unsupported, some "fold-without-witness")
  , ({ windowScenario "DR22-reject-past-deadline" windowFirst (some 80001) with exit := .reject, foldWitness := none }, .accepted, none)
  , (windowScenario "DR23-window-before-approval" { windowFirst with approval := none } (some 61001), .refused, some "not-phase1")
  , (windowScenario "DR24-edge-before-window" { claiming (request .updateActive 42 42 555 0 55) with submittedAt := 1000 } (some 80001), .refused, some "edge-inadmissible")
  , (windowScenario "DR25-second-at-deadline" windowSecond (some 80000), .accepted, none)
  , (windowScenario "DR26-second-past-deadline" windowSecond (some 80001), .refused, some "not-phase1")
  , (windowScenario "DR27-fold-before-deadline" windowFirst (some 60999), .accepted, none)
  , (windowScenario "DR28-window-before-leaf" { claiming retireRegistered with submittedAt := 1000 } (some 61001), .refused, some "not-phase1")
  ]

def windowBatches : List (BatchScenario × Outcome × Option String) :=
  [ (windowBatch "BR17-batch-at-first-deadline" [windowFirst, windowSecond] (some 61000), .accepted, none)
  , (windowBatch "BR18-batch-past-first-deadline" [windowFirst, windowSecond] (some 61001), .refused, some "not-phase1")
  , (windowBatch "BR19-expired-request-last" [windowSecond, windowFirst] (some 61001), .refused, some "not-phase1")
  , (windowBatch "BR20-batch-without-witness" [windowFirst, windowSecond] none, .unsupported, some "fold-without-witness")
  , (windowBatch "BR21-excluded-edge-last" [windowFirst, { claiming (request .updateActive 43 43 556 0 55) with submittedAt := 20000 }] (some 80001), .refused, some "edge-inadmissible")
  , (windowBatch "BR22-batch-before-first-deadline" [windowFirst, windowSecond] (some 60999), .accepted, none)
  , (windowBatch "BR23-later-singleton" [windowSecond] (some 61001), .accepted, none)
  , (windowBatch "BR24-later-singleton-at-deadline" [windowSecond] (some 80000), .accepted, none)
  , (windowBatch "BR25-later-singleton-past-deadline" [windowSecond] (some 80001), .refused, some "not-phase1")
  ]

def scenarios : List Scenario :=
  existingScenarios.map (fun sc => match sc.exit with
    | .fold _ => { sc with foldWitness := some { validTo := 0 } }
    | _ => sc) ++ windowScenarios.map (·.1)

def batchScenarios : List BatchScenario :=
  existingBatchScenarios.map (fun sc => match sc.question with
    | .foldBatch _ => { sc with foldWitness := some { validTo := 0 } }
    | _ => sc) ++ windowBatches.map (·.1)

/-- Exercise the declared driver before emitting the corpus. Failure reports
both computed and required verdicts, keeping setup failure distinct. -/
def checkWindows : IO Unit := do
  let stderr ← IO.getStderr
  let mut failures := 0
  let rows := windowScenarios.map (fun (sc, outcome, reason) =>
    (sc.id, (runSurface sc).2, outcome, reason)) ++
    windowBatches.map (fun (sc, outcome, reason) =>
      let batch := match sc.question with | .foldBatch rs => rs | _ => []
      (sc.id, (runFoldBatch sc.start sc.setup batch sc.foldWitness).2.2, outcome, reason))
  for (id, result, outcome, reason) in rows do
    if result.outcome != outcome || result.reason != reason then
      failures := failures + 1
      stderr.putStrLn s!"{id}: expected {outcomeName outcome}/{reason.getD "none"}; observed {outcomeName result.outcome}/{result.reason.getD "none"}"
  if failures > 0 then throw (IO.userError s!"fold window: {failures} of {rows.length} driver questions disagree")

/-- The digest the surface carries is over the declared names themselves, so a
silently widened or narrowed surface changes it. -/
def surfaceDefinition : String :=
  String.intercalate "|"
    (declaredOperations ++ declaredObservations ++ declaredUnobservable ++ declaredJudgements
      ++ declaredBatchQuestions.flatMap fun q => q.1 :: q.2)

def corpus : Json :=
  Json.mkObj
    [ ("schema", toJson "singular-driver-corpus-v1")
    , ("surface", surfaceJson surface (toString (hash surfaceDefinition)))
    , ("scenarios", Json.arr ((scenarios.map scenarioJson).toArray))
    , ("batches", Json.arr ((batchScenarios.map batchScenarioJson).toArray)) ]

def main : IO Unit := do
  checkWindows
  IO.println corpus.pretty
