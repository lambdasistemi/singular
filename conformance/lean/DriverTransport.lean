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
setup trace rather than a second adapter.
-/

open Lean Singular Singular.Driver

namespace DriverTransport

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
  let base : Request :=
    { edge, key, owner, refundAddress, deposit, output, approval := none, claimed := [] }
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

/-- One evaluation: a starting state, a lawful setup trace, and the request. -/
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
  pure
    { id, theoremName, statementSha256
    , kind := "witness", mutates := none
    , requiresReachableState := !setup.isEmpty
    , start, setup, request, lovelace }

/-- Evaluate, and answer with the row the driver produces. -/
def answer (j : Json) : Except String Json := do
  let scenario ← toScenario j
  pure (scenarioJson scenario)

end DriverTransport

def main : IO Unit := do
  let input ← (← IO.getStdin).readToEnd
  match Json.parse input with
  | .error reason => throw (IO.userError s!"invalid evaluator input: {reason}")
  | .ok json =>
    match DriverTransport.answer json with
    | .ok result => (← IO.getStdout).putStrLn result.compress
    | .error reason => throw (IO.userError reason)
