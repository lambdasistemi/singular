import Singular.Driver

/-! Driver states, requests and statement bindings. -/

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
def foldBatchOfOne : String := "Singular.Statements.fold_batch_of_one_is_step"
def foldBatchOfOneDigest : String :=
  "09dc61dcbe8e7a4a68b170944bb42cdcf6ece9af9fc006af96135cfab1185f87"
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
