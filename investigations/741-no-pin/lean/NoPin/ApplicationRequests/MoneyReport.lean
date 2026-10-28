import NoPin.ApplicationRequests.MoneyUpdate
import NoPin.ApplicationRequests.MoneyRefutation
import NoPin.ApplicationRequests.MoneyHoldingSeparated
import NoPin.ApplicationRequests.ProofAudit

/-! Hypothetical compiled comparison inventory, not accepted law. Extents,
certificate bindings, accepted dependencies and every amount come from Lean. -/
namespace NoPin.ApplicationRequests.Money.Report
open Lean Elab Command Term Meta

elab "money_journeys%" : term => do
  let .inductInfo info ← getConstInfo ``Journey | throwError "not a journey datatype"
  mkListLit (Lean.mkConst ``Journey) (info.ctors.map Lean.mkConst)
elab "money_parties%" : term => do
  let .inductInfo info ← getConstInfo ``Party | throwError "not a party datatype"
  mkListLit (Lean.mkConst ``Party) (info.ctors.map Lean.mkConst)
elab "money_sites%" : term => do
  let .inductInfo info ← getConstInfo ``Site | throwError "not an allocation-site datatype"
  mkListLit (Lean.mkConst ``Site) (info.ctors.map Lean.mkConst)
/-- Hypothesis under #741, not accepted law; compiled stage extent. -/
def journeys : List Journey := money_journeys%
/-- Hypothesis under #741, not accepted law; compiled recipient extent. -/
def parties : List Party := money_parties%
/-- Hypothesis under #741, not accepted law; compiled allocation mutation extent. -/
def sites : List Site := money_sites%
/-- Hypothesis under #741, not accepted law; classify the accepted consumer's actual constructors. -/
def oldJourneys : String → List Journey
  | "bookInsert" => [.registrationBooking, .registrationFold, .reclaim, .cleanup]
  | "bookTerminate" => [.terminationBooking, .terminationFold]
  | "bookOther" => [.unsupportedBooking]
  | "update" => [.update]
  | "fold" => [.registrationFold, .terminationFold]
  | "reject" => [.earlyRejection, .reclaim, .cleanup]
  | "withdraw" => [.liveWithdrawal]
  | _ => []

