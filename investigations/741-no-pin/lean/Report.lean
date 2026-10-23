import Lean
import NoPin
import NoPin.Oracle
import NoPin.Held.Report
import NoPin.ApplicationRequests.Report

/-! Hypothetical #741 evidence, not accepted law. Discover statements, cases,
guards and compiled proof axioms from the environment rather than a hand list. -/

namespace NoPin.Report
open Lean Elab Command Term Meta

/-- Hypothesis evidence under #741, not accepted law; compiled enumeration inventory. -/
def constructors (name : Name) : TermElabM (List Name) := do
  let .inductInfo info ← getConstInfo name | throwError "not an inductive: {name}"
  return info.ctors

elab "case_values%" : term => do
  mkListLit (mkConst ``Case) ((← constructors ``Case).map mkConst)
elab "guard_values%" : term => do
  mkListLit (mkConst ``Guard) ((← constructors ``Guard).map mkConst)
elab "role_values%" : term => do
  mkListLit (mkConst ``Role) ((← constructors ``Role).map mkConst)

/-- Hypothesis inventory under #741, not accepted law; generated from constructors. -/
def cases : List Case := case_values%
/-- Hypothesis inventory under #741, not accepted law; generated from constructors. -/
def guards : List Guard := guard_values%
/-- Hypothesis inventory under #741, not accepted law; generated from constructors. -/
def roles : List Role := role_values%

elab "#identity_report" : command => do
  let env ← getEnv
  let mut stated : NameSet := {}
  for file in ← ("investigations/741-no-pin" : System.FilePath).readDir do
    if !file.fileName.endsWith "statements.json" then continue
    let .ok ledger := Json.parse (← IO.FS.readFile file.path) | throwError "invalid statement ledger"
    let .ok rows := ledger.getObjValAs? (Array Json) "statements" | throwError "missing statement rows"
    for row in rows do
      let proofStatus := ((row.getObjValAs? String "proofStatus").toOption).getD
        (((row.getObjValAs? String "status").toOption).getD "")
      if proofStatus == "STATED" then
        let .ok name := row.getObjValAs? String "theorem" | throwError "missing statement name"
        stated := stated.insert name.toName
  for (name, info) in env.constants.toList do
    if name.toString.startsWith "NoPin." then
      if let .axiomInfo _ := info then throwError "custom axiom: {name}"
      let axioms ← collectAxioms name
      let extra := axioms.toList.filter fun a => a != `propext && a != `Classical.choice && a != `Quot.sound
      unless extra.isEmpty || (stated.contains name && extra.all (· == `sorryAx)) do
        throwError "unproved candidate definition or example: {name}"
    if name.getPrefix == `NoPin.Statements ||
        ((name.getPrefix == `NoPin.Fixtures || name.getPrefix == `NoPin.Mutants) &&
         match info with | .thmInfo _ => true | _ => false) then
      if name.getPrefix == `NoPin.Statements then
        liftTermElabM do
          let base := Name.str `NoPin.Fixtures name.getString!
          let premise := mkApp (mkConst (Name.str `NoPin.Fixtures (name.getString! ++ "_premise"))) (mkConst `NoPin.Mutation.none)
          let claim := mkApp (mkConst (Name.str `NoPin.Fixtures (name.getString! ++ "_claim"))) (mkConst `NoPin.Mutation.none)
          let _ := base
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
            if e.isAppOf `NoPin.Mutation.flip then some (mkConst `NoPin.Mutation.none) else none
        | _ => info.type
      IO.println (Json.mkObj [
        ("candidateType", toJson (reprStr candidateType)),
        ("kind", toJson kind), ("name", toJson name.toString), ("doc", toJson doc),
        ("type", toJson (reprStr info.type)),
        ("axioms", toJson (axioms.toList.map toString)),
        ("dependencies", toJson (dependencies.toList.map toString))]).compress

#identity_report

/-- Hypothesis fixture under #741, not accepted law; good oracle input for mutation-site discovery. -/
def goodQuery (surface : Case) : Query :=
  let role := match surface with
    | .witness => Role.witness | .trieReady => .trieReady | .application => .application
    | _ => .state
  let registry : Singular.TokenId := ⟨10, 20⟩
  let payload : Payload := ⟨1, 7, 42, 99, 3⟩
  let hashes := [⟨encode (.role .witness registry 7), 31⟩,
    ⟨encode (.role .trieReady registry 7), 32⟩,
    ⟨encode (.role .application registry 7), 33⟩,
    ⟨encode (.approval registry payload), 34⟩,
    ⟨encode (.approval { registry with policy := 0 } payload), 35⟩]
  let binding := if surface == .approvalNameOnly then Binding.nameOnly else .full
  let asset := roleAsset (lookupHash hashes) encode registry role 7
  let tx : TxView := ⟨[⟨11, 2⟩], [⟨[(registry, 1)]⟩], [(registry, 1)], [registry.policy]⟩
  { surface, hashes, application := 5, registry, payload, key := 7,
    supplied := approvalAsset binding (lookupHash hashes) encode 5 registry payload,
    observation := ⟨asset, true, asset⟩, seed := ⟨11, 2⟩, transaction := tx, history := [tx] }

/-- Hypothesis evidence under #741, not accepted law; executing each selector at all discovered sites. -/
def reportControls : IO Unit := do
  for selected in guards do
    let changed := guards.filter fun site =>
      applyGuard (.flip selected) site true != applyGuard .none site true ||
      applyGuard (.flip selected) site false != applyGuard .none site false
    unless changed == [selected] do throw (IO.userError "selector changed more than one guard")
  for surface in cases do
    let q := goodQuery surface
    unless runQuery .none q do throw (IO.userError "candidate refused positive oracle query")
    let used := guards.filter fun guard => !runQuery (.flip guard) q
    IO.println (Json.mkObj [("case", toJson surface), ("guards", toJson used)]).compress
    IO.println (Json.mkObj [("scenario", toJson (Scenario.mk q .none)),
      ("result", toJson (runQuery .none q))]).compress
    for guard in used do
      IO.println (Json.mkObj [("scenario", toJson (Scenario.mk q (.flip guard))),
        ("result", toJson (runQuery (.flip guard) q))]).compress
  IO.println (Json.mkObj [("roles", toJson roles), ("guards", toJson guards),
    ("cases", toJson cases)]).compress

#eval reportControls

end NoPin.Report

#held_report
#eval NoPin.Held.Report.reportControls

#application_requests_report
#singular_proof_closure
#eval NoPin.ApplicationRequests.Report.reportControls

#history_report
#eval NoPin.ApplicationRequests.HistoryReport.reportCorpus

#lifecycle_report
#eval NoPin.ApplicationRequests.Lifecycle.Report.reportCorpus

#refund_lifecycle_report
#eval NoPin.ApplicationRequests.RefundLifecycle.Report.reportCorpus

#money_report
#eval NoPin.ApplicationRequests.Money.Report.reportCorpus
