import OpenDatumApplicationHeld.MoneyHoldingEvidence
import OpenDatumApplicationHeld.MoneyUpdateEvidence
import Lean
open Lean Elab Command Meta
open OpenDatumApplicationHeld.Money
elab "#money_certificates" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `OpenDatumApplicationHeld.Money.Statements
  for (name, info) in statements do
    liftTermElabM do
      let witnessName := Name.str `OpenDatumApplicationHeld.Money.Evidence (name.getString! ++ "_antecedent")
      let positiveName := Name.str `OpenDatumApplicationHeld.Money.Evidence (name.getString! ++ "_positive")
      let mutantName := Name.str `OpenDatumApplicationHeld.Money.Evidence (name.getString! ++ "_mutant")
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
    let mut certificates := #[]
    for suffix in ["_antecedent", "_positive", "_mutant"] do
      let certificate := Name.str `OpenDatumApplicationHeld.Money.Evidence (name.getString! ++ suffix)
      certificates := certificates.push (Json.mkObj [("name", toJson certificate.toString),
        ("axioms", toJson ((← collectAxioms certificate).toList.map toString))])
    IO.println (Json.mkObj [("moneyEvidence", toJson name.toString),
      ("certificates", toJson certificates)]).compress
#money_certificates
