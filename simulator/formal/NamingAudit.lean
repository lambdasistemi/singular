import Lean
import Singular.NamingStatements

/-! Compiled naming axiom gate. Every theorem declared in `Singular.NamingStatements`
must be proved from the standard axioms alone (`propext`, `Classical.choice`, `Quot.sound`).
The check runs while this module elaborates, so a successful `lake build` of the naming
modules is the evidence that no statement depends on `sorryAx`. `#audit_naming_statements
report` prints one `AXIOMS` line per theorem for the source-level manifest check. -/
namespace Singular.NamingAudit
open Lean Elab Command

def standard : List Name := [``propext, ``Classical.choice, ``Quot.sound]

def audit (report : Bool) : CommandElabM Unit := do
  let env ← getEnv
  let some idx := env.getModuleIdx? `Singular.NamingStatements
    | throwError "Singular.NamingStatements is not imported"
  let names := (env.header.moduleData[idx]!.constNames.filter fun n =>
    n.getPrefix == `Singular.NamingStatements && !n.isInternalDetail).qsort Name.lt
  if names.isEmpty then throwError "no naming statement to audit"
  for n in names do
    let some (.thmInfo _) := env.find? n | throwError "{n} is not a theorem"
    let axioms ← collectAxioms n
    let extra := axioms.filter (· ∉ standard)
    unless extra.isEmpty do throwError "{n} depends on {extra}"
    if report then IO.println s!"AXIOMS {n} {axioms.toList}"

elab "#audit_naming_statements" : command => audit false
elab "#audit_naming_statements " &"report" : command => audit true

#audit_naming_statements

end Singular.NamingAudit
