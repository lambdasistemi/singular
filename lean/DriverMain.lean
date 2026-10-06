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

def insertAbsentTheorem : String := "Singular.Statements.insert_absent_transaction_row"
def insertAbsentDigest : String :=
  "a7e93824be2944e55b6482d0836111450522a7ed04eb57c262656f8903adaec6"
def insertActiveTheorem : String := "Singular.Statements.insert_active_transaction_row"
def insertActiveDigest : String :=
  "3c8d7b9bd9092b29d2bbb58ebbca15b008dc9b9396899d9d67d55ea66e1f6070"
def updateTerminalTheorem : String := "Singular.Statements.update_terminal_transaction_row"
def updateTerminalDigest : String :=
  "4806b33d0b74c975981c8905ceb8aab758efbe5d780eca50f59e68202ea2a4bf"
def insertAbsentInversion : String := "Singular.Statements.insert_absent_inversion"
def insertAbsentInversionDigest : String :=
  "b2ca14e3aa29caef0841c246964e5e64b600eef9ff64c0865677a1219d31525d"
def insertActiveInversion : String := "Singular.Statements.insert_active_inversion"
def insertActiveInversionDigest : String :=
  "df737501c3c51c4968eb5adcc658f74473984613c591b4886fa092c15e35dc9d"
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
def deliveredDatumIsRequestDatum : String :=
  "Singular.Statements.delivered_datum_is_request_datum"
def deliveredDatumIsRequestDatumDigest : String :=
  "76247fab5884aefffb7639b05675206c16b48c191fb0bd8c63ce87afba58c4a5"
def foldRefusesForeignDatum : String := "Singular.Statements.fold_refuses_foreign_datum"
def foldRefusesForeignDatumDigest : String :=
  "959f43d652876b9ea5eff3f9772344ffbc09fa3162f669e03fe1946a3e100600"
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
  "09dc61dcbe8e7a4a68b170944bb42cdcf6ece9af9fc006af96135cfab1185f87"
def foldPastDeadline : String := "Singular.Statements.fold_batch_refuses_past_deadline"
def foldPastDeadlineDigest : String :=
  "2195f8d24a7aad10b51f42f1e5c6c578b236eb9ad736a07b6507c8ea9479b0ec"
def foldInWindow : String := "Singular.Statements.fold_admitted_in_window_is_fold_batch"
def foldInWindowDigest : String :=
  "bdb88cbaa8898e97fc22a0435a90e53388ad0c98395d550e9b620d837fb401b1"
def foldAdmissionBoundary : String := "Singular.Statements.fold_admission_boundary"
def foldAdmissionBoundaryDigest : String :=
  "df18f10616d3a3adc8c356bd89d81076b1e256c13bde0dfaa539871d96833f1a"
def foldConsumingCreated : String := "Singular.Statements.fold_batch_refuses_consuming_created"
def foldConsumingCreatedDigest : String :=
  "0707908378fa9d1e58191e8758dbe198f7cd9dfe56974b240aedac2ece0d9b10"
def rejectBatchOfOne : String := "Singular.Statements.reject_batch_of_one_is_reject"
def rejectBatchOfOneDigest : String :=
  "9f0e815f13a2ce1e41ecd3d19792aa741ade3187fb951fbce6b3fa4b87b1f42c"

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

    -- The registration of key 42 folded under an upper bound equal to its
    -- deadline under `sTimed`: submitted at 10000, processing 1000, the excluded
    -- upper bound 11000 reaches the deadline and is admitted; at 11001 it passes
    -- it and the fold is refused, as the chain refuses it.
  , { id := "DR18-register-at-deadline"
    , theoremName := foldAdmissionBoundary, statementSha256 := foldAdmissionBoundaryDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := sTimed, setup := [], exit := .fold .insertActive
    , request := registerActive, lovelace := lovelace
    , foldWitness := some { submittedAt := [10000], validTo := 11000 } }
  , { id := "DR19-register-past-deadline"
    , theoremName := foldAdmissionBoundary, statementSha256 := foldAdmissionBoundaryDigest
    , kind := "mutant", mutates := some "DR18-register-at-deadline"
    , requiresReachableState := false, start := sTimed, setup := [], exit := .fold .insertActive
    , request := registerActive, lovelace := lovelace
    , foldWitness := some { submittedAt := [10000], validTo := 11001 } }
  ]

