import NoPin.Oracle
import NoPin.Held.Oracle
import NoPin.ApplicationRequests.Oracle

/-! Hypothetical #741 oracle, not accepted law: JSON scenarios from stdin.
This executes named definitions, never statements or theorem projections. -/

/-- Hypothesis oracle under #741, not accepted law; identity and role questions. -/
def main : IO UInt32 := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  repeat
    let input ← stdin.getLine
    if input.isEmpty then return 0
    let parsed := Lean.Json.parse input
    if let .ok json := parsed then
      if (json.getObjValAs? String "family").toOption == some "application-requests" then
        match Lean.fromJson? (α := NoPin.ApplicationRequests.Scenario) json with
        | .error error =>
          (← IO.getStderr).putStrLn error
          return 1
        | .ok scenario =>
          match NoPin.ApplicationRequests.runQuery scenario.mutation scenario.query with
          | .error error =>
            (← IO.getStderr).putStrLn error
            return 1
          | .ok result => stdout.putStrLn (Lean.toJson result).compress
          continue
      if (json.getObjValAs? String "family").toOption == some "held" then
        match Lean.fromJson? (α := NoPin.Held.Scenario) json with
        | .error error =>
          (← IO.getStderr).putStrLn error
          return 1
        | .ok scenario =>
          stdout.putStrLn (Lean.toJson (NoPin.Held.runQuery scenario.mutation scenario.query)).compress
          continue
    match parsed >>= Lean.fromJson? (α := NoPin.Scenario) with
    | .error error =>
        (← IO.getStderr).putStrLn error
        return 1
    | .ok scenario =>
        stdout.putStrLn (Lean.toJson (NoPin.runQuery scenario.mutation scenario.query)).compress
  return 0
