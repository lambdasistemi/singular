import OpenDatumApplicationHeld.MoneyStatements
import OpenDatumApplicationHeld.RefundLifecycleStatements
import Lean

/-! The application-held open-datum model beside the current one.
Compiled correspondence and definition-closure observations. -/

open Lean Elab Command

#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.additive_payments
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.approvalBurn_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.approval_burn_open
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.bookRegistration_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.bookTermination_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.booking_authority_and_parameters
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.burning_grants_nothing
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.configurationCreate_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.configuration_immutable
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.expiredCleanup_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.folder_protection
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.liveUpdate_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.no_stuck_termination
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.ownerReclaim_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.registrationFold_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.registration_lifecycle
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.terminationFold_inversion
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.termination_burn
#print axioms OpenDatumApplicationHeld.RefundLifecycle.Statements.treasury_at_booking

private def investigationName (name : Name) : Name :=
  let text := name.toString
  if text.startsWith "SingularApplicationHeld.Assets." then
    ("NoPin." ++ (text.drop "SingularApplicationHeld.Assets.".length).toString).toName
  else if text.startsWith "SingularApplicationHeld." then
    ("NoPin.ApplicationRequests." ++ (text.drop "SingularApplicationHeld.".length).toString).toName
  else if text.startsWith "OpenDatumApplicationHeld." then
    ("NoPin.ApplicationRequests." ++ (text.drop "OpenDatumApplicationHeld.".length).toString).toName
  else name

private def investigationType (type : Expr) : Expr :=
  type.replace fun expression => match expression with
    | .const name levels =>
      let original := investigationName name
      if original == name then none else some (.const original levels)
    | _ => none

private def alphaExpr : Expr → Expr
  | .const name levels => .const (investigationName name) levels
  | .proj name index value => .proj (investigationName name) index (alphaExpr value)
  | .lam _ type body info => .lam .anonymous (alphaExpr type) (alphaExpr body) info
  | .forallE _ type body info => .forallE .anonymous (alphaExpr type) (alphaExpr body) info
  | .letE _ type value body nonDep => .letE .anonymous (alphaExpr type) (alphaExpr value) (alphaExpr body) nonDep
  | .app fn argument => .app (alphaExpr fn) (alphaExpr argument)
  | .mdata data value => .mdata data (alphaExpr value)
  | expression => expression

private def reached (env : Environment) (roots : List Name) (constructors : Bool) : Array Json := Id.run do
  let mut pending := roots
  let mut seen : NameSet := {}
  let mut records := #[]
  while !pending.isEmpty do
    let name := pending.head!
    pending := pending.tail!
    if seen.contains name then continue
    seen := seen.insert name
    let some info := env.find? name | continue
    let value := info.value? (allowOpaque := true)
    let members := if constructors then match info with
      | .inductInfo data => data.ctors ++ ((getStructureInfo? env name).map (fun s => s.fieldInfo.toList.map (·.projFn)) |>.getD [])
      | _ => []
      else []
    if name.toString.startsWith "Singular." || name.toString.startsWith "SingularApplicationHeld." ||
        name.toString.startsWith "OpenDatumApplicationHeld." || name.toString.startsWith "OpenDatumApplication." then
      records := records.push (Json.mkObj [("name", toJson (investigationName name).toString),
      ("currentName", toJson name.toString),
      ("type", toJson (reprStr info.type)), ("value", toJson (value.map reprStr)),
      ("alphaType", toJson (reprStr (alphaExpr info.type))),
      ("alphaValue", toJson (value.map (fun v => reprStr (alphaExpr v)))),
      ("members", toJson (members.map (fun n => (investigationName n).toString)))])
    pending := members ++ info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending
  return records

elab "#refund_types" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `OpenDatumApplicationHeld.RefundLifecycle.Statements
  let mut roots : List Name := []
  for (name, info) in statements do
    IO.println (Json.mkObj [("statement", toJson name.toString),
      ("type", toJson (reprStr (investigationType info.type))),
      ("dependencies", toJson (info.type.getUsedConstants.toList.map toString))]).compress
    roots := info.type.getUsedConstants.toList ++ roots
  IO.println (Json.mkObj [("definitionClosure", toJson (reached env roots true))]).compress
  for withConstructors in [false, true] do
    IO.println (Json.mkObj [("control", toJson withConstructors),
      ("closure", toJson (reached env [`Singular.Config, `Singular.RegistryState] withConstructors))]).compress

#refund_types

elab "#money_types" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `OpenDatumApplicationHeld.Money.Statements
  for (name, info) in statements do
    IO.println (Json.mkObj [("moneyStatement", toJson name.toString),
      ("type", toJson (reprStr (investigationType info.type))),
      ("compiledType", toJson (reprStr info.type)),
      ("axioms", toJson ((← collectAxioms name).toList.map toString)),
      ("closure", toJson (reached env info.type.getUsedConstants.toList true))]).compress
#money_types
