import Singular.NamingAudit

/-! Executable naming corpus oracle. Replays the frozen naming journey and the
crafted negative controls through the real naming functions, checks every
expectation, and prints the naming corpus for the source-level identity check.
The naming profile is an unaccepted candidate; these rows are finite model
evidence, not a ledger claim. -/
namespace Singular
open Lean

def namingInitial : NamingState := {}

def craftedDeleteRequest (state : NamingState) (id : Nat) : Request :=
  { id := id, operation := Operation.delete, proposal := { registry := state.registry.config.registry, key := aliceKey, applicationPolicy := state.registry.config.applicationPolicy, refundAddress := 0, initial := { representative := representative state.registry aliceKey, quantity := 1, destination := demoDestination, datum := demoDatum, value := demoValue }, scope := [(entry state.registry aliceKey).incarnation] }, token := Option.none, held := some (representative state.registry aliceKey), destination := state.registry.config.requestAddress, authenticatedOrigin := true }

def craftedRelease (state : NamingState) (source id : Nat) : Action :=
  .release source (craftedDeleteRequest state id) { source := source, request := craftedDeleteRequest state id, accepted := true } { applicationSpend := true }

def craftedRefund : Refund := { destination := 60, value := 20 }

def craftedInsertRequest (state : NamingState) (key policy id : Nat) : Request :=
  let output : Output := { representative := representative state.registry key, quantity := 1, destination := demoDestination, datum := demoDatum, value := demoValue }
  let proposal : Proposal := { registry := state.registry.config.registry, key := key, applicationPolicy := policy, refundAddress := demoRefundAddress, initial := output, scope := [(entry state.registry key).incarnation] }
  { id := id, operation := Operation.insert, proposal := proposal, token := some (insertAsset proposal), held := Option.none, destination := state.registry.config.requestAddress, authenticatedOrigin := true }

def craftedCreateInsert (state : NamingState) (key policy id : Nat) (accepted : Bool) : Action :=
  let request := craftedInsertRequest state key policy id
  let asset := insertAsset request.proposal
  Action.createInsert request { asset := asset, accepted := accepted } { applicationMint := true }

def tamperedFold (state : NamingState) (requestId : Nat) : Action :=
  match state.registry.requests.find? (fun q => q.id == requestId) with
  | some r => Action.fold [{ request := requestId, outputId := freshId state.registry, output := some { r.proposal.initial with representative := { r.proposal.initial.representative with registry := 99 } } }] [{ asset := representative state.registry r.proposal.key, quantity := 1 }] [] { nativeSpend := true, representativeMint := true }
  | none => Action.fold [] [] [] { nativeSpend := true }

/-- A crafted naming state whose queued Insert carries a substituted
representative: the registered identity does not match the registry. -/
def substitutedRepState : NamingState :=
  let output : Output := { representative := { registry := 1, key := aliceKey, policy := 8, assetScope := 5 }, quantity := 1, destination := demoDestination, datum := demoDatum, value := demoValue }
  let proposal : Proposal := { registry := 1, key := aliceKey, applicationPolicy := 7, refundAddress := demoRefundAddress, initial := output, scope := [0] }
  let request : Request := { id := 7, operation := Operation.insert, proposal := proposal, token := some (insertAsset proposal), held := Option.none, destination := 90, authenticatedOrigin := true }
  { claimedOnce with registry := { claimedOnce.registry with requests := request :: claimedOnce.registry.requests, approvals := { asset := insertAsset proposal, accepted := true } :: claimedOnce.registry.approvals } }

def substitutedRepFold : Action :=
  Action.fold [{ request := 7, outputId := 9, output := some { representative := { registry := 1, key := aliceKey, policy := 8, assetScope := 5 }, quantity := 1, destination := demoDestination, datum := demoDatum, value := demoValue } }] [{ asset := { registry := 1, key := aliceKey, policy := 8, assetScope := 5 }, quantity := 1 }] [] { nativeSpend := true, representativeMint := true }

