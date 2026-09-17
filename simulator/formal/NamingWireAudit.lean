import Lean
import Singular.NamingWireStatements

namespace Singular.NamingWireAudit
open Lean Elab Command

def standard : List Name := [``propext, ``Classical.choice, ``Quot.sound]

def audit (report : Bool) : CommandElabM Unit := do
  let env ← getEnv
  let some idx := env.getModuleIdx? `Singular.NamingWireStatements
    | throwError "Singular.NamingWireStatements is not imported"
  let names := (env.header.moduleData[idx]!.constNames.filter fun name =>
    name.getPrefix == `Singular.NamingWireStatements && !name.isInternalDetail).qsort Name.lt
  if names.isEmpty then throwError "no naming wire statements to audit"
  for name in names do
    let some (.thmInfo _) := env.find? name | throwError "{name} is not a theorem"
    let axioms ← collectAxioms name
    let extra := axioms.filter (· ∉ standard)
    unless extra.isEmpty do throwError "{name} depends on {extra}"
    if report then IO.println s!"AXIOMS {name} {axioms.toList}"

elab "#audit_naming_wire" : command => audit false
elab "#audit_naming_wire " &"report" : command => audit true

#audit_naming_wire

end Singular.NamingWireAudit
