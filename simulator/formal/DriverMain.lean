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
  "9e8c6a06d60361ae94b24f50f014c7830bfdd5d22aa8b7a62a8ca9230f689153"
def foldBatchOfOne : String := "Singular.Statements.fold_batch_of_one_is_step"
def foldBatchOfOneDigest : String :=
  "09dc61dcbe8e7a4a68b170944bb42cdcf6ece9af9fc006af96135cfab1185f87"
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

/-- Explicit producer evidence; the driver itself never creates a proof. -/
def rejectionFor (s : RegistryState) (r : Request) (reason : RejectReason)
    (lo : Nat := 10001) (hi : Nat := 10002) : RejectWitness :=
  { evidence := { registry := s.config, registryId := s.config.registryId, request := r, reason := reason }
  , validFrom := lo, validTo := hi }

def registered : RegistryState := (runSetup sTimed [registerActive]).2.1

def rejectTheorem : String := "Singular.Statements.rejection_admitted_iff"
def rejectDigest : String := "f43e7df507ef67029d5f31885584cc360344bfe6fab9af5f38d3fddac08c577c"
def processTheorem : String := "Singular.Statements.process_actions_cons"
def processDigest : String := "a8e0db5aa39b1e5f1900b21720d60ce544af13242a846fec27c25b38b4c7721a"

def protectedRequest : Request := { registerTaken with submittedAt := 10000 }

def protectedScenario (id : String) (r : Request) (setup : List Request)
    (rejection : Option RejectWitness) : Scenario :=
  { id, theoremName := rejectTheorem, statementSha256 := rejectDigest
  , kind := "witness", mutates := none, requiresReachableState := !setup.isEmpty
  , start := sTimed, setup, exit := .reject, request := r, lovelace := r.deposit + r.tip
  , rejection }

/-- All 28 edge/leaf pairs, reached by real setup transitions. -/
def rejectionTable : List (Scenario × Bool) :=
  let edges := [Edge.insertAbsent, .insertActive, .updateActive, .updateTerminal,
                .deleteAbsent, .deleteActive, .witnessTerminal]
  let states : List (String × List Request × Leaf) :=
    [("unknown", [], .unknown),
     ("absent", [request .insertAbsent 42 91 0 91 55], .known .absent),
     ("active", [registerActive], .known .active),
     ("terminal", [registerActive, retireRegistered], .known .terminal)]
  edges.flatMap fun edge => states.map fun (name, setup, leaf) =>
    let r := { request edge 42 43 556 91 55 with submittedAt := 10000 }
    let state := (runSetup sTimed setup).2.1
    let sc := protectedScenario ("PR-table-" ++ edgeName edge ++ "-" ++ name) r setup
      (some (rejectionFor state r (.mismatch leaf)))
    -- Expectations are the seven-edge contract, separately stated from transition.
    let compatible := match edge, leaf with
      | .insertAbsent, .unknown | .insertActive, .unknown
      | .updateActive, .known .absent | .deleteAbsent, .known .absent
      | .updateTerminal, .known .active | .deleteActive, .known .active
      | .witnessTerminal, .known .terminal => true
      | _, _ => false
    (sc, !compatible)

/-- Positive and adversarial cases at the admission boundary. -/
def rejectionControls : List (Scenario × Option String) :=
  let r := protectedRequest
  let good := rejectionFor registered r (.mismatch (.known .active))
  let live := { registerActive with submittedAt := 10000 }
  let expiry := rejectionFor sTimed live .expired 11500 11501
  [ (protectedScenario "PR-mismatch" r [registerActive] (some good), none)
  , (protectedScenario "PR-missing" r [registerActive] none, some "reject-evidence-missing")
  , (protectedScenario "PR-wrong-root" r [registerActive]
      (some { good with evidence := { good.evidence with registry := sTimed.config } }),
      some "reject-registry-mismatch")
  , (protectedScenario "PR-wrong-registry" r [registerActive]
      (some { good with evidence := { good.evidence with
        registry := { registered.config with activePolicy := 88 } } }),
      some "reject-registry-mismatch")
  , (protectedScenario "PR-wrong-registry-identity" r [registerActive]
      (some { good with evidence := { good.evidence with registryId := 9 } }),
      some "reject-registry-mismatch")
  , (protectedScenario "PR-wrong-request" r [registerActive]
      (some { good with evidence := { good.evidence with request := { r with reference := 99 } } }),
      some "reject-request-mismatch")
  , (protectedScenario "PR-foreign-request-registry" { r with registryId := 9 } [registerActive]
      (some (rejectionFor registered { r with registryId := 9 } (.mismatch (.known .active)))),
      some "reject-registry-mismatch")
  , (protectedScenario "PR-forged-leaf" r [registerActive]
      (some { good with evidence := { good.evidence with reason := .mismatch .unknown } }),
      some "reject-leaf-mismatch")
  , (protectedScenario "PR-live-compatible" live []
      (some (rejectionFor sTimed live (.mismatch .unknown))), some "reject-compatible")
  , (protectedScenario "PR-expiry-boundary" live [] (some expiry), none)
  , (protectedScenario "PR-expiry-before" live []
      (some { expiry with validFrom := 11499 }), some "reject-not-expired")
  , (protectedScenario "PR-expiry-processing-end" live []
      (some { expiry with validFrom := 11000 }), some "reject-not-expired")
  , (protectedScenario "PR-expiry-empty-interval" live []
      (some { expiry with validTo := 11500 }), some "reject-invalid-interval")
  , (protectedScenario "PR-expiry-reversed-interval" live []
      (some { expiry with validTo := 11499 }), some "reject-invalid-interval")
  , (protectedScenario "PR-forged-submission" live []
      (some { expiry with evidence := { expiry.evidence with
        request := { live with submittedAt := 0 } }, validFrom := 11000 }),
      some "reject-request-mismatch")
  , (protectedScenario "PR-operational-no-approval" { live with approval := none } []
      (some (rejectionFor sTimed { live with approval := none } (.mismatch .unknown))),
      some "reject-compatible") ]

