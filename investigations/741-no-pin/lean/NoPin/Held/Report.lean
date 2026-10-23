import Lean
import NoPin.Held.StrongMutants
import NoPin.Held.Mutants

/-! Compiled evidence for #741 hypotheses, not accepted law. Constructor
inventories and case bindings come from the environment, never a hand list. -/
namespace NoPin.Held.Report
open Lean Elab Command Term Meta

/-- Hypothesis evidence under #741, not accepted law; compiled constructors. -/
def constructors (name : Name) : TermElabM (List Name) := do
  let .inductInfo info ← getConstInfo name | throwError "not an inductive: {name}"
  return info.ctors
elab "held_cases%" : term => do
  mkListLit (mkConst ``Case) ((← constructors ``Case).map mkConst)
elab "held_guards%" : term => do
  mkListLit (mkConst ``Guard) ((← constructors ``Guard).map mkConst)
/-- Hypothesis evidence under #741, not accepted law; discovered public cases. -/
def cases : List Case := held_cases%
/-- Hypothesis evidence under #741, not accepted law; discovered atomic guards. -/
def guards : List Guard := held_guards%

elab "#held_report" : command => do
  let env ← getEnv
  for (name, info) in env.constants.toList do
    if name.getPrefix == `NoPin.Held.Statements ||
        ((name.getPrefix == `NoPin.Held.Fixtures || name.getPrefix == `NoPin.Held.Instances ||
          name.getPrefix == `NoPin.Held.Mutants) &&
          match info with | .thmInfo _ => true | _ => false) then
      if name.getPrefix == `NoPin.Held.Statements then
        liftTermElabM do
          let premise := mkApp (mkConst (Name.str `NoPin.Held.Instances (name.getString! ++ "_premise"))) (mkConst `NoPin.Held.Mutation.none)
          let claim := mkApp (mkConst (Name.str `NoPin.Held.Instances (name.getString! ++ "_claim"))) (mkConst `NoPin.Held.Mutation.none)
          forallTelescope (← inferType premise) fun xs _ => do
            let arrow ← mkArrow (mkAppN premise xs) (mkAppN claim xs)
            let expected ← mkForallFVars xs arrow
            unless ← isDefEq info.type expected do throwError "statement/instance mismatch: {name}"
      let doc := (← findDocString? env name).getD ""
      let axioms ← collectAxioms name
      let kind := match info with | .thmInfo _ => "theorem" | _ => "other"
      let value := info.value? (allowOpaque := true)
      let dependencies := value.map Expr.getUsedConstants |>.getD #[]
      let candidateType := match info.type with
        | .app (.const `Not _) inner => inner.replace fun e =>
            if e.isAppOf `NoPin.Held.Mutation.flip then some (mkConst `NoPin.Held.Mutation.none) else none
        | _ => info.type
      let inversion ← liftTermElabM do
        if !name.getString!.endsWith "_inversion" then return Json.null
        forallTelescope info.type fun xs _ => do
          unless xs.size == 4 do throwError "inversion does not bind hash, codec, query, case: {name}"
          let q := xs[2]!
          let premise ← inferType xs[3]!
          for c in ← constructors ``Case do
            let expected ← mkEq (mkApp (mkConst ``Query.surface) q) (mkConst c)
            if ← isDefEq premise expected then return toJson c.getString!
          throwError "inversion not bound to a public case: {name}"
      IO.println (Json.mkObj [
        ("family", toJson "held"), ("inversion", inversion),
        ("candidateType", toJson (reprStr candidateType)),
        ("kind", toJson kind), ("name", toJson name.toString), ("doc", toJson doc),
        ("type", toJson (reprStr info.type)),
        ("axioms", toJson (axioms.toList.map toString)),
        ("dependencies", toJson (dependencies.toList.map toString))]).compress


/-- Hypothesis evidence under #741, not accepted law; actual producer execution and selector truth table. -/
def reportControls : IO Unit := do
  for selected in guards do
    let changed := guards.filter fun site =>
      applyGuard (.flip selected) site true != applyGuard .none site true ||
      applyGuard (.flip selected) site false != applyGuard .none site false
    unless changed == [selected] do throw (IO.userError "selector changed more than one guard")
  for surface in cases do
    let q := Fixtures.goodQuery surface
    unless runQuery .none q do throw (IO.userError ("candidate refused " ++ (toJson surface).compress))
    let used := guards.filter fun guard => !runQuery (.flip guard) q
    IO.println (Json.mkObj [("family", toJson "held"), ("case", toJson surface), ("guards", toJson used)]).compress
    IO.println (Json.mkObj [("family", toJson "held"), ("scenario", toJson (Scenario.mk q .none)),
      ("result", toJson (runQuery .none q))]).compress
    for guard in used do
      IO.println (Json.mkObj [("family", toJson "held"), ("scenario", toJson (Scenario.mk q (.flip guard))),
        ("result", toJson (runQuery (.flip guard) q))]).compress
  IO.println (Json.mkObj [("family", toJson "held"), ("roles", toJson ([] : List String)),
    ("guards", toJson guards), ("cases", toJson cases)]).compress

end NoPin.Held.Report
