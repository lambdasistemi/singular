import Singular.Model

/-! # The generic model driver

One driver over the model's own law, in place of one adapter per theorem.

Given a scenario it reaches the scenario's starting state by *running* the law
over a setup trace, checks the law premise on the state it arrived at, takes the
scenario's exit on the request through `Singular.admittedExitStep` — a
retraction's admission, then `Singular.exitStep` — and reports the whole
declared boundary of what the law actually did. Nothing here restates the model: every observation
delegates to a model definition or to the transaction the model builds.

Three outcomes, kept apart on purpose. `accepted` is a transition the law
admitted, and it is the only outcome that carries observations. `refused` is the
law saying no, in the model's own refusal vocabulary. `unsupported` is the
driver saying it could not reach the case — a setup that would not run, a
premise that does not hold, a transaction the model cannot build. A driver that
collapsed the third into the second would let a broken runner earn refusal
evidence, which is the defect these classes exist to make visible.

The serialization in the first section was written for the corpus producer in
`lean/Main.lean` and is promoted here so that the driver and the corpus speak
the same bytes; `Main` consumes it from this module rather than keeping a
second copy. -/

namespace Singular
namespace Driver

open Lean

/-! ## Serialization, promoted from the corpus producer -/

/-- One keyed asset, spelled with the on-chain identity the model pins: the
kind's policy and the asset name, which is the key. -/
def assetJson (c : Config) (p : Asset × Int) : Json :=
  Json.mkObj
    [ ("kind", toJson p.1.1), ("key", toJson p.1.2)
    , ("policy", toJson (kindPolicy c p.1.1))
    , ("assetName", toJson (tokenAssetName p.1.1 p.1.2))
    , ("quantity", toJson p.2) ]

def assetsJson (c : Config) (ds : List (Asset × Int)) : Json :=
  Json.arr ((ds.map (assetJson c)).toArray)

def txRoleName : TxRole → String
  | .state => "state" | .request => "request"
  | .destination => "destination" | .cage => "cage"
  | .witness => "witness" | .owner => "owner"

def txInputJson (c : Config) (i : TxInput) : Json :=
  Json.mkObj
    [ ("role", toJson (txRoleName i.role))
    , ("datum", toJson (datumFormName i.datum))
    , ("stateToken", toJson i.stateTokens)
    , ("approvalQuantity", toJson i.approvals)
    , ("lovelace", toJson i.lovelace)
    , ("assets", assetsJson c i.assets) ]

def txOutputJson (c : Config) (o : TxOutput) : Json :=
  Json.mkObj
    [ ("role", toJson (txRoleName o.role))
    , ("datum", toJson (datumFormName o.datum))
    , ("address", match o.address with | none => Json.null | some a => toJson a)
    , ("stateToken", toJson o.stateTokens)
    , ("inlineConfig", match o.config with | none => Json.null | some cfg => toJson cfg)
    , ("commitment", match o.commitment with | none => Json.null | some x => toJson x)
    , ("assets", assetsJson c o.assets)
    , ("custodyDatum", toJson o.custodyDatum)
    , ("lovelace", toJson o.lovelace)
    , ("reference", match o.reference with | none => Json.null | some x => toJson x) ]

/-- The built transaction, serialized. Every field comes from the `Tx` the model
constructed; nothing here is assembled beside it. -/
def txJson (c : Config) (tx : Tx) : Json :=
  Json.mkObj
    [ ("inputs", Json.arr ((tx.inputs.map (txInputJson c)).toArray))
    , ("outputs", Json.arr ((tx.outputs.map (txOutputJson c)).toArray))
    , ("mint", assetsJson c tx.mint)
    , ("signers", toJson tx.signers)
    , ("refunds", Json.arr ((tx.refunds.map fun p =>
        Json.mkObj [("address", toJson p.1), ("value", toJson p.2)]).toArray)) ]

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
  ["config", "custody", "held", "leaf", "mint", "paid", "root", "state", "tx"]

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
  ["config", "custody", "held", "leaf", "mint", "paid", "root", "state"]

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
  , protocolVersion := 5
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

