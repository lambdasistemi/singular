import OpenDatumApplication

/-! # The application driver executable

* `corpus` / `ledgers` print the generated corpus / ledgers;
* `run appStep` reads ONE scenario from standard input and prints its run;
* `write DIR` writes `DIR/corpus.json` and `DIR/ledgers.json`;
* `check DIR` fails unless:
  - the regenerated corpus and ledgers equal the committed files;
  - every committed scenario replays from its own JSON to its recorded run;
  - each check notices a controlled alteration: a changed recorded outcome is
    caught by replay and by the corpus comparison, and a dropped ledger row by
    the ledger comparison;
  - each definition mutant of the law runs at least one scenario differently
    from the committed corpus;
  - every genesis and accepted step of every scenario observes the invariant,
    and every accepting constructor has a reached accepted step;
  - at the invariant boundary the ordinary reached world is consistent and the
    identical-duplicate world is not, its accepted update leaving two outputs
    of one key, while the observation without its occurrence clause would
    admit it.

Any parse failure, unknown mode or failed check exits non-zero. -/

open Lean
open OpenDatumApplication
open OpenDatumApplication.Driver

def readStdin : IO String := do
  let stdin ← IO.getStdin
  let mut text := ""
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    text := text ++ line
  pure text

def parseOrFail (what text : String) : IO Json :=
  match Json.parse text with
  | .ok j => pure j
  | .error e => throw (IO.userError s!"{what} is not JSON: {e}")

def orFail {α : Type} (what : String) : Except String α → IO α
  | .ok a => pure a
  | .error e => throw (IO.userError s!"{what}: {e}")

/-- Report one check and count it as failed unless it holds. -/
def report (ok : Bool) (line : String) : IO Nat := do
  let tag := if ok then "PASS" else "FAIL"
  IO.println s!"{tag} {line}"
  pure (if ok then 0 else 1)

def check (dir : String) : IO UInt32 := do
  let corpus ← parseOrFail "corpus.json" (← IO.FS.readFile s!"{dir}/corpus.json")
  let ledgers ← parseOrFail "ledgers.json" (← IO.FS.readFile s!"{dir}/ledgers.json")
  let mut failed := 0
  failed := failed + (← report (corpusJson == corpus)
    "the regenerated corpus equals the committed corpus")
  failed := failed + (← report (ledgersJson == ledgers)
    "the regenerated ledgers equal the committed ledgers")
  let diffs ← orFail "replay" (replayDiffs corpus)
  failed := failed + (← report diffs.isEmpty
    s!"every committed scenario replays from its own JSON ({diffs.length} differing: {diffs})")
  let altered ← orFail "alteration" (alterFirstOutcome corpus)
  let alteredDiffs ← orFail "replay of the altered corpus" (replayDiffs altered)
  failed := failed + (← report (!alteredDiffs.isEmpty)
    s!"control: replay notices one altered recorded outcome ({alteredDiffs})")
  failed := failed + (← report (corpusJson != altered)
    "control: the corpus comparison notices one altered recorded outcome")
  let droppedRow : Json := Json.mkObj [("theorems", Json.arr (theoremLedger.getArr?.toOption.getD #[]).pop)
    , ("atoms", atomLedger)]
  failed := failed + (← report (ledgersJson != droppedRow)
    "control: the ledger comparison notices one dropped theorem row")
  for (name, law) in mutants do
    let moved ← orFail s!"mutant {name}" (differingUnder law corpus)
    failed := failed + (← report (!moved.isEmpty)
      s!"control: definition mutant {name} runs {moved.length} scenarios differently: {moved}")
  failed := failed + (← report inconsistentReached.isEmpty
    s!"every genesis and every accepted step of every scenario observes the invariant ({inconsistentReached})")
  let exercised := ["bookInsert", "bookTerminate", "update", "fold", "reject"]
  failed := failed + (← report (exercised.all acceptedConstructors.contains)
    s!"every accepting constructor has a reached accepted step: {acceptedConstructors}")
  let ordinaryAfter := match appStep ordinaryWorld boundaryUpdate with
    | .ok w' => appConsistentB w'
    | .error _ => false
  failed := failed + (← report (appConsistentB ordinaryWorld && ordinaryAfter)
    "boundary: the ordinary reached world is consistent, and so is its updated successor")
  let duplicateAfter := match appStep duplicatedWorld boundaryUpdate with
    | .ok w' => some (appConsistentB w')
    | .error _ => none
  failed := failed + (← report (!appConsistentB duplicatedWorld && duplicateAfter == some false)
    "boundary: the identical-duplicate world is outside the invariant; its accepted update leaves two outputs of one key")
  failed := failed + (← report (appConsistentBWith false duplicatedWorld)
    "control: without the occurrence clause the observation would admit the identical-duplicate world")
  IO.println s!"application checks: {failed} failed"
  pure (if failed == 0 then 0 else 1)

def main (args : List String) : IO UInt32 := do
  match args with
  | ["corpus"] =>
    IO.println corpusJson.pretty
    pure 0
  | ["ledgers"] =>
    IO.println ledgersJson.pretty
    pure 0
  | ["write", dir] =>
    IO.FS.writeFile s!"{dir}/corpus.json" (corpusJson.pretty ++ "\n")
    IO.FS.writeFile s!"{dir}/ledgers.json" (ledgersJson.pretty ++ "\n")
    IO.println s!"wrote {dir}/corpus.json and {dir}/ledgers.json"
    pure 0
  | ["check", dir] => check dir
  | ["run", "appStep"] =>
    let j ← parseOrFail "scenario" (← readStdin)
    match scenarioFromJson j with
    | .ok s =>
      IO.println (runScenario s).pretty
      pure 0
    | .error e =>
      IO.eprintln s!"scenario does not decode: {e}"
      pure 2
  | _ =>
    IO.eprintln "usage: open-datum-application corpus | ledgers | write DIR | check DIR | run appStep"
    pure 2
