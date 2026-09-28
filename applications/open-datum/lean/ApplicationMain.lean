import OpenDatumApplication

/-! # The application driver executable

* `corpus` prints every corpus scenario run through `appStep`;
* `run appStep` reads ONE scenario from standard input and prints its run;
* `replay` reads a corpus from standard input, reruns every scenario from its
  own recorded JSON through the same runner, and fails unless every recomputed
  run equals the recorded one;
* `ledgers` prints the theorem and semantic-atom ledgers.

Any parse failure, unknown surface or mismatch exits non-zero. -/

open Lean
open OpenDatumApplication.Driver

def readStdin : IO String := do
  let stdin ← IO.getStdin
  let mut text := ""
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    text := text ++ line
  pure text

def parseOrFail (text : String) : IO Json :=
  match Json.parse text with
  | .ok j => pure j
  | .error e => throw (IO.userError s!"input is not JSON: {e}")

def main (args : List String) : IO UInt32 := do
  match args with
  | ["corpus"] =>
    IO.println corpusJson.pretty
    pure 0
  | ["ledgers"] =>
    IO.println (Json.mkObj [("theorems", theoremLedger), ("atoms", atomLedger)]).pretty
    pure 0
  | ["run", "appStep"] =>
    let j ← parseOrFail (← readStdin)
    match scenarioFromJson j with
    | .ok s =>
      IO.println (runScenario s).pretty
      pure 0
    | .error e =>
      IO.eprintln s!"scenario does not decode: {e}"
      pure 2
  | ["replay"] =>
    let j ← parseOrFail (← readStdin)
    let rows ← match j.getArr? with
      | .ok a => pure a.toList
      | .error e => throw (IO.userError s!"corpus is not an array: {e}")
    let mut failures := 0
    for row in rows do
      match row.getObjVal? "scenario" >>= scenarioFromJson with
      | .error e =>
        IO.eprintln s!"scenario does not decode: {e}"
        failures := failures + 1
      | .ok s =>
        if runScenario s != row then
          IO.eprintln s!"replay differs: {s.name}"
          failures := failures + 1
    IO.println s!"replayed {rows.length} scenarios, {failures} differing"
    pure (if failures == 0 && !rows.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: open-datum-application corpus | ledgers | run appStep | replay"
    pure 2
