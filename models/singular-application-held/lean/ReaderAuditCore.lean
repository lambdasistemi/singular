import SingularApplicationHeld.ReaderStatements
import SingularApplicationHeld.ReaderQuery
import Lean

namespace ReaderAuditSupport
open Lean Elab Command

private def projectName (name : Name) : Bool :=
  ["Singular.", "SingularApplicationHeld.", "OpenDatumApplicationHeld."].any
    (fun part => name.toString.startsWith part)

private def reached (env : Environment) (roots : List Name) : Array Json := Id.run do
  let mut pending := roots
  let mut seen : NameSet := {}
  let mut records := #[]
  while !pending.isEmpty do
    let name := pending.head!
    pending := pending.tail!
    if seen.contains name then continue
    seen := seen.insert name
    if !projectName name then continue
    let some info := env.find? name | continue
    let value := info.value? (allowOpaque := true)
    let members := match info with
      | .inductInfo data => data.ctors ++
          ((getStructureInfo? env name).map (fun s => s.fieldInfo.toList.map (·.projFn)) |>.getD [])
      | _ => []
    records := records.push (Json.mkObj [("name", toJson name.toString),
      ("type", toJson (reprStr info.type)), ("value", toJson (value.map reprStr))])
    pending := members ++ info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending
  return records

private def emit (namespaces : Array Name) : CommandElabM Unit := do
  let env ← getEnv
  let mut roots : List Name := []
  for (name, info) in env.constants.toList do
    if !namespaces.contains name.getPrefix then continue
    let .thmInfo _ := info | continue
    let field := if info.type.isAppOf ``LawfulBEq then "readerSupport" else "readerStatement"
    IO.println (Json.mkObj [(field, toJson name.toString),
      ("type", toJson (reprStr info.type)),
      ("axioms", toJson ((← collectAxioms name).toList.map toString))]).compress
    if field == "readerStatement" then roots := info.type.getUsedConstants.toList ++ roots
  for name in [`SingularApplicationHeld.readKey, `SingularApplicationHeld.recognizeReaderState,
      `SingularApplicationHeld.ReaderEvidenceCorrespondence, `SingularApplicationHeld.runReaderQuery] do
    let some info := env.find? name | throwError "missing reader definition {name}"
    IO.println (Json.mkObj [("readerDefinition", toJson name.toString),
      ("type", toJson (reprStr info.type)),
      ("value", toJson ((info.value? (allowOpaque := true)).map reprStr))]).compress
    roots := name :: roots
  IO.println (Json.mkObj [("readerClosure", toJson (reached env roots))]).compress

elab "#reader_audit_shared" : command =>
  emit #[`SingularApplicationHeld.ReaderStatements]

elab "#reader_audit_all" : command =>
  emit #[`SingularApplicationHeld.ReaderStatements, `OpenDatumApplicationHeld.ReaderStatements,
    `OpenDatumApplicationHeld.ReaderFixtures]

end ReaderAuditSupport
