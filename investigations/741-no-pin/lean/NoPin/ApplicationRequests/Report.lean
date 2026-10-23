import NoPin.ApplicationRequests.Evidence
import NoPin.ApplicationRequests.ProofAudit
import Lean

/-! Compiled #741 candidate evidence, not accepted law. Inventories are derived
from Lean constructors; witnesses and general statement types are joined in the
compiled environment. Mutants change exactly one declared guard selector. -/
namespace NoPin.ApplicationRequests.Report
open Lean Elab Command Term Meta

/-- Hypothesis evidence under #741, not accepted law; compiled constructor extent. -/
def constructors (name : Name) : TermElabM (List Name) := do
  let .inductInfo info ← getConstInfo name | throwError "not inductive: {name}"
  return info.ctors
elab "request_cases%" : term => do
  mkListLit (mkConst ``Case) ((← constructors ``Case).map mkConst)
elab "request_guards%" : term => do
  mkListLit (mkConst ``Guard) ((← constructors ``Guard).map mkConst)
/-- Hypothesis evidence under #741, not accepted law; all actual public surfaces. -/
def cases : List Case := request_cases%
/-- Hypothesis evidence under #741, not accepted law; all production guard constructors. -/
def guards : List Guard := request_guards%

elab "#application_requests_report" : command => do
  let env ← getEnv
  let .ok ledger := Json.parse (← IO.FS.readFile "investigations/741-no-pin/application-requests-statements.json")
    | throwError "invalid Singular proof ledger"
  let .ok rows := ledger.getObjValAs? (Array Json) "statements" | throwError "missing proof rows"
  let changes ← liftTermElabM do constructors ``Change
  IO.println (Json.mkObj [("family", toJson "application-requests"),
    ("sourceChanges", toJson (changes.map (·.getString!)))]).compress
  for (name, info) in env.constants.toList do
    if name.getPrefix == `NoPin.ApplicationRequests.Statements ||
        (name.getPrefix == `NoPin.ApplicationRequests.Evidence &&
          match info with | .thmInfo _ => true | _ => false) then
      let isStatement := name.getPrefix == `NoPin.ApplicationRequests.Statements
      let inversion ← liftTermElabM do
        if !isStatement then return Json.null
        let premiseName := Name.str `NoPin.ApplicationRequests.Evidence (name.getString! ++ "_premise")
        let claimName := Name.str `NoPin.ApplicationRequests.Evidence (name.getString! ++ "_claim")
        let premise := mkApp (mkConst premiseName) (mkConst ``Mutation.none)
        let claim := mkApp (mkConst claimName) (mkConst ``Mutation.none)
        forallTelescope (← inferType premise) fun xs _ => do
          let arrow ← mkArrow (mkAppN premise xs) (mkAppN claim xs)
          let expected ← mkForallFVars xs arrow
          unless ← isDefEq info.type expected do throwError "statement/instance mismatch: {name}"
        if !name.getString!.endsWith "_inversion" then return Json.null
        let caseName := name.getString! |>.dropEnd "_inversion".length |>.toString
        unless (← constructors ``Case).any (fun c => c.getString! == caseName) do
          throwError "inversion not bound to a public case: {name}"
        forallTelescope info.type fun xs _ => do
          unless xs.size == 5 do throwError "inversion telescope shape: {name}"
          let q := xs[3]!
          let c : Expr := Lean.mkConst (Name.str `NoPin.ApplicationRequests.Case caseName)
          let caseEq ← mkEq (mkApp (mkConst `NoPin.ApplicationRequests.Query.surface) q) c
          let shapeEq ← mkEq (mkApp (mkConst `NoPin.ApplicationRequests.caseShape) q) (mkConst `Bool.true)
          let expected ← mkAppM `And #[caseEq, shapeEq]
          unless ← isDefEq (← inferType xs[4]!) expected do
            throwError "inversion is not bound to its actual source/action case: {name}"
        return toJson caseName
      let axioms ← collectAxioms name
      let mut refutation := Json.null
      if isStatement then
        for row in rows do
          if (row.getObjValAs? String "theorem").toOption != some name.toString then continue
          if (row.getObjValAs? String "status").toOption != some "REFUTED" then continue
          let .ok proof := row.getObjValAs? String "refutation" | throwError "missing refutation"
          let exactType ← liftTermElabM <| ProofAudit.exactNegation name proof.toName
          unless exactType do throwError "refutation negates another proposition: {name}"
          let used ← collectAxioms proof.toName
          refutation := Json.mkObj [("name", toJson proof), ("exact", toJson exactType),
            ("axioms", toJson (used.toList.map toString))]
      let doc := (← findDocString? env name).getD ""
      let candidateType := match info.type with
        | .app (.const `Not _) inner => inner.replace fun e =>
            if e.isAppOf ``Mutation.flip then some (mkConst ``Mutation.none) else none
        | _ => info.type
      IO.println (Json.mkObj [("family", toJson "application-requests"),
        ("inversion", inversion), ("name", toJson name.toString),
        ("kind", toJson (match info with | .thmInfo _ => "theorem" | _ => "other")),
        ("type", toJson (reprStr info.type)), ("candidateType", toJson (reprStr candidateType)),
        ("doc", toJson doc), ("refutation", refutation), ("axioms", toJson (axioms.toList.map toString))]).compress

/-- Hypothesis evidence under #741, not accepted law; execute every discovered selector and surface. -/
def reportControls : IO Unit := do
  for selected in guards do
    let changed := guards.filter fun site =>
      applyGuard (.flip selected) site true != applyGuard .none site true ||
      applyGuard (.flip selected) site false != applyGuard .none site false
    unless changed == [selected] do throw (IO.userError "selector affects multiple guards")
  for surface in cases do
    let q := Evidence.goodQuery surface
    unless (runQuery .none q).toOption == some true do throw (IO.userError "candidate refuses positive case")
    let used := guards.filter fun guard => (runQuery (.flip guard) q).toOption == some false
    IO.println (Json.mkObj [("family", toJson "application-requests"),
      ("case", toJson surface), ("guards", toJson used)]).compress
    for mutation in Mutation.none :: used.map Mutation.flip do
      let .ok result := runQuery mutation q | throw (IO.userError "oracle observation incomplete")
      IO.println (Json.mkObj [("family", toJson "application-requests"),
        ("scenario", toJson (Scenario.mk q mutation)), ("result", toJson result)]).compress
  for (label, q, guard) in Evidence.badQueries ++ Evidence.repairBadQueries do
    unless (runQuery .none q).toOption == some false &&
        (runQuery (.flip guard) q).toOption == some true do
      throw (IO.userError ("boundary control does not isolate its guard: " ++ label))
    for mutation in [Mutation.none, Mutation.flip guard] do
      let .ok result := runQuery mutation q | throw (IO.userError "bad-control parse")
      IO.println (Json.mkObj [("family", toJson "application-requests"),
        ("attack", toJson label), ("scenario", toJson (Scenario.mk q mutation)), ("result", toJson result)]).compress
  IO.println (Json.mkObj [("family", toJson "application-requests"),
    ("cases", toJson cases), ("guards", toJson guards), ("roles", toJson ([] : List String))]).compress

end NoPin.ApplicationRequests.Report
