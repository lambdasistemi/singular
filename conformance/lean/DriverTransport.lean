import Singular.Driver

/-! # The generic model evaluator, over a supplied abstract context

One description, two interpreters. This is the second one: it reads the
registration description and the abstract context the caller established, runs
the model's own law through `Singular.Driver.runSurface`, and answers with the
complete declared boundary.

It is transport and nothing else. Every value it returns is produced by the
driver the model already ships; there is no projection here, no restatement of
a transition, and no Cardano byte. The context is supplied from outside — the
caller's real fee and timing pins arrive as ordinary model fields — so the same
description can be evaluated against whatever registry the caller established
rather than against one fixed configuration.

The entry point is deliberately edge-agnostic: it takes a starting state, a
setup trace and a request, so a connected retirement is the same call with a
setup trace rather than a second adapter. A retraction also carries the witness
its admission reads, so the model admits it before it pays it.
-/

open Lean Singular Singular.Driver

namespace DriverTransport

/-- A natural field a caller may leave out, read as 0 when absent or null. -/
def optionalNat (j : Json) (name : String) : Except String Nat :=
  match j.getObjVal? name with
  | .error _ => pure 0
  | .ok Json.null => pure 0
  | .ok v => fromJson? v

/-- The model's own decoders do not cover `Request`, which carries defaults. -/
def toRequest (j : Json) : Except String Request := do
  let edge ← (j.getObjVal? "edge") >>= fromJson?
  let key ← (j.getObjVal? "key") >>= fromJson?
  let owner ← (j.getObjVal? "owner") >>= fromJson?
  let refundAddress ← (j.getObjVal? "refundAddress") >>= fromJson?
  let deposit ← (j.getObjVal? "deposit") >>= fromJson?
  let output ← (j.getObjVal? "output") >>= fromJson?
  -- "canonical" asks for the approval this very request carries under the
  -- registry's pinned application policy. Its asset name is the model's own
  -- `approvalAssetName` of the request's tuple, so the caller never has to
  -- compute a model hash and never gets to invent one.
  -- The tip and the output reference the request sits at are optional: a caller
  -- that names neither describes a request holding its deposit alone, at reference 0.
  let tip ← optionalNat j "tip"
  let reference ← optionalNat j "reference"
  let base : Request :=
    { edge, key, owner, refundAddress, deposit, output, approval := none, claimed := [], tip
    , reference }
  let approval ←
    match j.getObjVal? "approval" with
    | .error _ => pure none
    | .ok Json.null => pure none
    | .ok (Json.str "canonical") => do
      let policy ← (j.getObjVal? "applicationPolicy") >>= fromJson?
      let destination := requestDestination base
      pure (some
        { policy, edge, key, owner, destination
        , assetName := approvalAssetName edge key owner destination
        , signatures := [] })
    | .ok a => do let v ← fromJson? a; pure (some v)
  pure { base with approval }

/-- A leaf as the corpus spells it, so a caller can describe a starting trie. -/
def toLeaf (j : Json) : Except String Leaf :=
  match j with
  | Json.null => .ok .unknown
  | Json.str "absent" => .ok (.known .absent)
  | Json.str "active" => .ok (.known .active)
  | Json.str "terminal" => .ok (.known .terminal)
  | _ => .error "unknown leaf spelling"

/-- The starting state: the caller's configuration and whatever it already holds. -/
def toState (j : Json) : Except String RegistryState := do
  let config ← (j.getObjVal? "config") >>= fromJson?
  let trie ←
    match j.getObjVal? "trie" with
    | .error _ => pure []
    | .ok (Json.arr entries) =>
      entries.toList.mapM fun entry => do
        let key ← (entry.getObjVal? "key") >>= fromJson?
        let leaf ← (entry.getObjVal? "leaf") >>= toLeaf
        pure (key, leaf)
    | .ok _ => .error "trie is not an array"
  let custody ←
    match j.getObjVal? "custody" with
    | .error _ => pure []
    | .ok c => fromJson? c
  let held ←
    match j.getObjVal? "held" with
    | .error _ => pure []
    | .ok h => fromJson? h
  pure { config, trie, custody, held }

/-- The exit a caller names by its operation name, one of the driver's declared
exits; a caller that names none asks for the fold of the request's own edge. -/
def toExit (j : Json) (request : Request) : Except String Exit :=
  match j.getObjVal? "exit" with
  | .error _ => pure (.fold request.edge)
  | .ok named => do
    let name : String ← fromJson? named
    match declaredExits.find? (exitName · == name) with
    | some exit => pure exit
    | none => throw s!"no declared exit is named {name}"