/-! ## The law premise -/

/-- The keys a state can possibly violate `Consistent` at: a key bound nowhere
has no active token, no custody entry and reads `unknown`, so every conjunct
holds of it trivially. Quantifying over this discovered extent is what makes the
premise decidable without weakening it. -/
def stateKeys (s : RegistryState) : List Key :=
  (s.trie.map (·.1) ++ s.custody.map (·.key) ++ s.held.map (·.key)).foldl
    (fun acc k => if acc.contains k then acc else acc ++ [k]) []

/-- The decidable finite characterization of `Singular.Consistent`: the root
commits to the map, the active and absent supply laws hold as biconditionals
with at most one token each, and every terminal attestation and custody entry is
about a leaf that can still be what it says.

This is a Bool over a finite key extent, not the `Prop` itself; what it
establishes is that no key the state actually mentions violates a conjunct. -/
def consistentB (s : RegistryState) : Bool :=
  (s.config.root.toList == (rootOf s.trie).toList)
  && (stateKeys s).all (fun k =>
       ((kindCount s .active k == 1) == (trieGet s.trie k == .known .active))
       && decide (kindCount s .active k ≤ 1)
       && ((custodyCount s k == 1) == (trieGet s.trie k == .known .absent))
       && decide (custodyCount s k ≤ 1))
  && s.held.all (fun h => !(h.kind == .terminal) || trieGet s.trie h.key == .known .terminal)
  && s.custody.all (fun c => trieGet s.trie c.key == .known .absent)

def premiseDeclaration : String := "Singular.Driver.consistentB"

/-! ## Scenarios and results -/

/-- D02: one scenario. `setup` is a trace of requests that must each be accepted
to reach the starting state; `start` is where that trace begins; `exit` is the way
the scenario's request leaves the queue, and names its operation. A scenario that
needs a non-initial state declares `requiresReachableState` and must supply the
trace that produces it, so a constructed final state cannot stand in for one.
`witness` is what a retraction's admission reads beyond the request
(`Singular.RetractWitness`); only a retraction reads it (`admissionWitness`). -/
structure Scenario where
  id : String
  theoremName : String
  statementSha256 : String
  kind : String
  mutates : Option String
  requiresReachableState : Bool
  start : RegistryState
  setup : List Request
  exit : Exit
  request : Request
  lovelace : Nat
  witness : Option RetractWitness := none
  foldWitness : Option FoldWitness := none

/-- One executed setup step and the state it produced. -/
structure SetupStep where
  request : Request
  accepted : Bool
  reason : Option String
  state : RegistryState

inductive Outcome where
  | accepted | refused | unsupported
  deriving BEq

def outcomeName : Outcome → String
  | .accepted => "accepted"
  | .refused => "refused"
  | .unsupported => "unsupported"

/-- D03: what the driver saw. Observations exist only for an accepted
transition; a refusal and an execution failure both observe nothing, and they
are told apart by their outcome class rather than by their reason text. -/
structure DriverResult where
  outcome : Outcome
  reason : Option String
  premiseChecked : Bool
  observations : Option Json

/-- Run a setup trace, stopping at the first request the law refuses. -/
def runSetup : RegistryState → List Request → (List SetupStep × RegistryState × Bool)
  | s, [] => ([], s, true)
  | s, r :: rest =>
    match step s r with
    | .error why =>
      ([{ request := r, accepted := false, reason := some why, state := s }], s, false)
    | .ok res =>
      let (steps, final, ok) := runSetup res.state rest
      ({ request := r, accepted := true, reason := none, state := res.state } :: steps, final, ok)

/-- What an executed result reports of itself, for a single request and a batch
alike: the state it produced, read back field by field, and its own mint and
payments. -/
def resultObservations (c : Config) (res : Result) : List (String × Json) :=
  [ ("config", toJson res.state.config)
  , ("custody", toJson res.state.custody)
  , ("held", Json.arr (res.state.held.map heldObservationJson).toArray)
  , ("mint", assetsJson c res.mint)
  , ("paid", Json.arr ((res.paid.map fun p =>
      Json.mkObj [("address", toJson p.1), ("value", toJson p.2)]).toArray))
  , ("root", toJson res.state.config.root)
  , ("state", toJson res.state) ]