def queuedFoldAction (state : NamingState) (requestId : Nat) : Action :=
  match state.registry.requests.find? (fun q => q.id == requestId) with
  | some r => Action.fold [{ request := requestId, outputId := freshId state.registry, output := some r.proposal.initial }] [{ asset := representative state.registry r.proposal.key, quantity := 1 }] [] { nativeSpend := true, representativeMint := true }
  | none => Action.fold [] [] [] { nativeSpend := true }

structure SpellingRow where
  id : String
  spelling : String
  expected : Option Nat
  deriving ToJson

structure QueueRow where
  id : String
  before : NamingState
  spelling : String
  fixture : NamingFixture
  accepted : Bool
  expectedReason : String := ""
  deriving ToJson

structure FoldRow where
  id : String
  before : NamingState
  requestId : Nat
  accept : Bool
  expectedReason : String := ""
  deriving ToJson

structure StepRow where
  id : String
  before : NamingState
  action : Action
  accept : Bool
  expectedReason : String := ""
  deriving ToJson

structure ResolveRow where
  id : String
  before : NamingState
  spelling : String
  authenticated : Bool
  expected : Json
  deriving ToJson

structure ReplayRow where
  id : String
  before : NamingState
  actions : List Action
  expectedState : NamingState
  deriving ToJson

def spellingRows : List SpellingRow := [
  { id := "SP01-alice-defined", spelling := "alice", expected := some aliceKey },
  { id := "SP02-unknown-refused", spelling := "carol", expected := none }]

def queueRows : List QueueRow := [
  { id := "NQ01-alice-first-queues", before := namingInitial, spelling := "alice", fixture := aliceFixture, accepted := true },
  { id := "NQ02-competing-claim-queues", before := claimedOnce, spelling := "alice", fixture := otherFixture, accepted := true },
  { id := "NQ03-unapproved-refused", before := namingInitial, spelling := "alice", fixture := aliceFixture, accepted := false, expectedReason := "application-approval" },
  { id := "NQ04-unknown-spelling-refused", before := namingInitial, spelling := "carol", fixture := aliceFixture, accepted := false, expectedReason := "unknown-spelling" },
  { id := "NQ05-malformed-fixture-refused", before := namingInitial, spelling := "alice", fixture := malformedFixture, accepted := false, expectedReason := "invalid-fixture" },
  { id := "NQ06-approval-while-active-queues", before := activeOnce, spelling := "alice", fixture := aliceFixture, accepted := true }]

def foldRows : List FoldRow := [
  { id := "NF01-first-absent-key-fold", before := claimedTwice, requestId := 1, accept := true },
  { id := "NF02-competing-fold-occupied", before := activeOnce, requestId := 2, accept := false, expectedReason := "occupied-key" },
  { id := "NF03-unknown-request-refused", before := activeOnce, requestId := 9, accept := false, expectedReason := "request-unavailable" },
  { id := "NF04-replay-refused", before := activeOnce, requestId := 1, accept := false, expectedReason := "request-unavailable" }]

def foldWithClaim : Action := queuedFoldAction claimedTwice 1

