import SingularApplicationHeld.Statements
import Lean

/-! The application-held Singular model beside the current one, to be removed
with it in #743. Compiled statement and root-dependency records use reprStr,
the same printer as the investigation. -/

#print axioms SingularApplicationHeld.Statements.active_role_never_state
#print axioms SingularApplicationHeld.Statements.batch_effects
#print axioms SingularApplicationHeld.Statements.batch_inversion
#print axioms SingularApplicationHeld.Statements.fold_minted_outputs
#print axioms SingularApplicationHeld.Statements.fold_untouched_keys
#print axioms SingularApplicationHeld.Statements.genesis_inversion
#print axioms SingularApplicationHeld.Statements.minted_active_never_state
#print axioms SingularApplicationHeld.Statements.public_fold_constructed
#print axioms SingularApplicationHeld.Statements.public_fold_effects
#print axioms SingularApplicationHeld.Statements.publicFold_inversion
#print axioms SingularApplicationHeld.Statements.recognition_inversion
#print axioms SingularApplicationHeld.Statements.registration_effects
#print axioms SingularApplicationHeld.Statements.registration_inversion
#print axioms SingularApplicationHeld.Statements.registration_separate_holdings
#print axioms SingularApplicationHeld.Statements.termination_effects
#print axioms SingularApplicationHeld.Statements.termination_inversion

open Lean Elab Command

elab "#application_held_types" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) =>
    name.getPrefix == `SingularApplicationHeld.Statements
  let mut pending : List Name := []
  for (name, info) in statements do
    IO.println (Json.mkObj [("statement", toJson name.toString),
      ("type", toJson (reprStr info.type))]).compress
    pending := info.type.getUsedConstants.toList ++ pending
  let mut seen : NameSet := {}
  while !pending.isEmpty do
    let name := pending.head!
    pending := pending.tail!
    if seen.contains name then continue
    seen := seen.insert name
    let some info := env.find? name | continue
    let value := info.value? (allowOpaque := true)
    if name.toString.startsWith "Singular." then
      IO.println (Json.mkObj [("root", toJson name.toString),
        ("type", toJson (reprStr info.type)),
        ("value", toJson (value.map reprStr))]).compress
    pending := info.type.getUsedConstants.toList ++
      (value.map Expr.getUsedConstants |>.getD #[]).toList ++ pending

#application_held_types
