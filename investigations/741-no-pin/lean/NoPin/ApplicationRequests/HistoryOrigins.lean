import NoPin.ApplicationRequests.History
import Lean

/-! Hypothetical #741 constructor inversions. The complete existential premise
of each source constructor is derived from its compiled type. No handwritten
field inventory can omit a newly added history premise. -/
namespace NoPin.ApplicationRequests.HistoryOrigins
open Lean Elab Command Term Meta

elab "#derive_history_origins" : command => liftTermElabM do
  let .inductInfo source ← getConstInfo ``CandidateReachable | throwError "history is not inductive"
  forallTelescope (← inferType (mkConst ``CandidateReachable)) fun parameters _ => do
    unless parameters.size == 5 do throwError "unexpected history parameters"
    let fixed := parameters.extract 0 4
    let world := parameters[4]!
    for constructor in source.ctors do
      let constructorType ← inferType (mkAppN (mkConst constructor) fixed)
      let origin ← forallTelescope constructorType fun fields result => do
        let mut body ← mkEq result.getAppArgs.back! world
        for field in fields.reverse do
          let predicate ← mkLambdaFVars #[field] body
          body ← mkAppM ``Exists #[predicate]
        pure body
      let value ← mkLambdaFVars parameters origin
      addDecl (.defnDecl {
        name := Name.str `NoPin.ApplicationRequests.HistoryOrigins constructor.getString!
        levelParams := [], type := (← inferType value), value,
        hints := .abbrev, safety := .safe })

#derive_history_origins

end NoPin.ApplicationRequests.HistoryOrigins
