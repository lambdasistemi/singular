import NoPin.ApplicationRequests.HistoryClaims
import NoPin.ApplicationRequests.ProofAudit

/-! Hypothetical history evidence: roots are the four frozen ledger names.
An unrelated declaration cannot change this definition closure. -/
namespace NoPin.ApplicationRequests.HistoryProofAudit
open Lean Elab Command

/-- Include constructor premises when a statement reaches an inductive relation.
The relation's sort alone does not expose its transition guards. -/
def historyClosure (env : Environment) (roots : Array Name) : Array Json := Id.run do
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
    if let .inductInfo relation := info then
      pending := relation.ctors ++ pending
    pending := info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending
  return records

elab "#history_proof_closure" : command => do
  let env ← getEnv
  let names := #[`NoPin.ApplicationRequests.HistoryStatements.supply_in_step,
    `NoPin.ApplicationRequests.HistoryStatements.one_live_token,
    `NoPin.ApplicationRequests.HistoryStatements.burn_only_terminating_fold,
    `NoPin.ApplicationRequests.HistoryStatements.no_remint_after_terminal]
  let mut roots := #[]
  for name in names do
    let info ← getConstInfo name
    roots := roots ++ info.type.getUsedConstants
  IO.println (Json.mkObj [("historyProofClosure", toJson (historyClosure env roots))]).compress

end NoPin.ApplicationRequests.HistoryProofAudit