def stepRows : List StepRow := [
  { id := "NS01-crafted-release-delete", before := activeOnce, action := craftedRelease activeOnce 3 9, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS02-crafted-withdraw", before := activeOnce, action := Action.withdraw 1 { policy := 7, name := Commitment.withdraw 1 1 craftedRefund } craftedRefund { nativeSpend := true }, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS03-crafted-evolve", before := activeOnce, action := .evolve 3 { id := 5, key := aliceKey, output := { representative := representative activeOnce.registry aliceKey, quantity := 1, destination := demoDestination, datum := 200, value := demoValue } } { source := 3, successor := { id := 5, key := aliceKey, output := { representative := representative activeOnce.registry aliceKey, quantity := 1, destination := demoDestination, datum := 200, value := demoValue } }, accepted := true } { applicationSpend := true }, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS04-crafted-mint-withdraw", before := activeOnce, action := .mintWithdraw { asset := { policy := 7, name := Commitment.withdraw 1 1 craftedRefund }, accepted := true } { applicationMint := true }, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS05-crafted-outsider", before := claimedOnce, action := Action.outsider (craftedInsertRequest claimedOnce aliceKey 7 1), accept := false, expectedReason := "naming-no-delete" },
  { id := "NS06-crafted-move-action", before := claimedOnce, action := Action.moveAction (insertAsset (craftedInsertRequest claimedOnce aliceKey 7 1).proposal) 0 {}, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS07-crafted-escape", before := claimedOnce, action := Action.escape 1, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS08-fold-of-delete-request", before := { activeOnce with registry := { activeOnce.registry with requests := craftedDeleteRequest activeOnce 9 :: activeOnce.registry.requests } }, action := Action.fold [{ request := 9 }] [] [] { nativeSpend := true }, accept := false, expectedReason := "naming-no-delete" },
  { id := "NS09-substituted-policy", before := claimedOnce, action := craftedCreateInsert claimedOnce aliceKey 99 2 true, accept := false, expectedReason := "insert-binding" },
  { id := "NS10-unapproved-insert", before := claimedOnce, action := craftedCreateInsert claimedOnce aliceKey 7 2 false, accept := false, expectedReason := "application-approval" },
  { id := "NS11-substituted-representative", before := substitutedRepState, action := substitutedRepFold, accept := false, expectedReason := "representative-identity" },
  { id := "NS12-fold-request-parity", before := claimedTwice, action := foldWithClaim, accept := true },
  { id := "NS13-crafted-occupied-fold", before := activeOnce, action := queuedFoldAction activeOnce 2, accept := false, expectedReason := "occupied-key" },
  { id := "NS14-tampered-item-output", before := claimedTwice, action := tamperedFold claimedTwice 1, accept := false, expectedReason := "certified-output" }]

def resolveRows : List ResolveRow := [
  { id := "NR01-unauthenticated-view", before := claimedTwice, spelling := "alice", authenticated := false, expected := toJson NamingObservation.unauthenticated },
  { id := "NR02-two-claims-pending", before := claimedTwice, spelling := "alice", authenticated := true, expected := toJson NamingObservation.pending },
  { id := "NR03-active-certified-fixture", before := activeOnce, spelling := "alice", authenticated := true, expected := toJson (NamingObservation.active aliceFixture) },
  { id := "NR04-absent-initial", before := namingInitial, spelling := "alice", authenticated := true, expected := toJson NamingObservation.absent },
  { id := "NR05-active-second-claim-pending", before := activeOnce, spelling := "alice", authenticated := true, expected := toJson (NamingObservation.active aliceFixture) },
  { id := "NR06-unknown-spelling", before := namingInitial, spelling := "carol", authenticated := true, expected := Json.mkObj [("error", toJson "unknown-spelling")] }]

def replayRows : List ReplayRow := [
  { id := "NRP01-journey-fold-replay", before := claimedTwice, actions := [queuedFoldAction claimedTwice 1], expectedState := activeOnce },
  { id := "NRP02-refusal-replay-keeps-state", before := activeOnce, actions := [craftedRelease activeOnce 3 9, Action.escape 9], expectedState := activeOnce }]

def queueVerdict (row : QueueRow) : Except String NamingQueueOutcome :=
  namingQueue row.before row.spelling row.fixture row.accepted

def queueCorrect (row : QueueRow) : Bool :=
  match queueVerdict row with
  | .ok _ => row.accepted
  | .error reason => !row.accepted && reason == row.expectedReason

def foldVerdict (row : FoldRow) : Except String NamingResult :=
  namingFoldRequest row.before row.requestId

def foldCorrect (row : FoldRow) : Bool :=
  match foldVerdict row with
  | .ok _ => row.accept
  | .error reason => !row.accept && reason == row.expectedReason

def stepVerdict (row : StepRow) : Except String NamingResult :=
  namingStep row.before row.action

