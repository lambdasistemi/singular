import NoPin.ApplicationRequests.LifecycleEvidence
import Lean

/-! Hypothetical #741 compiled inventory. General statements are deliberately
unproved; every finite certificate is axiom-scanned and type-bound. -/
namespace NoPin.ApplicationRequests.Lifecycle.Report
open Lean Elab Command Term Meta

elab "lifecycle_guards%" : term => do
  let .inductInfo info ← getConstInfo ``AppGuard | throwError "not an inductive guard"
  mkListLit (Lean.mkConst ``AppGuard) (info.ctors.map Lean.mkConst)
/-- Hypothesis under #741, not accepted law; discovered production selector extent. -/
def guards : List AppGuard := lifecycle_guards%

elab "#lifecycle_report" : command => do
  let env ← getEnv
  let .inductInfo actions ← getConstInfo ``ApplicationAction | throwError "not an action datatype"
  let .inductInfo sites ← getConstInfo ``AppGuard | throwError "not a guard datatype"
  IO.println (Json.mkObj [("family", toJson "lifecycle"),
    ("constructors", toJson (actions.ctors.map (·.getString!))),
    ("guards", toJson (sites.ctors.map (·.getString!)))]).compress
  for constructor in actions.ctors do
    let inversion := Name.str `NoPin.ApplicationRequests.Lifecycle.Statements (constructor.getString! ++ "_inversion")
    unless env.contains inversion do throwError "missing source-derived inversion: {constructor}"
  for (name, info) in env.constants.toList do
    if name.getPrefix == `NoPin.ApplicationRequests.Lifecycle.Statements ||
        (name.getPrefix == `NoPin.ApplicationRequests.Lifecycle.Evidence &&
          match info with | .thmInfo _ => true | _ => false) then
      if name.getPrefix == `NoPin.ApplicationRequests.Lifecycle.Statements then
        liftTermElabM do
          let witnessName := Name.str `NoPin.ApplicationRequests.Lifecycle.Evidence (name.getString! ++ "_antecedent")
          let positiveName := Name.str `NoPin.ApplicationRequests.Lifecycle.Evidence (name.getString! ++ "_positive")
          let mutantName := Name.str `NoPin.ApplicationRequests.Lifecycle.Evidence (name.getString! ++ "_mutant")
          let (parameters, _, conclusion) ← forallMetaTelescope info.type
          let proof := parameters.back!
          let witness := Lean.mkConst witnessName
          unless ← isDefEq (← inferType proof) (← inferType witness) do
            throwError "incomplete lifecycle antecedent: {name}"
          proof.mvarId!.assign witness
          unless ← isDefEq conclusion (← inferType (Lean.mkConst positiveName)) do
            throwError "wrong lifecycle consequence: {name}"
          let mutant ← getConstInfo mutantName
          let .app (.const `Not _) implication := mutant.type | throwError "not a falsification"
          let repaired := implication.replace fun e =>
            if e.isAppOf ``AppMutation.flip then some (Lean.mkConst ``AppMutation.none) else none
          let expected ← mkArrow (← inferType witness) (← inferType (Lean.mkConst positiveName))
          unless ← isDefEq repaired expected do throwError "mutant not bound to complete statement: {name}"
          IO.println (Json.mkObj [("family", toJson "lifecycle"), ("binding", toJson name.toString),
            ("witness", toJson witnessName.toString), ("positive", toJson positiveName.toString),
            ("mutant", toJson mutantName.toString)]).compress
      IO.println (Json.mkObj [("family", toJson "lifecycle"), ("name", toJson name.toString),
        ("type", toJson (reprStr info.type)), ("doc", toJson ((← findDocString? env name).getD "")),
        ("axioms", toJson ((← collectAxioms name).toList.map toString))]).compress

/-- Hypothesis under #741, not accepted law; execute all source-derived selectors and constructor examples. -/
def reportCorpus : IO Unit := do
  for selected in guards do
    let changed := guards.filter fun site =>
      appGuard (.flip selected) site true != appGuard .none site true ||
      appGuard (.flip selected) site false != appGuard .none site false
    unless changed == [selected] do throw (IO.userError "selector changes multiple sites")
  for (name, _) in Fixtures.examples do
    let q := Fixtures.inputFor name
    unless actionName q.action == name do throw (IO.userError "constructor witness mismatch")
    let step := applicationStep .none NoPin.ApplicationRequests.Fixtures.hash
      NoPin.ApplicationRequests.Fixtures.code NoPin.ApplicationRequests.Fixtures.decode
      NoPin.ApplicationRequests.Fixtures.release q.observation
    unless step do throw (IO.userError "positive application refused")
    let used := guards.filter fun guard =>
      !(applicationStep (.flip guard) NoPin.ApplicationRequests.Fixtures.hash
        NoPin.ApplicationRequests.Fixtures.code NoPin.ApplicationRequests.Fixtures.decode
        NoPin.ApplicationRequests.Fixtures.release q.observation)
    IO.println (Json.mkObj [("family", toJson "lifecycle"), ("constructor", toJson name),
      ("selectors", toJson used)]).compress
    for mutation in AppMutation.none :: used.map AppMutation.flip do
      let scenario : Scenario := ⟨.step, q, mutation⟩
      let .ok result := runScenario scenario | throw (IO.userError "incomplete lifecycle scenario")
      IO.println (Json.mkObj [("family", toJson "lifecycle"), ("scenario", toJson scenario),
        ("result", toJson result)]).compress
  let scenario : Scenario := ⟨.publicTermination, Fixtures.terminationInput, .none⟩
  let .ok result := runScenario scenario | throw (IO.userError "incomplete public termination")
  unless result do throw (IO.userError "public termination refused")
  IO.println (Json.mkObj [("family", toJson "lifecycle"), ("scenario", toJson scenario),
    ("result", toJson result)]).compress

end NoPin.ApplicationRequests.Lifecycle.Report
