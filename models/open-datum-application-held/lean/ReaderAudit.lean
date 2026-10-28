import OpenDatumApplicationHeld.ReaderFixtures
import Lean

open Lean Elab Command

/-- Report elaborated statements and the executable definitions they constrain. -/
elab "#reader_audit" : command => do
  let env ← getEnv
  let namespaces := [`SingularApplicationHeld.ReaderStatements,
    `OpenDatumApplicationHeld.ReaderStatements, `OpenDatumApplicationHeld.ReaderFixtures]
  for (name, info) in env.constants.toList do
    if !namespaces.contains name.getPrefix then continue
    let .thmInfo _ := info | continue
    IO.println (Json.mkObj [
      ("readerStatement", toJson name.toString),
      ("type", toJson (reprStr info.type)),
      ("axioms", toJson ((← collectAxioms name).toList.map toString))]).compress
  for name in [`SingularApplicationHeld.readKey, `SingularApplicationHeld.recognizeReaderState,
      `SingularApplicationHeld.ReaderEvidenceCorrespondence, `SingularApplicationHeld.runReaderQuery] do
    let some info := env.find? name | throwError "missing reader definition {name}"
    IO.println (Json.mkObj [
      ("readerDefinition", toJson name.toString),
      ("type", toJson (reprStr info.type)),
      ("value", toJson ((info.value? (allowOpaque := true)).map reprStr))]).compress

#reader_audit