/-- The declared boundary of one accepted transition. Each field delegates: the
leaf and root are read back off the state the law produced, the mint and the
payments are the executed result's own, and the transaction is the one
`Singular.admittedTxOfExit` built from that exit. -/
def observationsJson (c : Config) (r : Request) (res : Result) (tx : Tx) : Json :=
  Json.mkObj <| resultObservations c res ++
    [ ("leaf", leafJson (trieGet res.state.trie r.key))
    , ("tx", txJson c tx) ]

/-- The witness a scenario's exit is admitted under. A retraction is admitted
under the scenario's own, and a retraction that carries none has nothing to be
admitted under. A fold is admitted by `Singular.foldAdmission` under the upper
bound of the fold witness it carries, and a fold that carries none has nothing to
be admitted under; a reject has no admission and ignores the witness. -/
def admissionWitness (sc : Scenario) : Option RetractWitness :=
  match sc.exit with
  | .retract => sc.witness
  | .fold _ =>
    sc.foldWitness.map fun w =>
      { submittedAt := 0, validFrom := 0, validTo := w.validTo, signatories := [] }
  | .reject =>
    some { submittedAt := 0, validFrom := 0, validTo := 0, signatories := [] }

/-- F01 `runSurface`: execute one scenario against the model's law.

The order is the requirement: reach the state by running the law, check the
premise on the state reached, and only then apply the request and observe. An
observation that preceded its premise would be an observation of a state the
model does not admit.

The exit is taken through admission: `Singular.admittedExitStep` and
`Singular.admittedTxOfExit`, so a retraction is accepted only when
`Singular.retractAdmission` admits it under its witness, and a fold only when
`Singular.foldAdmission` admits its request, from the request's own submission
time, under the fold witness's validity upper bound; each is otherwise refused
with the admission's reason. A reject is exactly `Singular.exitStep` and
`Singular.txOfExit`. A retraction or a fold with no witness is `unsupported`: the
case was not described, and reading it as the model's refusal would dress a
missing input up as one. -/
def runSurface (sc : Scenario) : List SetupStep × DriverResult :=
  let (steps, s, reached) := runSetup sc.start sc.setup
  if !reached then
    (steps, { outcome := .unsupported, reason := some "setup-refused"
            , premiseChecked := false, observations := none })
  else if !consistentB s then
    (steps, { outcome := .unsupported, reason := some "premise-does-not-hold"
            , premiseChecked := false, observations := none })
  else
    match admissionWitness sc with
    | none =>
      (steps, { outcome := .unsupported
              , reason := some (match sc.exit with
                  | .fold _ => "fold-without-witness"
                  | _ => "retraction-without-witness")
              , premiseChecked := true, observations := none })
    | some witness =>
    match admittedExitStep s sc.exit sc.request witness with
    | .error why =>
      (steps, { outcome := .refused, reason := some why
              , premiseChecked := true, observations := none })
    | .ok res =>
      match admittedTxOfExit s sc.exit sc.request witness sc.lovelace with
      | .error why =>
        (steps, { outcome := .unsupported, reason := some ("transaction-unbuildable: " ++ why)
                , premiseChecked := true, observations := none })
      | .ok tx =>
        (steps, { outcome := .accepted, reason := none, premiseChecked := true
                , observations := some (observationsJson s.config sc.request res tx) })

/-- The declared judgements of a transaction a caller observed, in their order:
`spend`, the refusal `Singular.spendRefusal` gives the scenario's exit for the
inputs it spends, then `settle`, whether its outputs pay what that exit owes its
request and if not the reason `Singular.settle` gives. A retraction's admission is
not judged here: `runSurface` answers it first, refusing with its reason, so the
row and these judgements, read in that order, are `Singular.exitRefusal`. -/
def judgeSurface (sc : Scenario) (inputs : List TxInput) (outputs : List TxOutput) :
    Option String :=
  (spendRefusal sc.exit inputs).orElse fun _ => settle (obligations sc.exit sc.request) outputs

