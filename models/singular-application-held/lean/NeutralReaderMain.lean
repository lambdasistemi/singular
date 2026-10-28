import SingularApplicationHeld.ReaderQuery

/-- Execute the neutral reader on exactly one JSON evidence scenario. -/
def main : IO UInt32 := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let stderr ← IO.getStderr
  let source ← stdin.readToEnd
  match Lean.Json.parse source >>= Lean.fromJson? (α := SingularApplicationHeld.ReaderQuery) with
  | .error reason =>
    stderr.putStrLn reason
    return 1
  | .ok query =>
    stdout.putStrLn (Lean.toJson (SingularApplicationHeld.runNeutralReaderQuery query)).compress
    return 0