#guard rejectionTable.length == 28
#guard rejectionTable.all fun (sc, expected) =>
  let result := (runSurface sc).2
  result.premiseChecked && result.outcome == (if expected then .accepted else .refused) &&
    result.reason == (if expected then none else some "reject-compatible")
#guard rejectionControls.all fun (sc, reason) =>
  let result := (runSurface sc).2
  result.premiseChecked && result.reason == reason &&
    result.outcome == (if reason.isNone then .accepted else .refused)

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
    , exit := .reject, request := registerTaken, lovelace := lovelace
    , rejection := some (rejectionFor ((runSetup s0 [registerActive]).2.1)
        registerTaken (.mismatch (.known .active))) }
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
  ] ++ rejectionTable.map Prod.fst ++ rejectionControls.map Prod.fst

/-- The batch questions: a lawful two-request fold and its refused mutants — a
crossed claim, an empty batch, a later request the law refuses — a batch of one
beside the single step it preserves; two rejects judged paid, short, and short in
sum for one owner, a reject of one beside the single reject, and the batches the
driver does not answer. -/
def legacyBatchScenarios : List BatchScenario :=
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
  ]

def mixedBatch (id : String) (actions : List ProcessAction) : BatchScenario :=
  { id, theoremName := processTheorem, statementSha256 := processDigest
  , kind := "witness", mutates := none, requiresReachableState := false
  , start := sTimed, setup := [], question := .processBatch 10001 10002 actions }

def mixedControls : List (BatchScenario × Option String) :=
  let proof := (rejectionFor registered protectedRequest (.mismatch (.known .active))).evidence
  [ (mixedBatch "PR-batch-fold-then-reject"
      [.fold registerActiveClaimed, .reject protectedRequest (some proof)], none)
  , (mixedBatch "PR-batch-stale-root"
      [.fold registerActiveClaimed, .reject protectedRequest
        (some { proof with registry := sTimed.config })], some "reject-registry-mismatch")
  , (mixedBatch "PR-batch-reversed-actions"
      [.reject protectedRequest (some proof), .fold registerActiveClaimed],
      some "reject-registry-mismatch")
  , (mixedBatch "PR-batch-reject-then-fold"
      [.fold registerActiveClaimed, .reject protectedRequest (some proof),
       .fold (claiming retireRegistered)], none)
  , (mixedBatch "PR-batch-protect-compatible"
      [.reject registerActiveClaimed (some
        (rejectionFor sTimed registerActiveClaimed (.mismatch .unknown)).evidence)],
      some "reject-compatible")
  , (mixedBatch "PR-batch-wrong-mint"
      [.fold { registerActiveClaimed with claimed := [] }], some "net-mint-mismatch")
  , (mixedBatch "PR-batch-empty" [], some "empty-process-batch") ]

#guard scenarios.any fun sc => sc.id == "PR-retract-forged-time" &&
  (runSurface sc).2.reason == some "not-phase2"
#guard scenarios.any fun sc => sc.id == "PR-retract-ignores-witness-time" &&
  (runSurface sc).2.outcome == .accepted

#guard mixedControls.all fun (sc, reason) =>
  match sc.question with
  | .processBatch lo hi actions =>
    let result := (runProcessBatch sc.start sc.setup lo hi actions).2
    result.reason == reason && result.outcome == (if reason.isNone then .accepted else .refused)
  | _ => false

/-- All rejects in one transaction must use its one validity interval. -/
def inconsistentRejectIntervals : BatchScenario :=
  { id := "PR-reject-inconsistent-intervals", theoremName := rejectTheorem
  , statementSha256 := rejectDigest, kind := "witness", mutates := none
  , requiresReachableState := true, start := sTimed, setup := [registerActive]
  , question := .rejectBatch [(.reject, registerTaken), (.reject, registerTakenAgain)]
  , rejections :=
      [some (rejectionFor registered registerTaken (.mismatch (.known .active)))
      , some (rejectionFor registered registerTakenAgain (.mismatch (.known .active)) 10002 10003)] }

#guard (runRejectBatch sTimed [registerActive]
  [(.reject, registerTaken), (.reject, registerTakenAgain)]
  inconsistentRejectIntervals.rejections).2.reason == some "reject-batch-interval-mismatch"

def batchScenarios : List BatchScenario :=
  legacyBatchScenarios.map (fun sc =>
    match sc.question with
    | .rejectBatch rs =>
      let state := (runSetup sc.start sc.setup).2.1
      { sc with rejections := rs.map (fun (_, r) =>
          some (rejectionFor state r (.mismatch (trieGet state.trie r.key)))) }
    | _ => sc) ++ mixedControls.map Prod.fst ++ [inconsistentRejectIntervals]

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