def setupStepJson (stp : SetupStep) : Json :=
  Json.mkObj
    [ ("request", toJson stp.request)
    , ("accepted", toJson stp.accepted)
    , ("reason", match stp.reason with | none => Json.null | some why => toJson why)
    , ("state", toJson stp.state) ]

/-- One executed scenario, serialized as the corpus row the checker reads. A
row carries its scenario's witness when it has one. -/
def scenarioJson (sc : Scenario) : Json :=
  let (steps, result) := runSurface sc
  Json.mkObj <|
    [ ("id", toJson sc.id)
    , ("theorem", toJson sc.theoremName)
    , ("statementSha256", toJson sc.statementSha256)
    , ("kind", toJson sc.kind)
    , ("mutates", match sc.mutates with | none => Json.null | some m => toJson m)
    , ("operation", toJson (exitName sc.exit))
    , ("requiresReachableState", toJson sc.requiresReachableState)
    , ("start", toJson sc.start)
    , ("request", toJson sc.request)
    , ("lovelace", toJson sc.lovelace) ]
    ++ (match sc.witness with | none => [] | some w => [("witness", toJson w)])
    ++ (match sc.foldWitness with | none => [] | some w => [("foldWitness", toJson w)])
    ++
    [ ("setup", Json.arr ((steps.map setupStepJson).toArray))
    , ("outcome", toJson (outcomeName result.outcome))
    , ("reason", match result.reason with | none => Json.null | some why => toJson why)
    , ("premise", Json.mkObj
        [ ("declaration", toJson premiseDeclaration)
        , ("checked", toJson result.premiseChecked) ])
    , ("observations", match result.observations with | none => Json.null | some o => o) ]

/-! ## The batch questions

Two laws a single-request scenario never reaches. `Singular.foldBatch` folds
several requests atomically: `empty-fold` for none, the first failing request's
`step` reason, then `net-mint-mismatch` when what the batch claims differs from
what its edges mint. A batch of rejects leaves the registry as it was and is
judged as `Singular.settle` over the concatenated obligations of its requests,
which is how `settle` states a batch. The driver answers each as a declared
question: it reaches the starting state and checks the premise exactly as
`runSurface` does, then reports what the law did. The model builds no
transaction for a batch, so no batch answer observes one. -/

/-- One batch question: requests each folded on its own edge, or requests each
taken by the exit it names, of which only a non-empty batch of rejects is
answered. -/
inductive BatchQuestion where
  | foldBatch (requests : List Request)
  | rejectBatch (requests : List (Exit × Request))

def batchQuestionName : BatchQuestion → String
  | .foldBatch _ => "foldBatch"
  | .rejectBatch _ => "rejectBatch"

/-- The distinct keys of a batch, in the order its requests first name them. -/
def batchKeys (requests : List Request) : List Key :=
  requests.foldl (fun acc r => if acc.contains r.key then acc else acc ++ [r.key]) []

/-- The declared boundary of an answered batch: what its result reports of
itself, and the leaf at every key the batch names, read off the state it
produced. -/
def batchObservationsJson (c : Config) (keys : List Key) (res : Result) : Json :=
  Json.mkObj <| resultObservations c res ++
    [ ("leaf", Json.arr (keys.map fun k =>
        Json.mkObj [("key", toJson k), ("leaf", leafJson (trieGet res.state.trie k))]).toArray) ]

/-- The requests of a batch of rejects: `none` for an empty batch and for one
naming any other exit, which the driver does not answer. -/
def batchRejects (batch : List (Exit × Request)) : Option (List Request) :=
  if batch.isEmpty then none
  else batch.mapM fun (exit, request) => if exit == .reject then some request else none

