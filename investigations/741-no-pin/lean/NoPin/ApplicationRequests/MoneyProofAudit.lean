import NoPin.ApplicationRequests.MoneyReport
import NoPin.ApplicationRequests.ProofAudit

/-! Hypothetical money evidence: unchanged transitive kernel definitions. -/
namespace NoPin.ApplicationRequests.MoneyProofAudit
open Lean Elab Command

theorem neighbouring_negation : ¬ False := by simp

elab "#money_proof_closure" : command => do
  let env ← getEnv
  let .ok ledger := Json.parse (← IO.FS.readFile "investigations/741-no-pin/money-statements.json")
    | throwError "invalid money ledger"
  let .ok rows := ledger.getObjValAs? (Array Json) "statements" | throwError "missing money rows"
  let corrected := `NoPin.ApplicationRequests.Money.Statements.registration_fold_journey_holding_separated
  let mut roots := #[]
  let mut names : Array Name := #[]
  for row in rows do
    let .ok name := row.getObjValAs? String "theorem" | throwError "missing money theorem"
    if name.toName == corrected then continue
    let info ← getConstInfo name.toName
    names := names.push name.toName
    roots := roots ++ info.type.getUsedConstants
  unless names.size == 12 && names.toList.eraseDups.length == 12 do
    throwError "expected twelve distinct ledger-named money roots"
  IO.println (Json.mkObj [("moneyProofClosure", toJson (ProofAudit.closure env roots))]).compress
  let correctedInfo ← getConstInfo corrected
  IO.println (Json.mkObj [("moneyHoldingProofClosure",
    toJson (ProofAudit.closure env correctedInfo.type.getUsedConstants))]).compress
  IO.println (Json.mkObj [("moneyProofRoots", toJson (names.map toString)),
    ("moneyHoldingProofRoot", toJson corrected.toString)]).compress
  let target := `NoPin.ApplicationRequests.Money.Statements.registration_fold_journey
  let exactProof := `NoPin.ApplicationRequests.Money.Refutation.registration_fold_journey_refutation
  let exactMatch ← liftTermElabM <| ProofAudit.exactNegation target exactProof
  let neighbouring ← liftTermElabM <| ProofAudit.exactNegation target
    `NoPin.ApplicationRequests.MoneyProofAudit.neighbouring_negation
  unless exactMatch && !neighbouring do throwError "money exact-negation control failed"
  IO.println (Json.mkObj [("moneyRefutationControl", toJson exactMatch),
    ("neighbouringRejected", toJson (!neighbouring))]).compress

end NoPin.ApplicationRequests.MoneyProofAudit
