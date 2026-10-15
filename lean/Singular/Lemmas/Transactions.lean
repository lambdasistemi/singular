import Singular.Model

/-! The two transaction expansions used by the long row proofs. -/

namespace Singular

/-! ### The fold's transaction -/

/-- A fold the step refuses builds no transaction, for the step's reason. -/
theorem txOf_of_step_error (s : RegistryState) (r : Request) (lovelace : Nat) (why : String)
    (h : step s r = .error why) : txOf s r lovelace = .error why := by
  simp [txOf, txOfExit, exitStep, h]

/-- The transaction of an admitted fold, spelled from its step: every field is the
step's answer or a definition applied to the request, and the payments the fold
exit owes are carried by the outputs that pay them and listed first among its
refunds. -/
theorem txOf_of_step_ok (s : RegistryState) (r : Request) (lovelace : Nat) (t : Result)
    (h : step s r = .ok t) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := registryDatumForm
                , stateTokens := registryStateTokens, approvals := 0, lovelace := 0 }
              , { role := .request, datum := registryDatumForm
                , stateTokens := 0, approvals := approvalsIn r, lovelace := lovelace } ]
              ++ txBurnInputs s t r
          , outputs := txStateOutput t
              :: (txDestinationOutputs t r).map
                  (fun o => { o with
                    lovelace := owedTo (.destination (requestDestination r) r.datum)
                      (obligations (.fold r.edge) r) })
              ++ txCageOutputs t r
              ++ ownerOutputs .none (r.approval.map (·.assetName)) (obligations (.fold r.edge) r)
          , mint := t.mint
          , signers := requiredSigners r
          , refunds := (obligations (.fold r.edge) r).map paymentPaid ++ t.paid } := by
  simp [txOf, txOfExit, exitStep, h, txStateOutput, txBurnInputs, txCageOutputs,
    routedPayment, mintRoutedTo, txDestinationOutputs]


end Singular