/-- A batch of rejects as the model steps it: each request through
`Singular.exitStep` with `Exit.reject`, from the state the previous left, the
results combined as `Singular.foldActions` combines a batch's. -/
def rejectBatchStep (s : RegistryState) (requests : List Request) : Except String Result :=
  requests.foldlM
    (fun acc request => do
      let t ← exitStep acc.state .reject request
      pure (combineResults acc t))
    (emptyResult s)

/-- What a batch of rejects owes: the concatenated obligations of its requests. -/
def rejectBatchPayments (requests : List Request) : List Payment :=
  requests.flatMap (obligations .reject)

/-- The judgement of a batch of rejects over the outputs of a transaction a caller
observed: `Singular.settle` over what the batch owes. -/
def judgeRejectBatch (requests : List Request) (outputs : List TxOutput) : Option String :=
  settle (rejectBatchPayments requests) outputs

/-- Reach a batch's starting state as `runSurface` reaches a scenario's: run the
setup trace through the law, then check the premise on the state it reached. -/
def reachBatchStart (start : RegistryState) (setup : List Request) :
    List SetupStep × Except DriverResult RegistryState :=
  let (steps, s, reached) := runSetup start setup
  if !reached then
    (steps, .error { outcome := .unsupported, reason := some "setup-refused"
                   , premiseChecked := false, observations := none })
  else if !consistentB s then
    (steps, .error { outcome := .unsupported, reason := some "premise-does-not-hold"
                   , premiseChecked := false, observations := none })
  else (steps, .ok s)

/-- F04 `runFoldBatch`: the `foldBatch` question. From the state the setup trace
reaches, with the premise checked, the batch is admitted first by
`Singular.foldAdmission` under the `Singular.FoldWitness` it carries
(`Singular.admittedFoldBatch`), and a batch carrying none is `unsupported`; an
admitted batch is then `Singular.foldBatch` verbatim:
refused for its reason, or accepted with the declared batch boundary. Beside the
answer it returns the batch's step trace, each request through `Singular.step`
from the state the previous left until the first one the law refuses, so a
reader can see which request a refusal came from. -/
def runFoldBatch (start : RegistryState) (setup batch : List Request)
    (witness : Option FoldWitness := none) :
    List SetupStep × List SetupStep × DriverResult :=
  match reachBatchStart start setup with
  | (steps, .error result) => (steps, [], result)
  | (steps, .ok s) =>
    match witness with
    | none =>
      (steps, [], { outcome := .unsupported, reason := some "fold-without-witness"
                  , premiseChecked := true, observations := none })
    | some w =>
    match foldAdmission s.config batch w with
    | some why =>
      (steps, [], { outcome := .refused, reason := some why
                  , premiseChecked := true, observations := none })
    | none =>
    let (folded, _, _) := runSetup s batch
    match foldBatch s batch with
    | .error why =>
      (steps, folded, { outcome := .refused, reason := some why
                      , premiseChecked := true, observations := none })
    | .ok res =>
      (steps, folded, { outcome := .accepted, reason := none, premiseChecked := true
                      , observations := some (batchObservationsJson s.config (batchKeys batch) res) })

/-- F05 `runRejectBatch`: the `rejectBatch` question. From the state the setup
trace reaches, with the premise checked, a non-empty batch of rejects is stepped
by `rejectBatchStep` and answered with the declared batch boundary; an empty
batch, and one naming a fold or a retract, is `unsupported`. -/
def runRejectBatch (start : RegistryState) (setup : List Request) (batch : List (Exit × Request)) :
    List SetupStep × DriverResult :=
  match reachBatchStart start setup with
  | (steps, .error result) => (steps, result)
  | (steps, .ok s) =>
    match batchRejects batch with
    | none =>
      (steps, { outcome := .unsupported
              , reason := some (if batch.isEmpty then "empty-reject-batch"
                                else "reject-batch-names-another-exit")
              , premiseChecked := true, observations := none })
    | some requests =>
      match rejectBatchStep s requests with
      | .error why =>
        (steps, { outcome := .refused, reason := some why
                , premiseChecked := true, observations := none })
      | .ok res =>
        (steps, { outcome := .accepted, reason := none, premiseChecked := true
                , observations := some (batchObservationsJson s.config (batchKeys requests) res) })

