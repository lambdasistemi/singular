import NoPin.Oracle

/-! Hypothetical #741 oracle, not accepted law: JSON scenarios from stdin.
This executes named definitions, never statements or theorem projections. -/

/-- Hypothesis oracle under #741, not accepted law; identity and role questions. -/
def main : IO UInt32 := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  repeat
    let input ← stdin.getLine
    if input.isEmpty then return 0
    match Lean.Json.parse input >>= Lean.fromJson? (α := NoPin.Scenario) with
    | .error error =>
        (← IO.getStderr).putStrLn error
        return 1
    | .ok scenario =>
        stdout.putStrLn (Lean.toJson (NoPin.runQuery scenario.mutation scenario.query)).compress
  return 0
