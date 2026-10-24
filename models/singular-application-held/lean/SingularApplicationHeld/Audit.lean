import SingularApplicationHeld.HistoryClaims
import SingularApplicationHeld.Statements
import Lean

/-! The application-held Singular model beside the current one, to be removed
with it in #743. Compiled statements rename constant names back to the
investigation vocabulary before reprStr, preserving its width-sensitive layout.
Root-dependency records print the unchanged root constants directly. -/

#print axioms SingularApplicationHeld.Statements.active_role_never_state
#print axioms SingularApplicationHeld.Statements.batch_effects
#print axioms SingularApplicationHeld.Statements.batch_inversion
#print axioms SingularApplicationHeld.Statements.fold_minted_outputs
#print axioms SingularApplicationHeld.Statements.fold_untouched_keys
#print axioms SingularApplicationHeld.Statements.genesis_inversion
#print axioms SingularApplicationHeld.Statements.minted_active_never_state
#print axioms SingularApplicationHeld.Statements.public_fold_constructed
#print axioms SingularApplicationHeld.Statements.public_fold_effects
#print axioms SingularApplicationHeld.Statements.publicFold_inversion
#print axioms SingularApplicationHeld.Statements.recognition_inversion
#print axioms SingularApplicationHeld.Statements.registration_effects
#print axioms SingularApplicationHeld.Statements.registration_inversion
#print axioms SingularApplicationHeld.Statements.registration_separate_holdings
#print axioms SingularApplicationHeld.Statements.termination_effects
#print axioms SingularApplicationHeld.Statements.termination_inversion

open Lean Elab Command

private def investigationType (type : Expr) : Expr :=
  type.replace fun expression => match expression with
    | .const name levels =>
      let text := name.toString
      if text.startsWith "SingularApplicationHeld.Assets." then
        some (.const ("NoPin." ++ (text.drop "SingularApplicationHeld.Assets.".length).toString).toName levels)
      else if text.startsWith "SingularApplicationHeld." then
        some (.const ("NoPin.ApplicationRequests." ++ (text.drop "SingularApplicationHeld.".length).toString).toName levels)
      else none
    | _ => none

elab "#application_held_types" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `SingularApplicationHeld.Statements
  let mut pending : List Name := []
  for (name, info) in statements do
    IO.println (Json.mkObj [("statement", toJson name.toString),
      ("type", toJson (reprStr (investigationType info.type)))]).compress
    pending := info.type.getUsedConstants.toList ++ pending
  let mut seen : NameSet := {}
  while !pending.isEmpty do
    let name := pending.head!
    pending := pending.tail!
    if seen.contains name then continue
    seen := seen.insert name
    let some info := env.find? name | continue
    let value := info.value? (allowOpaque := true)
    if name.toString.startsWith "Singular." then
      IO.println (Json.mkObj [("root", toJson name.toString),
        ("type", toJson (reprStr info.type)),
        ("value", toJson (value.map reprStr))]).compress
    pending := info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending

#application_held_types

private def investigationName (name : Name) : Name :=
  let text := name.toString
  if text.startsWith "SingularApplicationHeld.Assets." then
    ("NoPin." ++ (text.drop "SingularApplicationHeld.Assets.".length).toString).toName
  else if text.startsWith "SingularApplicationHeld." then
    ("NoPin.ApplicationRequests." ++ (text.drop "SingularApplicationHeld.".length).toString).toName
  else if text.startsWith "OpenDatumApplicationHeld." then
    ("NoPin.ApplicationRequests." ++ (text.drop "OpenDatumApplicationHeld.".length).toString).toName
  else name

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
    if name.toString.startsWith "Singular." || name.toString.startsWith "SingularApplicationHeld." then
      records := records.push (Json.mkObj [("name", toJson (investigationName name).toString),
      ("currentName", toJson name.toString),
      ("type", toJson (reprStr info.type)), ("value", toJson (value.map reprStr)),
      ("alphaType", toJson (reprStr (alphaExpr info.type))),
      ("alphaValue", toJson (value.map (fun v => reprStr (alphaExpr v)))),
      ("members", toJson (members.map (fun n => (investigationName n).toString)))])
    pending := members ++ info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending
  return records


elab "#history_types" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `SingularApplicationHeld.HistoryStatements
  for (name, info) in statements do
    IO.println (Json.mkObj [("historyStatement", toJson name.toString),
      ("type", toJson (reprStr (investigationType info.type))),
      ("compiledType", toJson (reprStr info.type)),
      ("axioms", toJson ((← collectAxioms name).toList.map toString)),
      ("closure", toJson (reached env info.type.getUsedConstants.toList true))]).compress
#history_types
