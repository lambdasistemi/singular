import Singular.Statements

open Lean Singular

namespace RegistrationOracle

-- The caller supplies the context. This example starts with an empty registry.
structure Scenario where
  config : Config
  key : Nat
  owner : Nat
  recipient : Nat
  lovelace : Nat
  deriving FromJson

def startingState (scenario : Scenario) : RegistryState :=
  { config := { scenario.config with root := rootOf [] }
  , trie := [], custody := [], held := [] }

theorem startingState_reachable (scenario : Scenario) :
    Reachable (startingState scenario) :=
  Reachable.initial scenario.config

def registrationRequest (scenario : Scenario) : Request :=
  let r : Request :=
    { edge := .insertActive, key := scenario.key
    , owner := scenario.owner, output := scenario.recipient }
  { r with approval := some (openApproval scenario.config r) }

-- Read delivery from the MODEL TRANSACTION, not from a hard-coded expectation.
def deliveryView (tx : Tx) : List (Option Nat × List (Asset × Int)) :=
  tx.outputs.filterMap fun output =>
    if output.role == .destination then some (output.address, output.assets)
    else none

def expectedDelivery (s : RegistryState) (r : Request) (lovelace : Nat) :
    Except String (List (Option Nat × List (Asset × Int))) :=
  (txOf s r lovelace).map deliveryView

-- This is the actual theorem dependency: the exported observation is proved
-- to have the promised value under the ORIGINAL theorem's hypotheses.
theorem expectedDelivery_agrees
    (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat)
    (h : Reachable s) (he : r.edge = .insertActive)
    (hap : r.approval = some ap) (hok : step s r = .ok t)
    (hfee : s.config.maxFee ≤ lovelace) :
    expectedDelivery s r lovelace =
      .ok [(some r.output, [((.active, r.key), 1)])] := by
  have transaction :=
    (Statements.insert_active_transaction_row s r t ap lovelace
      h he hap hok hfee).1
  rw [expectedDelivery, transaction]
  rfl

-- A small JSON transport. It preserves the computed address, identity and
-- quantity. Unexpected shapes and unmet fee premises fail; they never pass.
def answer (scenario : Scenario) : Except String Json := do
  let s := startingState scenario
  let r := registrationRequest scenario
  if scenario.lovelace < s.config.maxFee then
    throw "request does not cover the processing tip"
  let deliveries ← expectedDelivery s r scenario.lovelace
  match deliveries with
  | [(some address, [((kind, key), quantity)])] =>
      pure (Json.mkObj
        [ ("address", toJson address)
        , ("policy", toJson (kindPolicy s.config kind))
        , ("key", toJson key)
        , ("quantity", toJson quantity) ])
  | _ => throw "model did not produce one addressed, single-asset delivery"

-- Retirement starts from the result of the same model registration, never
-- from a hand-constructed active state.
structure RetirementScenario where
  registration : Scenario
  lovelace : Nat
  deriving FromJson

def retirementRequest (scenario : Scenario) (config : Config) : Request :=
  let r : Request :=
    { edge := .updateTerminal, key := scenario.key, owner := scenario.owner }
  { r with approval := some (openApproval config r) }

def witnessView (tx : Tx) : List (Asset × Int) :=
  tx.inputs.flatMap fun input =>
    if input.role == .witness then input.assets else []

def retirementView (s : RegistryState) (r : Request) (lovelace : Nat) :
    Except String (Nat × Nat × List (Asset × Int) × List (Asset × Int) × Leaf) := do
  let t ← step s r
  let tx ← txOf s r lovelace
  pure (kindCount s .active r.key, kindCount t.state .active r.key,
    tx.mint, witnessView tx, trieGet t.state.trie r.key)

theorem retirementView_agrees
    (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat)
    (h : Reachable s) (he : r.edge = .updateTerminal)
    (hap : r.approval = some ap) (hok : step s r = .ok t)
    (hfee : s.config.maxFee ≤ lovelace) :
    retirementView s r lovelace =
      .ok (1, 0, [((.active, r.key), -1)], [((.active, r.key), 1)], .known .terminal) := by
  obtain ⟨htx, hbefore, _, hafter, _, _, _, _, hleaf, _⟩ :=
    Statements.update_terminal_transaction_row s r t ap lovelace h he hap hok hfee
  simp only [retirementView, hok, htx]
  change (Except.ok (kindCount s .active r.key, kindCount t.state .active r.key,
    [((.active, r.key), -1)], [((.active, r.key), 1)], trieGet t.state.trie r.key) :
    Except String (Nat × Nat × List (Asset × Int) × List (Asset × Int) × Leaf)) = _
  rw [hbefore, hafter, hleaf]

def retirementAnswer (scenario : RetirementScenario) : Except String Json := do
  let origin := scenario.registration
  let initial := startingState origin
  if origin.lovelace < initial.config.maxFee then
    throw "registration does not cover the processing tip"
  let inserted ← step initial (registrationRequest origin)
  if scenario.lovelace < inserted.state.config.maxFee then
    throw "retirement does not cover the processing tip"
  let request := retirementRequest origin inserted.state.config
  let (before, after, mint, spent, leaf) ←
    retirementView inserted.state request scenario.lovelace
  let assetsJson := fun assets : List (Asset × Int) =>
    Json.arr ((assets.map fun ((kind, key), quantity) => Json.mkObj
      [("policy", toJson (kindPolicy inserted.state.config kind)),
       ("key", toJson key), ("quantity", toJson quantity)]).toArray)
  pure (Json.mkObj [("before", toJson before), ("after", toJson after),
    ("mint", assetsJson mint), ("spent", assetsJson spent), ("leaf", leafJson leaf)])

end RegistrationOracle

def main (args : List String) : IO Unit := do
  let line ← (← IO.getStdin).getLine
  let result := do
    let json ← Json.parse line
    match args with
    | [] =>
        let scenario : RegistrationOracle.Scenario ← fromJson? json
        RegistrationOracle.answer scenario
    | ["retirement"] =>
        let scenario : RegistrationOracle.RetirementScenario ← fromJson? json
        RegistrationOracle.retirementAnswer scenario
    | _ => throw "expected no argument or retirement"
  match result with
  | .ok json => (← IO.getStdout).putStrLn json.compress
  | .error reason => throw (IO.userError reason)
