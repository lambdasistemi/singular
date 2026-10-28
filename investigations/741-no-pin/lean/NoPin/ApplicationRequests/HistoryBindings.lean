import Lean

/-! Compile-time instance binding. A certificate must inhabit the entire
specialized antecedent, and its claimed consequence must be definitionally the
general statement's consequence. Names and counts alone do not bind evidence. -/
open Lean Elab Command Term Meta in
elab "#bind_history_instance " statement:ident " [" arguments:term,* "] "
    witness:ident claim:ident : command => liftTermElabM do
  let mut applied ← elabTerm statement none
  for argument in arguments.getElems do
    let .forallE _ domain _ _ ← whnf (← inferType applied)
      | throwError "too many statement arguments"
    applied := mkApp applied (← elabTermEnsuringType argument domain)
  synthesizeSyntheticMVarsNoPostponing
  applied ← instantiateMVars applied
  let .forallE _ premise conclusion _ ← whnf (← inferType applied)
    | throwError "missing complete statement antecedent"
  let certificate ← elabTerm witness none
  unless ← isDefEq (← inferType certificate) premise do
    throwError "certificate does not inhabit complete antecedent"
  let consequence ← elabTerm claim (some (mkSort .zero))
  synthesizeSyntheticMVarsNoPostponing
  unless ← isDefEq (conclusion.instantiate1 certificate) consequence do
    throwError "certificate claims another consequence"
  let axioms ← collectAxioms certificate.getAppFn.constName!
  unless axioms.all (fun a => a == `propext || a == `Classical.choice || a == `Quot.sound) do
    throwError "unproved history certificate"
  IO.println (Json.mkObj [
    ("family", toJson "history"), ("binding", toJson applied.getAppFn.constName!.toString),
    ("witness", toJson certificate.getAppFn.constName!.toString),
    ("claim", toJson consequence.getAppFn.constName!.toString),
    ("specialization", toJson (reprStr (← inferType applied))),
    ("axioms", toJson (axioms.toList.map toString))]).compress
