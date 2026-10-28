import OpenDatumApplicationHeld.ReaderFixtures

/-- Export replayable observations and their definition-computed answers. -/
def main : IO Unit := do
  let stdout ← IO.getStdout
  for (name, query) in OpenDatumApplicationHeld.ReaderFixtures.corpus do
    stdout.putStrLn (Lean.Json.mkObj [
      ("name", Lean.toJson name),
      ("query", Lean.toJson query),
      ("answer", Lean.toJson (SingularApplicationHeld.runReaderQuery query))]).compress
