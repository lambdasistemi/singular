import Singular.Model

/-! Declared operations, observations and boundary identity. -/

namespace Singular.Driver
open Lean

/-! ## The declared surface -/

/-- An edge's name is the model's own `ToJson Edge` spelling, so the driver
cannot acquire a second vocabulary for the seven edges. -/
def edgeName (e : Edge) : String :=
  match toJson e with
  | .str s => s
  | j => j.compress

/-- An operation's name: a fold is named by its edge, so every fold keeps the
edge's own spelling; a reject and a retract by their constructor names. -/
def exitName : Exit → String
  | .fold e => edgeName e
  | .reject => "reject"
  | .retract => "retract"

/-- The nine exits are the declared operations: a fold of each of the seven
edges, a reject and a retract. The extent is the model's inductives, listed once
here because Lean has no enumeration of them. -/
def declaredExits : List Exit :=
  ([Edge.insertAbsent, .insertActive, .updateActive, .updateTerminal,
    .deleteAbsent, .deleteActive, .witnessTerminal].map .fold) ++ [.reject, .retract]

def declaredOperations : List String := declaredExits.map exitName

/-- The declared boundary observations. Every accepted scenario reports all of
them; a row reporting a subset is a per-theorem projection and is rejected by
the checker rather than counted as conformance. -/
def declaredObservations : List String :=
  ["config", "held", "leaf", "mint", "paid", "root", "state", "tx"]

/-- Fields the model has no vocabulary for, named here so they are a stated
limit instead of a silent omission. The registry root is the leading case: the
model's `rootOf` is FNV-1a over the sorted (key, leaf byte) list — its own
commitment function — and is NOT the concrete trie hash a chain would carry.

`outputMinimumAda` is the second of that kind: a ledger requires every output to
carry a minimum, and this model says nothing about it. A transaction output's
`lovelace` here is therefore a floor, not an amount: what the exit owes the
recipient the output pays — the cage output's deposit, the destination output's
deposit for a fold delivering a token, an owner output's payment — and a logical
zero on an output that pays no recipient. It is named so that a consumer compares
that field as a floor, observed at least the model's, and never reconstructs the
ledger minimum as an equality the model never claimed. -/
def declaredUnobservable : List String :=
  ["concreteTrieHash", "outputMinimumAda", "registryAddress",
   "scriptExecutionUnits", "transactionId", "utxoReference"]

/-- The declared judgements: questions the driver answers about a transaction a
caller observed, beside the boundary it reports, in the order it asks them.
`spend` judges what the observed inputs spend, by `Singular.spendRefusal`;
`settle` whether the observed outputs pay what the scenario's exit owes, by
`Singular.settle`. -/
def declaredJudgements : List String := ["spend", "settle"]

/-- What a batch answer reports: the single-request boundary without its
transaction, since the model builds none for a batch, and with `leaf` read at
every distinct request key. -/
def batchObservations : List String :=
  ["config", "held", "leaf", "mint", "paid", "root", "state"]

/-- The declared batch questions, each named with its own observation extent:
`foldBatch`, answered by `Singular.foldBatch`, and `rejectBatch`, a batch of
rejects judged by `Singular.settle` over their concatenated obligations. -/
def declaredBatchQuestions : List (String × List String) :=
  [("foldBatch", batchObservations), ("rejectBatch", batchObservations)]

/-- D01: the surface identity a scenario is executed against. -/
structure SurfaceIdentity where
  declaration : String
  protocolVersion : Nat
  operations : List String
  observations : List String
  unobservable : List String
  judgements : List String
  batchQuestions : List (String × List String)

def surface : SurfaceIdentity :=
  { declaration := "Singular.Driver.runSurface"
  , protocolVersion := 8
  , operations := declaredOperations
  , observations := declaredObservations
  , unobservable := declaredUnobservable
  , judgements := declaredJudgements
  , batchQuestions := declaredBatchQuestions }

def surfaceJson (s : SurfaceIdentity) (definitionDigest : String) : Json :=
  Json.mkObj
    [ ("declaration", toJson s.declaration)
    , ("definitionDigest", toJson definitionDigest)
    , ("protocolVersion", toJson s.protocolVersion)
    , ("operations", toJson s.operations)
    , ("observations", toJson s.observations)
    , ("unobservable", toJson s.unobservable)
    , ("judgements", toJson s.judgements)
    , ("batchQuestions", Json.mkObj (s.batchQuestions.map fun q => (q.1, toJson q.2))) ]

end Singular.Driver
