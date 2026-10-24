import NoPin.ApplicationRequests.MoneyReport
import NoPin.ApplicationRequests.ProofAudit

/-! Hypothetical money evidence: unchanged transitive kernel definitions. -/
namespace NoPin.ApplicationRequests.MoneyProofAudit
open Lean Elab Command

theorem neighbouring_negation : ¬ False := by simp

elab "#money_proof_closure" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `NoPin.ApplicationRequests.Money.Statements
  let roots := statements.foldl (fun roots (_, info) => roots ++ info.type.getUsedConstants) #[]
  IO.println (Json.mkObj [("moneyProofClosure", toJson (ProofAudit.closure env roots))]).compress
  let target := `NoPin.ApplicationRequests.Money.Statements.registration_fold_journey
  let exactProof := `NoPin.ApplicationRequests.Money.Refutation.registration_fold_journey_refutation
  let exactMatch ← liftTermElabM <| ProofAudit.exactNegation target exactProof
  let neighbouring ← liftTermElabM <| ProofAudit.exactNegation target
    `NoPin.ApplicationRequests.MoneyProofAudit.neighbouring_negation
  unless exactMatch && !neighbouring do throwError "money exact-negation control failed"
  IO.println (Json.mkObj [("moneyRefutationControl", toJson exactMatch),
    ("neighbouringRejected", toJson (!neighbouring))]).compress

end NoPin.ApplicationRequests.MoneyProofAudit
