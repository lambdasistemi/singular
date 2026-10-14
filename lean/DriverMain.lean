import DriverMain.Fixtures
import DriverMain.Rejection
import DriverMain.Scenarios
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

def foldBatchCons : String := "Singular.Statements.fold_batch_cons"
def foldBatchConsDigest : String :=
  "a0992d97ae5b6f86503bdc5247b4b2602ec74a5516713e274c4919aa53d5d26f"
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
  , ({ windowScenario "DR22-reject-past-deadline" windowFirst (some 80001) with exit := .reject, foldWitness := none
      , rejection := some (rejectionFor windowState windowFirst .expired 80001 80002) }, .accepted, none)
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
