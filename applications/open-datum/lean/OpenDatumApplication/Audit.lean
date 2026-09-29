import Lean
import OpenDatumApplication.Statements

/-! # The compiled proof status of the open-datum statements

Every public theorem of `OpenDatumApplication.Statements` is discovered from the
compiled environment — never from a list — together with the axioms the kernel
reports it depending on (`collectAxioms`) and its declaration header as written
in `Statements.lean`. `compiledStatements` embeds that table in the application
executable, which is the only writer of `ledgers.json`; the generator derives
each row's status and header hash from it (`Driver.reconcileStatements`).

`#audit_open_datum` fails elaboration when a statement depends on an axiom other
than the standard three or `sorryAx`, so no build can carry a custom axiom;
`#audit_open_datum report` prints one `AXIOMS` line per statement, the saved
report the repository's independent bridge reads. Private helpers are internal
names and are not statements. -/

namespace OpenDatumApplication.Audit

open Lean Elab Command Term

/-- The public theorems of `OpenDatumApplication.Statements`, in name order. -/
def discoveredStatements {m : Type → Type} [Monad m] [MonadEnv m] [MonadError m] :
    m (Array Name) := do
  let env ← getEnv
  let some idx := env.getModuleIdx? `OpenDatumApplication.Statements
    | throwError "OpenDatumApplication.Statements is not imported"
  let names := (env.header.moduleData[idx]!.constNames.filter fun n =>
    n.getPrefix == `OpenDatumApplication.Statements && !n.isInternalDetail).qsort Name.lt
  if names.isEmpty then throwError "no statement to audit"
  for n in names do
    let some (.thmInfo _) := env.find? n | throwError "{n} is not a theorem"
  return names

/-- The axioms a statement depends on, as names, sorted. -/
def axiomsOf {m : Type → Type} [Monad m] [MonadEnv m] (n : Name) : m (List String) := do
  let axioms ← collectAxioms n
  return (axioms.map toString).qsort (· < ·) |>.toList

/-- A statement's declaration header as written: from `theorem` through the
first ` := by` after its name. Refused unless the name's header occurs exactly
once. -/
def headerOf (source : String) (n : Name) : Except String String := do
  let short := n.getString!
  match source.splitOn ("\ntheorem " ++ short ++ " ") with
  | [_, rest] =>
    match rest.splitOn " := by" with
    | head :: _ :: _ => pure ("theorem " ++ short ++ " " ++ head ++ " := by")
    | _ => throw s!"{n}: no ' := by' after its header"
  | _ => throw s!"{n}: its header does not occur exactly once"

def audit (report : Bool) : CommandElabM Unit := do
  for n in ← discoveredStatements do
    let axioms ← axiomsOf n
    let extra := axioms.filter fun a =>
      !(a == "propext" || a == "Classical.choice" || a == "Quot.sound" || a == "sorryAx")
    unless extra.isEmpty do throwError "{n} depends on {extra}"
    if report then IO.println s!"AXIOMS {n} {axioms}"

elab "#audit_open_datum" : command => audit false
elab "#audit_open_datum " &"report" : command => audit true

/-- The compiled statement table, built while this module elaborates from the
same environment and the same `Statements.lean` the build just compiled. -/
elab "compiled_statements%" : term => do
  let file ← getFileName
  let some dir := (System.FilePath.mk file).parent
    | throwError "no directory for {file}"
  let source ← IO.FS.readFile (dir / "Statements.lean")
  let rows ← (← discoveredStatements).toList.mapM fun n => do
    let header ← match headerOf source n with
      | .ok h => pure h
      | .error e => throwError e
    pure (n.toString, ← axiomsOf n, header)
  return toExpr rows

#audit_open_datum

/-- Every compiled statement: qualified name, reported axioms, header. -/
def compiledStatements : List (String × List String × String) := compiled_statements%

end OpenDatumApplication.Audit
