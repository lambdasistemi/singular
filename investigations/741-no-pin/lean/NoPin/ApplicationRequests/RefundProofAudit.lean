import NoPin.ApplicationRequests.RefundLifecycleStatements
import NoPin.ApplicationRequests.ProofAudit

/-! Hypothetical #741 evidence: the refund statement definition closure. -/
namespace NoPin.ApplicationRequests.RefundProofAudit
open Lean Elab Command

elab "#refund_proof_closure" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `NoPin.ApplicationRequests.RefundLifecycle.Statements
  let roots := statements.foldl (fun roots (_, info) => roots ++ info.type.getUsedConstants) #[]
  IO.println (Json.mkObj [("refundProofClosure",
    toJson (ProofAudit.closure env roots))]).compress

end NoPin.ApplicationRequests.RefundProofAudit