def stepCorrect (row : StepRow) : Bool :=
  match stepVerdict row with
  | .ok _ => row.accept
  | .error reason => !row.accept && reason == row.expectedReason

def verdictJson (r : Except String NamingResult) : Json :=
  match r with
  | .ok v => Json.mkObj [("accepted", toJson true), ("value", toJson v)]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def queueJson (r : Except String NamingQueueOutcome) : Json :=
  match r with
  | .ok o => Json.mkObj [("accepted", toJson true), ("requestId", toJson o.requestId), ("value", Json.mkObj [("state", toJson o.state)])]
  | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)]

def resolveJson (r : Except String NamingObservation) : Json :=
  match r with
  | .ok o => toJson o
  | .error reason => Json.mkObj [("error", toJson reason)]

def namingResolveSpelling (state : NamingState) (spelling : String) (authenticated : Bool) :
    Except String NamingObservation :=
  if !authenticated then .ok .unauthenticated
  else match spellingKey spelling with
    | some key => namingResolve state key authenticated
    | none => .error "unknown-spelling"

def replayJson (state : NamingState) (actions : List Action) : Json :=
  let replay := namingReplay state actions
  Json.mkObj [("state", toJson replay.state),
    ("records", toJson (replay.records.map fun pair =>
      Json.mkObj [("action", toJson pair.1), ("result", verdictJson pair.2)]))]

def queueRowJson (row : QueueRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before), ("spelling", toJson row.spelling),
    ("fixture", toJson row.fixture), ("accepted", toJson row.accepted), ("result", queueJson (queueVerdict row))]

def foldRowJson (row : FoldRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before), ("requestId", toJson row.requestId),
    ("result", verdictJson (foldVerdict row))]

def stepRowJson (row : StepRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before), ("action", toJson row.action),
    ("result", verdictJson (stepVerdict row))]

def resolveRowJson (row : ResolveRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before), ("spelling", toJson row.spelling),
    ("authenticated", toJson row.authenticated),
    ("expected", resolveJson (namingResolveSpelling row.before row.spelling row.authenticated))]

def replayRowJson (row : ReplayRow) : Json :=
  Json.mkObj [("id", toJson row.id), ("before", toJson row.before), ("actions", toJson row.actions),
    ("expected", replayJson row.before row.actions)]

end Singular

open Lean Singular

def main : IO Unit := do
  let stdout ← IO.getStdout
  for row in spellingRows do
    unless spellingKey row.spelling == row.expected do
      throw (IO.userError s!"spelling expectation failed: {row.id}")
  for row in queueRows do
    unless queueCorrect row do
      throw (IO.userError s!"queue expectation failed: {row.id}: {repr (queueVerdict row)}")
  for row in foldRows do
    unless foldCorrect row do
      throw (IO.userError s!"fold expectation failed: {row.id}: {repr (foldVerdict row)}")
  for row in stepRows do
    unless stepCorrect row do
      throw (IO.userError s!"step expectation failed: {row.id}: {repr (stepVerdict row)}")
  for row in resolveRows do
    unless resolveJson (namingResolveSpelling row.before row.spelling row.authenticated) == row.expected do
      throw (IO.userError s!"resolve expectation failed: {row.id}")
  for row in replayRows do
    let replay := namingReplay row.before row.actions
    unless replay.state == row.expectedState do
      throw (IO.userError s!"replay state failed: {row.id}")
  let json := Json.mkObj [("schema", toJson "singular-naming-corpus-v1"),
    ("spellings", toJson (spellingRows.map fun row => Json.mkObj [("id", toJson row.id), ("spelling", toJson row.spelling), ("expected", toJson row.expected)])),
    ("queues", toJson (queueRows.map queueRowJson)),
    ("folds", toJson (foldRows.map foldRowJson)),
    ("steps", toJson (stepRows.map stepRowJson)),
    ("resolves", toJson (resolveRows.map resolveRowJson)),
    ("replays", toJson (replayRows.map replayRowJson))]
  stdout.putStrLn json.compress