/-- D04: one batch scenario. Like a scenario it is bound to a theorem, reaches its
starting state by a setup trace, and, for a batch of rejects, may carry the
outputs of a transaction a caller observed, to be judged. -/
structure BatchScenario where
  id : String
  theoremName : String
  statementSha256 : String
  kind : String
  mutates : Option String
  requiresReachableState : Bool
  start : RegistryState
  setup : List Request
  question : BatchQuestion
  outputs : Option (List TxOutput) := none
  foldWitness : Option FoldWitness := none

/-- One judged output in the spelling a caller gives it: its role, the identity of
its address, its lovelace, the form of its datum and the reference its inline datum
presents. `settle` reads nothing else of an output. -/
def judgedOutputJson (o : TxOutput) : Json :=
  Json.mkObj
    [ ("role", toJson (txRoleName o.role))
    , ("address", match o.address with | none => Json.null | some a => toJson a)
    , ("lovelace", toJson o.lovelace)
    , ("datum", toJson (datumFormName o.datum))
    , ("reference", match o.reference with | none => Json.null | some x => toJson x) ]

/-- One executed batch scenario, serialized as the corpus row the checker reads.
A fold batch row carries its step trace (`folded`); a batch of rejects carries
each request with its exit, and, when it was given outputs, `settle`'s judgement
of them for an answered batch. -/
def batchScenarioJson (sc : BatchScenario) : Json :=
  let (steps, folded, result, requests, settled) :
      List SetupStep × Option (List SetupStep) × DriverResult × Json × Option Json :=
    match sc.question with
    | .foldBatch batch =>
      let (steps, folded, result) := runFoldBatch sc.start sc.setup batch sc.foldWitness
      (steps, some folded, result, Json.arr (batch.map toJson).toArray, none)
    | .rejectBatch batch =>
      let (steps, result) := runRejectBatch sc.start sc.setup batch
      let settled : Option Json :=
        match sc.outputs, result.outcome, batchRejects batch with
        | some outputs, .accepted, some rejects =>
          some (match judgeRejectBatch rejects outputs with
                | none => Json.null
                | some why => toJson why)
        | _, _, _ => none
      (steps, none, result,
        Json.arr (batch.map fun (p : Exit × Request) =>
          Json.mkObj [("exit", toJson (exitName p.1)), ("request", toJson p.2)]).toArray,
        settled)
  Json.mkObj <|
    [ ("id", toJson sc.id)
    , ("theorem", toJson sc.theoremName)
    , ("statementSha256", toJson sc.statementSha256)
    , ("kind", toJson sc.kind)
    , ("mutates", match sc.mutates with | none => Json.null | some m => toJson m)
    , ("question", toJson (batchQuestionName sc.question))
    , ("requiresReachableState", toJson sc.requiresReachableState)
    , ("start", toJson sc.start)
    , ("requests", requests)
    , ("setup", Json.arr ((steps.map setupStepJson).toArray)) ]
    ++ (match folded with
        | none => []
        | some f => [("folded", Json.arr ((f.map setupStepJson).toArray))])
    ++ (match sc.outputs with
        | none => []
        | some outputs => [("outputs", Json.arr ((outputs.map judgedOutputJson).toArray))])
    ++ (match sc.foldWitness with | none => [] | some w => [("foldWitness", toJson w)])
    ++ (match settled with | none => [] | some j => [("settle", j)])
    ++
    [ ("outcome", toJson (outcomeName result.outcome))
    , ("reason", match result.reason with | none => Json.null | some why => toJson why)
    , ("premise", Json.mkObj
        [ ("declaration", toJson premiseDeclaration)
        , ("checked", toJson result.premiseChecked) ])
    , ("observations", match result.observations with | none => Json.null | some o => o) ]

end Driver
end Singular