elab "#money_report" : command => do
  let env ← getEnv
  let .inductInfo journeyInfo ← getConstInfo ``Journey | throwError "missing journeys"
  let .inductInfo partyInfo ← getConstInfo ``Party | throwError "missing parties"
  let .inductInfo siteInfo ← getConstInfo ``Site | throwError "missing sites"
  let .inductInfo appInfo ← getConstInfo ``ApplicationAction | throwError "missing application actions"
  let .inductInfo oldInfo ← getConstInfo ``OpenDatumApplication.AppAction | throwError "missing accepted actions"
  let .inductInfo holdingInfo ← getConstInfo ``HoldingPaymentMutation | throwError "missing holding payment guards"
  IO.println (Json.mkObj [("family", toJson "money"),
    ("journeys", toJson (journeyInfo.ctors.map (·.getString!))),
    ("parties", toJson (partyInfo.ctors.map (·.getString!))),
    ("sites", toJson (siteInfo.ctors.map (·.getString!))),
    ("applicationConstructors", toJson (appInfo.ctors.map (·.getString!))),
    ("acceptedApplicationConstructors", toJson (oldInfo.ctors.map (·.getString!))),
    ("holdingPaymentGuards", toJson ((holdingInfo.ctors.map (·.getString!)).filter (· != "none")))]).compress
  for constructor in oldInfo.ctors do
    let classified := oldJourneys constructor.getString!
    if classified.isEmpty then throwError "unclassified accepted journey: {constructor}"
    IO.println (Json.mkObj [("family", toJson "money"), ("acceptedConstructor", toJson constructor.getString!),
      ("replacementJourneys", toJson classified)]).compress
  for (label, name) in [("oldAllocation", ``oldAllocation), ("oldUpdate", ``oldUpdate), ("oldReclaim", ``oldReclaim), ("oldRejection", ``oldRejection),
      ("acceptedGenesisWitness", ``Evidence.create_journey_positive)] do
    let info ← getConstInfo name
    let some value := info.value? | throwError "no compiled definition: {name}"
    IO.println (Json.mkObj [("family", toJson "money"), ("producer", toJson label),
      ("references", toJson (value.getUsedConstants.toList.map toString))]).compress
  for (name, info) in env.constants.toList do
    if name.getPrefix == `NoPin.ApplicationRequests.Money.Statements ||
        (name.getPrefix == `NoPin.ApplicationRequests.Money.Evidence &&
          match info with | .thmInfo _ => true | _ => false) then
      if name.getPrefix == `NoPin.ApplicationRequests.Money.Statements then
        liftTermElabM do
          let witnessName := Name.str `NoPin.ApplicationRequests.Money.Evidence (name.getString! ++ "_antecedent")
          let positiveName := Name.str `NoPin.ApplicationRequests.Money.Evidence (name.getString! ++ "_positive")
          let mutantName := Name.str `NoPin.ApplicationRequests.Money.Evidence (name.getString! ++ "_mutant")
          let (parameters, _, conclusion) ← forallMetaTelescope info.type
          let proof := parameters.back!
          let witness := Lean.mkConst witnessName
          unless ← isDefEq (← inferType proof) (← inferType witness) do
            throwError "incomplete money antecedent: {name}"
          proof.mvarId!.assign witness
          unless ← isDefEq conclusion (← inferType (Lean.mkConst positiveName)) do
            throwError "wrong money consequence: {name}"
          let mutant ← getConstInfo mutantName
          let .app (.const `Not _) implication := mutant.type | throwError "not a falsification"
          let repaired := implication.replace fun e =>
            if e.isAppOf ``Mutation.application || e.isAppOf ``Mutation.allocation then
              some (Lean.mkConst ``Mutation.none)
            else if e.isConstOf ``HoldingPaymentMutation.includeHolding then
              some (Lean.mkConst ``HoldingPaymentMutation.none) else none
          let expected ← mkArrow (← inferType witness) (← inferType (Lean.mkConst positiveName))
          unless ← isDefEq repaired expected do throwError "mutant not bound to complete money statement: {name}"
          IO.println (Json.mkObj [("family", toJson "money"), ("binding", toJson name.toString),
            ("witness", toJson witnessName.toString), ("positive", toJson positiveName.toString),
            ("mutant", toJson mutantName.toString)]).compress
      let refutationName := Name.str `NoPin.ApplicationRequests.Money.Refutation
        (name.getString! ++ "_refutation")
      let mut refutation := Json.null
      if env.contains refutationName then
        let exactMatch ← liftTermElabM <| NoPin.ApplicationRequests.ProofAudit.exactNegation name refutationName
        refutation := Json.mkObj [("name", toJson refutationName.toString),
          ("exact", toJson exactMatch),
          ("axioms", toJson ((← collectAxioms refutationName).toList.map toString))]
      IO.println (Json.mkObj [("family", toJson "money"), ("name", toJson name.toString),
        ("type", toJson (reprStr info.type)), ("doc", toJson ((← findDocString? env name).getD "")),
        ("axioms", toJson ((← collectAxioms name).toList.map toString)),
        ("refutation", refutation)]).compress

/-- Hypothesis under #741, not accepted law; computed amounts and ordinary definition replay. -/
def reportCorpus : IO Unit := do
  for selected in sites do
    let changed := sites.filter fun site => amountAt (.allocation selected) site 10 != amountAt .none site 10
    unless changed == [selected] do throw (IO.userError "allocation selector changes multiple sites")
    unless appMutation (.allocation selected) == .none do throw (IO.userError "allocation changed application")
  for journey in journeys do
    let q := Fixtures.input journey
    for party in parties do
      IO.println (Json.mkObj [("family", toJson "money"), ("journey", toJson journey),
        ("party", toJson party), ("old", toJson ((oldAllocation .none journey q.baseline).at party)),
        ("new", toJson ((newAllocation .none journey q).at party)),
        ("ruling", toJson (rulingFor journey party))]).compress
    for surface in [Surface.oldAllocation, .newAllocation, .applicationStep, .oldReclaim] do
      let scenario : Scenario := ⟨surface, journey, q, .none⟩
      let .ok result := runScenario scenario | throw (IO.userError "money oracle input incomplete")
      IO.println (Json.mkObj [("family", toJson "money"), ("scenario", toJson scenario),
        ("result", result)]).compress
  let q := Fixtures.input .reclaim
  let .registration _ data := q.registration | throw (IO.userError "reclaim witness is not a registration")
  unless data.controller != data.refundAddress do throw (IO.userError "reclaim authority witness is trivial")
  for (role, signer) in [("controller", data.controller), ("refundAddress", data.refundAddress)] do
    let input := { q with lifecycle := { q.lifecycle with
      observation := { q.lifecycle.observation with signers := [signer] } } }
    for surface in [Surface.applicationStep, .oldReclaim] do
      let scenario : Scenario := ⟨surface, .reclaim, input, .none⟩
      let .ok result := runScenario scenario | throw (IO.userError "authority control setup failed")
      IO.println (Json.mkObj [("family", toJson "money"), ("authorityRole", toJson role),
        ("signer", toJson signer), ("scenario", toJson scenario), ("result", result)]).compress
  let scenario : Scenario := ⟨.oldRejection, .earlyRejection, Fixtures.input .earlyRejection, .none⟩
  let .ok result := runScenario scenario | throw (IO.userError "old mismatch rejection setup failed")
  unless result == toJson true do throw (IO.userError "old mismatch rejection refused")
  IO.println (Json.mkObj [("family", toJson "money"), ("oldMismatchControl", toJson true),
    ("scenario", toJson scenario), ("result", result)]).compress

end NoPin.ApplicationRequests.Money.Report
