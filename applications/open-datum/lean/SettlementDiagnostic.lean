import OpenDatumApplication.Driver

/-! Model-only executable observations at the changed custody/value boundary.
Every prerequisite and outcome comes from appStep. This is not a ledger or
validator receipt; the malformed duplicate inventory is labelled separately. -/
open Lean Singular OpenDatumApplication OpenDatumApplication.Driver

def main : IO UInt32 := do
  let actions := lifecycleActions 0
  let results := runActionsWith Law.standard (genesis app0 cfg0 app0.registry) actions
  let pending := reachWorld (bookedTerminationActions 0)
  let finalWorld := reachWorld actions
  let controls := [
    ("all lifecycle prerequisites accepted", results.all (·.isOk)),
    ("all reached states observe independent consistency", results.all (fun r => r.toOption.any appConsistentB)),
    ("actual output consumed at booking", pending.outputs.isEmpty),
    ("held includes surplus", pending.economic.terminations.any (fun b => b.request.contents.lovelace == 4000000)),
    ("no ordinary addition required", (actions.any fun a => match a with | .bookTerminate _ _ added _ => added == 0 | _ => false)),
    ("treasury donation below former protected floor", finalWorld.economic.treasury - pending.economic.treasury == 2000000),
    ("terminal with no pending or live custody", trieGet finalWorld.registry.trie 5 == .known .terminal && finalWorld.outputs.isEmpty && finalWorld.economic.terminations.isEmpty),
    ("malformed duplicated boundary excluded", !appConsistentB duplicatedWorld) ]
  IO.println (Json.mkObj [("lifecycle", runScenario (scenario "held-minus-tip" "witness" [] actions)),
    ("pending", worldToJson pending), ("final", worldToJson finalWorld),
    ("controls", toJson (controls.map fun (name, holds) => Json.mkObj [("control", toJson name), ("holds", toJson holds)]))]).pretty
  pure (if controls.all Prod.snd then 0 else 1)