/-- A batch of two requests at key 60, the first creating what the second
consumes, each claiming its own edge's mint so the mint guard holds; the law
admits both steps, and the batch is refused for consuming what it created. The
requests that consume a custody entry or an update's holding start from key 60
booked absent, by a real `insertAbsent` run through the law. -/
def consumeCreated (id : String) (setup : List Request) (create consume : Edge) :
    BatchScenario :=
  { id := id
  , theoremName := foldConsumingCreated, statementSha256 := foldConsumingCreatedDigest
  , kind := "witness", mutates := none, requiresReachableState := !setup.isEmpty
  , start := s0, setup := setup
  , question := .foldBatch
      [ claiming (request create 60 60 600 60 55), claiming (request consume 60 60 600 60 55) ] }

/-- Key 60 booked absent: the starting point of the pairs that update it. -/
def bookedAbsent : Request := request .insertAbsent 60 60 0 60 55

/-- Every create-then-consume pair: a holding created by `insertActive` or
`updateActive` and consumed by `updateTerminal` or `deleteActive`, refused
`token-missing`; a custody entry created by `insertAbsent` and consumed by
`updateActive` or `deleteAbsent`, refused `not-booked`. -/
def consumeCreatedRows : List BatchScenario :=
  [ consumeCreated "BR15-insert-then-retire" [] .insertActive .updateTerminal
  , consumeCreated "BR16-insert-then-delete" [] .insertActive .deleteActive
  , consumeCreated "BR17-update-then-retire" [bookedAbsent] .updateActive .updateTerminal
  , consumeCreated "BR18-update-then-delete" [bookedAbsent] .updateActive .deleteActive
  , consumeCreated "BR19-book-then-update" [] .insertAbsent .updateActive
  , consumeCreated "BR20-book-then-delete" [] .insertAbsent .deleteAbsent ]

/-- The batch questions: a lawful two-request fold and its refused mutants — a
crossed claim, an empty batch, a later request the law refuses — a batch of one
beside the single step it preserves; two rejects judged paid, short, and short in
sum for one owner, a reject of one beside the single reject, and the batches the
driver does not answer. -/
def batchScenarios : List BatchScenario :=
  [ { id := "BR01-fold-two-registrations"
    , theoremName := bookedAtMostOnce, statementSha256 := bookedAtMostOnceDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := s0, setup := []
    , question := .foldBatch
        [registerActiveClaimed, claiming (request .insertAbsent 5 91 0 91 55)] }
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
    , outputs := some [ownerPaid 43 55, ownerPaid 44 40] }
  , { id := "BR07-reject-two-short"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken), (.reject, registerTakenAgain)]
    , outputs := some [ownerPaid 43 55, ownerPaid 44 39] }
    -- Two rejects owed to owner 43, 55 and 40, paid by one output of 55: each
    -- deposit alone is covered, their sum is not.
  , { id := "BR08-reject-one-owner-short-in-sum"
    , theoremName := noExitStrandsTheDeposit, statementSha256 := noExitStrandsTheDepositDigest
    , kind := "mutant", mutates := some "BR06-reject-two-paid"
    , requiresReachableState := true, start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken), (.reject, registerTakenTwice)]
    , outputs := some [ownerPaid 43 55] }
  , { id := "BR09-reject-one"
    , theoremName := rejectBatchOfOne, statementSha256 := rejectBatchOfOneDigest
    , kind := "witness", mutates := none, requiresReachableState := true
    , start := s0, setup := [registerActive]
    , question := .rejectBatch [(.reject, registerTaken)]
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
    -- Two registrations folded inside both windows under `sTimed`, then the same
    -- batch with one request submitted early enough that the bound passes its
    -- deadline: admission refuses the whole batch.
  , { id := "BR13-fold-two-in-window"
    , theoremName := foldInWindow, statementSha256 := foldInWindowDigest
    , kind := "witness", mutates := none, requiresReachableState := false
    , start := sTimed, setup := []
    , question := .foldBatch
        [registerActiveClaimed, claiming (request .insertAbsent 5 91 0 91 55)]
    , foldWitness := some { submittedAt := [10000, 10500], validTo := 11000 } }
  , { id := "BR14-fold-two-one-expired"
    , theoremName := foldPastDeadline, statementSha256 := foldPastDeadlineDigest
    , kind := "mutant", mutates := some "BR13-fold-two-in-window"
    , requiresReachableState := false, start := sTimed, setup := []
    , question := .foldBatch
        [registerActiveClaimed, claiming (request .insertAbsent 5 91 0 91 55)]
    , foldWitness := some { submittedAt := [10000, 9000], validTo := 11000 } }
  ] ++ consumeCreatedRows

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

def main : IO Unit := IO.println corpus.pretty
