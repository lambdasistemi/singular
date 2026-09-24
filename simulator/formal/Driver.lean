import Singular.Model

/-! # The generic model driver

One driver over the model's own law, in place of one adapter per theorem.

Given a scenario it reaches the scenario's starting state by *running* the law
over a setup trace, checks the law premise on the state it arrived at, takes the
scenario's exit on the request through `Singular.exitStep`, and reports the whole
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

def datumFormName : DatumForm → String
  | .inline => "inline"
  | .hashed => "hashed"
  | .none => "none"

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
    , ("lovelace", toJson o.lovelace) ]

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
caller observed, beside the boundary it reports. `settle` judges whether the
observed outputs pay what the scenario's exit owes, by `Singular.settle`. -/
def declaredJudgements : List String := ["settle"]

/-- D01: the surface identity a scenario is executed against. -/
structure SurfaceIdentity where
  declaration : String
  protocolVersion : Nat
  operations : List String
  observations : List String
  unobservable : List String
  judgements : List String

def surface : SurfaceIdentity :=
  { declaration := "Singular.Driver.runSurface"
  , protocolVersion := 3
  , operations := declaredOperations
  , observations := declaredObservations
  , unobservable := declaredUnobservable
  , judgements := declaredJudgements }

def surfaceJson (s : SurfaceIdentity) (definitionDigest : String) : Json :=
  Json.mkObj
    [ ("declaration", toJson s.declaration)
    , ("definitionDigest", toJson definitionDigest)
    , ("protocolVersion", toJson s.protocolVersion)
    , ("operations", toJson s.operations)
    , ("observations", toJson s.observations)
    , ("unobservable", toJson s.unobservable)
    , ("judgements", toJson s.judgements) ]

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
trace that produces it, so a constructed final state cannot stand in for one. -/
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

/-- The declared boundary of one accepted transition. Each field delegates: the
leaf and root are read back off the state the law produced, the mint and the
payments are the executed result's own, and the transaction is the one
`Singular.txOfExit` built from that exit. -/
def observationsJson (c : Config) (r : Request) (res : Result) (tx : Tx) : Json :=
  Json.mkObj
    [ ("config", toJson res.state.config)
    , ("custody", toJson res.state.custody)
    , ("held", toJson res.state.held)
    , ("leaf", leafJson (trieGet res.state.trie r.key))
    , ("mint", assetsJson c res.mint)
    , ("paid", Json.arr ((res.paid.map fun p =>
        Json.mkObj [("address", toJson p.1), ("value", toJson p.2)]).toArray))
    , ("root", toJson res.state.config.root)
    , ("state", toJson res.state)
    , ("tx", txJson c tx) ]

/-- F01 `runSurface`: execute one scenario against the model's law.

The order is the requirement: reach the state by running the law, check the
premise on the state reached, and only then apply the request and observe. An
observation that preceded its premise would be an observation of a state the
model does not admit. -/
def runSurface (sc : Scenario) : List SetupStep × DriverResult :=
  let (steps, s, reached) := runSetup sc.start sc.setup
  if !reached then
    (steps, { outcome := .unsupported, reason := some "setup-refused"
            , premiseChecked := false, observations := none })
  else if !consistentB s then
    (steps, { outcome := .unsupported, reason := some "premise-does-not-hold"
            , premiseChecked := false, observations := none })
  else
    match exitStep s sc.exit sc.request with
    | .error why =>
      (steps, { outcome := .refused, reason := some why
              , premiseChecked := true, observations := none })
    | .ok res =>
      match txOfExit s sc.exit sc.request sc.lovelace with
      | .error why =>
        (steps, { outcome := .unsupported, reason := some ("transaction-unbuildable: " ++ why)
                , premiseChecked := true, observations := none })
      | .ok tx =>
        (steps, { outcome := .accepted, reason := none, premiseChecked := true
                , observations := some (observationsJson s.config sc.request res tx) })

/-- The declared judgement `settle`: whether the outputs of a transaction a
caller observed pay what the scenario's exit owes its request, and if not, the
reason `Singular.settle` gives. -/
def judgeSurface (sc : Scenario) (outputs : List TxOutput) : Option String :=
  settle (obligations sc.exit sc.request) outputs

def setupStepJson (stp : SetupStep) : Json :=
  Json.mkObj
    [ ("request", toJson stp.request)
    , ("accepted", toJson stp.accepted)
    , ("reason", match stp.reason with | none => Json.null | some why => toJson why)
    , ("state", toJson stp.state) ]

/-- One executed scenario, serialized as the corpus row the checker reads. -/
def scenarioJson (sc : Scenario) : Json :=
  let (steps, result) := runSurface sc
  Json.mkObj
    [ ("id", toJson sc.id)
    , ("theorem", toJson sc.theoremName)
    , ("statementSha256", toJson sc.statementSha256)
    , ("kind", toJson sc.kind)
    , ("mutates", match sc.mutates with | none => Json.null | some m => toJson m)
    , ("operation", toJson (exitName sc.exit))
    , ("requiresReachableState", toJson sc.requiresReachableState)
    , ("start", toJson sc.start)
    , ("request", toJson sc.request)
    , ("lovelace", toJson sc.lovelace)
    , ("setup", Json.arr ((steps.map setupStepJson).toArray))
    , ("outcome", toJson (outcomeName result.outcome))
    , ("reason", match result.reason with | none => Json.null | some why => toJson why)
    , ("premise", Json.mkObj
        [ ("declaration", toJson premiseDeclaration)
        , ("checked", toJson result.premiseChecked) ])
    , ("observations", match result.observations with | none => Json.null | some o => o) ]

end Driver
end Singular
