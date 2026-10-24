import NoPin.ApplicationRequests.Statements
import Lean

/-! Hypothetical investigation evidence: freeze the kernel definitions reached
from statement types, independently of the new proof terms. -/
namespace NoPin.ApplicationRequests.ProofAudit
open Lean Elab Command

/-- Hypothesis evidence: the refutation must negate the exact frozen proposition. -/
def exactNegation (statement refutation : Name) : MetaM Bool := do
  let proposition := (← getConstInfo statement).type
  let actual := (← getConstInfo refutation).type
  Meta.isDefEq actual (mkApp (mkConst ``Not) proposition)

/-- Hypothesis evidence, not accepted law; transitively inspect types and values. -/
def closure (env : Environment) (roots : Array Name) : Array Json := Id.run do
  let mut pending := roots.toList
  let mut seen : NameSet := {}
  let mut records := #[]
  while !pending.isEmpty do
    let name := pending.head!
    pending := pending.tail!
    if seen.contains name then continue
    seen := seen.insert name
    let some info := env.find? name | continue
    let value := info.value? (allowOpaque := true)
    records := records.push (Json.mkObj [
      ("name", toJson name.toString), ("type", toJson (reprStr info.type)),
      ("levels", toJson (info.levelParams.map toString)),
      ("value", toJson (value.map reprStr))])
    pending := info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending
  return records

elab "#singular_proof_closure" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `NoPin.ApplicationRequests.Statements
  let roots := statements.foldl (fun roots (_, info) => roots ++ info.type.getUsedConstants) #[]
  IO.println (Json.mkObj [("proofClosure", toJson (closure env roots))]).compress

end NoPin.ApplicationRequests.ProofAudit