/-- What a retraction's admission reads beyond the request, as the caller
established it: the request's submission time, the transaction's validity bounds
and its signatories (`Singular.RetractWitness`). A retraction question must carry
it, and no other question may: every other exit's admission reads none. -/
def toWitness (j : Json) (exit : Exit) : Except String (Option RetractWitness) :=
  match j.getObjVal? "witness", exit with
  | .error _, .retract => throw "a retraction question carries no witness"
  | .error _, _ => pure none
  | .ok w, .retract => some <$> fromJson? w
  | .ok _, _ => throw "only a retraction question carries a witness"

/-- One evaluation: a starting state, a lawful setup trace, and the request, taken
by the exit the caller names; a retraction under the witness it carries. -/
def toScenario (j : Json) : Except String Scenario := do
  let start ← (j.getObjVal? "start") >>= toState
  let request ← (j.getObjVal? "request") >>= toRequest
  let lovelace ← (j.getObjVal? "lovelace") >>= fromJson?
  let setup ←
    match j.getObjVal? "setup" with
    | .error _ => pure []
    | .ok (Json.arr steps) => steps.toList.mapM toRequest
    | .ok _ => .error "setup is not an array"
  let theoremName ← (j.getObjVal? "theorem") >>= fromJson?
  let statementSha256 ← (j.getObjVal? "statementSha256") >>= fromJson?
  let id ← (j.getObjVal? "id") >>= fromJson?
  let exit ← toExit j request
  let witness ← toWitness j exit
  pure
    { id, theoremName, statementSha256
    , kind := "witness", mutates := none
    , requiresReachableState := !setup.isEmpty
    , start, setup, exit, request, lovelace, witness }

/-- One input a caller observed, as the driver's judgement reads it: the state
tokens it holds. `spend` reads nothing else of an input, so nothing else is taken
from the caller; the other fields are the model's zeros. -/
def toInput (j : Json) : Except String TxInput := do
  let stateTokens ← (j.getObjVal? "stateToken") >>= fromJson?
  pure { role := .request, datum := .none, stateTokens, approvals := 0, lovelace := 0 }

/-- One output a caller observed, as the driver's judgement reads it: its role,
the identity of its address, its lovelace, the form of its datum, and the identity
of the output reference its inline datum presents, if any. The judgement, `settle`, reads
nothing else of an output, so nothing else is taken from the caller. -/
def toOutput (j : Json) : Except String TxOutput := do
  let role ← match (← (j.getObjVal? "role") >>= fromJson? : String) with
    | "destination" => pure TxRole.destination
    | "cage" => pure .cage
    | "owner" => pure .owner
    | other => throw s!"no judged output has the role {other}"
  let address ← (j.getObjVal? "address") >>= fromJson?
  let lovelace ← (j.getObjVal? "lovelace") >>= fromJson?
  let datum ← match (← (j.getObjVal? "datum") >>= fromJson? : String) with
    | "inline" => pure DatumForm.inline
    | "hashed" => pure .hashed
    | "none" => pure .none
    | other => throw s!"no judged output presents the datum form {other}"
  let reference ← match j.getObjVal? "reference" with
    | .error _ => pure none
    | .ok Json.null => pure none
    | .ok r => some <$> fromJson? r
  pure { role, datum, address := some address, stateTokens := 0, config := none
       , commitment := none, assets := [], lovelace, reference }

/-- Evaluate, and answer with the row the driver produces. A question carrying the
inputs and outputs of a transaction the caller observed is also answered with the
driver's judgement of them, under `settle`: the reason `spend` or `settle` gives,
or `null` when the transaction spends what the exit may and pays what it owes. -/
def answer (j : Json) : Except String Json := do
  let scenario ← toScenario j
  let row := scenarioJson scenario
  match j.getObjVal? "outputs" with
  | .error _ => pure row
  | .ok (Json.arr observed) => do
    let outputs ← observed.toList.mapM toOutput
    let inputs ← match j.getObjVal? "inputs" with
      | .error _ => throw "a judged transaction names no inputs"
      | .ok (Json.arr spent) => spent.toList.mapM toInput
      | .ok _ => throw "inputs is not an array"
    let judgement := match judgeSurface scenario inputs outputs with
      | none => Json.null
      | some why => toJson why
    pure (row.setObjVal! "settle" judgement)
  | .ok _ => throw "outputs is not an array"

end DriverTransport

def main : IO Unit := do
  let input ← (← IO.getStdin).readToEnd
  match Json.parse input with
  | .error reason => throw (IO.userError s!"invalid evaluator input: {reason}")
  | .ok json =>
    match DriverTransport.answer json with
    | .ok result => (← IO.getStdout).putStrLn result.compress
    | .error reason => throw (IO.userError reason)
