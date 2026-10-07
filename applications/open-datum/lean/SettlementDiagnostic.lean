import OpenDatumApplication.Model
import OpenDatumApplication.Driver

/-! # 310-settlement-diagnostic-001

A standalone execution of the current law at one boundary. It proves nothing
and uses no statement: it runs `OpenDatumApplication.selectRow`,
`createdOutputs` and `foldEffect` as they stand at 3b6d6e5, and reports
computed values.

The subject is the conjunct of `OpenDatumApplication.Statements.fold_settles_additively`
that every spent output was a live output and is gone after the fold, which
that statement states over ANY world. Two cases, each observed by the same
functions:

* **malformed boundary** (proof plan 22a189e4): genesis registry, key 5
  `unknown`, yet one application output `o` of key 5 at reference 0 with
  `nextRef = 0`, and booked an insertion and a termination of key 5. The fold
  selecting both is observed: its selected rows, acceptance, inventories, mint,
  payments, the spent-removal observation and the additive floors;
* **reached control**: genesis, then book and fold an insertion, a signed
  payload update, and book a termination, every step through `appStep`, then the
  same observations of the termination fold.

Each fold case also runs with the controller paid one lovelace short, to show
the settlement observation detects a genuine shortfall and to report the law's
actual reason. The exit status is 0 only if every stated control holds. -/

open Lean
open Singular
open OpenDatumApplication
open OpenDatumApplication.Driver

namespace SettlementDiagnostic

/-! ## Observers -/

/-- The spent-removal conjunct, observed: every output the selected rows spend
was live before and is not live after. -/
def spentRemoved (before after : World) (rows : List FoldRow) : Bool :=
  (rows.filterMap (·.spent)).all fun s => before.outputs.contains s && !after.outputs.contains s

/-- The deliveries a fold's insertions present, as the law settles against them. -/
def settledOutputs (w : World) (rows : List FoldRow) (outs : List TxOutput) : List TxOutput :=
  outs ++ (createdOutputs w.app w.nextRef rows).map (deliveryOf w.app)

/-- The additive floors, observed: every recipient the payments name receives at
least the sum of what it is owed. -/
def additiveFloorsHold (ps : List Payment) (outs : List TxOutput) : Bool :=
  (ps.map (·.recipient)).all fun r => decide (owedTo r ps ≤ receivedBy r outs)

def recipientJson : Recipient → Json
  | .destination a d => Json.mkObj [("destination", toJson a), ("datum", datumJson d)]
  | .custody => Json.str "custody"
  | .owner k => Json.mkObj [("owner", toJson k)]
  | .bound k r => Json.mkObj [("owner", toJson k), ("boundReference", toJson r)]

def floorsJson (ps : List Payment) (outs : List TxOutput) : Json :=
  Json.arr ((ps.map (·.recipient)).eraseDups.map fun r =>
    Json.mkObj [("recipient", recipientJson r), ("owed", toJson (owedTo r ps))
      , ("received", toJson (receivedBy r outs))]).toArray

def rowJson (r : FoldRow) : Json :=
  Json.mkObj [("edge", toJson r.pending.request.edge), ("key", toJson r.pending.request.key)
    , ("owner", toJson r.pending.request.owner), ("deposit", toJson r.pending.request.deposit)
    , ("spentRef", toJson (r.spent.map (·.ref)))]

def inventoryJson (w : World) : Json :=
  Json.arr (w.outputs.map fun x =>
    Json.mkObj [("ref", toJson x.ref), ("key", toJson x.envelope.control.key)
      , ("lovelace", toJson x.lovelace), ("payload", dataToJson x.envelope.payload)
      , ("envelopeHash", toJson (envelopeHash x.envelope))]).toArray

def keyedPayload (o : AppOutput) : Json :=
  Json.mkObj [("ref", toJson o.ref), ("payload", dataToJson o.envelope.payload)
    , ("envelopeHash", toJson (envelopeHash o.envelope))]

/-- A world as published here: every field the law reads, the booked requests with
their approvals and claims, and the invariant observed on it. -/
def worldJson (w : World) : Json :=
  Json.mkObj [("registry", toJson w.registry), ("registryAsset", toJson w.registryAsset)
    , ("outputs", Json.arr (w.outputs.map outputToJson).toArray)
    , ("pending", Json.arr (w.pending.map fun p =>
        Json.mkObj [("request", toJson p.request)
          , ("envelope", match p.envelope with | some e => envelopeToJson e | none => Json.null)]).toArray)
    , ("nextRef", toJson w.nextRef), ("lastMint", assetsToJson w.lastMint)
    , ("invariant", toJson (appConsistentB w))]

/-! ## One observed fold -/

structure FoldCase where
  name : String
  world : World
  selected : List (Edge × Key)
  outputs : List TxOutput

def rowsOf (c : FoldCase) : Except String (List FoldRow) :=
  c.selected.mapM (selectRow Law.standard c.world)

def resultOf (c : FoldCase) : Except String (World × Result) :=
  foldEffect Law.standard c.world c.selected c.outputs

def spentObserved (c : FoldCase) : Option Bool :=
  match rowsOf c, resultOf c with
  | .ok rows, .ok (w', _) => some (spentRemoved c.world w' rows)
  | _, _ => none

def additiveObserved (c : FoldCase) : Option Bool :=
  match rowsOf c with
  | .ok rows => some (additiveFloorsHold (foldPayments rows) (settledOutputs c.world rows c.outputs))
  | .error _ => none

def refusalOf (c : FoldCase) : Option String :=
  match resultOf c with
  | .ok _ => none
  | .error why => some why

def caseJson (c : FoldCase) : Json :=
  let rowsJson := match rowsOf c with
    | .ok rows => Json.arr (rows.map rowJson).toArray
    | .error why => Json.mkObj [("refused", toJson why)]
  let paymentsJson := match rowsOf c with
    | .ok rows => floorsJson (foldPayments rows) (settledOutputs c.world rows c.outputs)
    | .error _ => Json.null
  let resultJson := match resultOf c with
    | .ok (w', t) => Json.mkObj [("outcome", "accepted"), ("mint", assetsToJson t.mint)
        , ("finalInventory", inventoryJson w'), ("finalWorld", worldJson w')
        , ("finalInvariant", toJson (appConsistentB w'))
        , ("finalLeafKey5", leafJson (trieGet w'.registry.trie 5))]
    | .error why => Json.mkObj [("outcome", "refused"), ("reason", toJson why)]
  Json.mkObj [("case", toJson c.name), ("selected", selectionToJson c.selected)
    , ("action", actionToJson (.fold c.selected c.outputs))
    , ("paymentOutputs", paymentsToJson c.outputs)
    , ("initialWorld", worldJson c.world)
    , ("initialInventory", inventoryJson c.world)
    , ("initialInvariant", toJson (appConsistentB c.world))
    , ("initialLeafKey5", leafJson (trieGet c.world.registry.trie 5))
    , ("rows", rowsJson), ("floors", paymentsJson), ("result", resultJson)
    , ("spentRemovedObserved", toJson (spentObserved c))
    , ("additiveFloorsObserved", toJson (additiveObserved c))]

/-! ## The malformed boundary -/

def malformedEnvelope : Envelope := envelopeFor 5 payload0

def malformedOutput : AppOutput :=
  { ref := 0, address := appAddress app0, lovelace := insertDeposit
  , assets := [((.active, 5), 1)], envelope := malformedEnvelope }

def genesis0 : World := genesis app0 cfg0 app0.registry

def malformedWorld : World :=
  { genesis0 with
    outputs := [malformedOutput],
    pending := [⟨booked app0 (insertRequest 5 malformedEnvelope) [controller], some malformedEnvelope⟩,
                ⟨booked app0 (terminateRequest 5) [controller], none⟩] }

def bothOfKey5 : List (Edge × Key) := [(.insertActive, 5), (.updateTerminal, 5)]

def malformedPaid : FoldCase :=
  { name := "malformed-boundary", world := malformedWorld, selected := bothOfKey5
  , outputs := paid (insertDeposit + terminateDeposit) }

def malformedShort : FoldCase :=
  { malformedPaid with
    name := "malformed-boundary-short-by-one"
    outputs := paid (insertDeposit + terminateDeposit - 1) }

/-! ## The reached control -/

def lifecycleActions : List AppAction :=
  insertKey 5 ++
    [ .update 0 [successorOf 5 payload1 insertDeposit] [controller]
    , .bookTerminate (terminateRequest 5) 1 [controller] ]

/-- Every step through `appStep`, each required to succeed. -/
def runChain (w : World) : List AppAction → Except String (List World)
  | [] => .ok []
  | a :: rest => do
    let w' ← appStep w a
    let ws ← runChain w' rest
    pure (w' :: ws)

def chainResult : Except String (List World) := runChain genesis0 lifecycleActions

/-- The lifecycle as published: each action, the world it met, the law's outcome and
the world it reached, computed by the same `appStep`. -/
def traceChain (w : World) : Nat → List AppAction → List Json
  | _, [] => []
  | i, a :: rest =>
    let before := Json.mkObj [("invariant", toJson (appConsistentB w)), ("nextRef", toJson w.nextRef)
      , ("outputs", Json.arr (w.outputs.map keyedPayload).toArray)]
    match appStep w a with
    | .ok w' =>
      Json.mkObj [("step", toJson i), ("action", actionToJson a), ("before", before)
        , ("outcome", "accepted"), ("after", worldJson w')] :: traceChain w' (i + 1) rest
    | .error why =>
      [Json.mkObj [("step", toJson i), ("action", actionToJson a), ("before", before)
        , ("outcome", "refused"), ("reason", toJson why)]]

def lastWorld : World :=
  match chainResult with
  | .ok ws => ws.getLastD genesis0
  | .error _ => genesis0

def terminateOnly : List (Edge × Key) := [(.updateTerminal, 5)]

def lifecyclePaid : FoldCase :=
  { name := "reached-lifecycle", world := lastWorld, selected := terminateOnly
  , outputs := paid (insertDeposit + terminateDeposit) }

def lifecycleShort : FoldCase :=
  { lifecyclePaid with
    name := "reached-lifecycle-short-by-one"
    outputs := paid (insertDeposit + terminateDeposit - 1) }

/-- Key 5's output where the chain first holds one, and where it ends. -/
def keyFiveOutputs : List AppOutput :=
  match chainResult with
  | .ok ws => ws.filterMap (outputOfKey · 5)
  | .error _ => []

def referenceTrace : Json :=
  let original := keyFiveOutputs.head?
  let current := outputOfKey lastWorld 5
  Json.mkObj [("original", match original with | some o => keyedPayload o | none => Json.null)
    , ("current", match current with | some o => keyedPayload o | none => Json.null)
    , ("referenceChanged", toJson (original.map (·.ref) != current.map (·.ref)))
    , ("payloadChanged",
        toJson (original.map (·.envelope.payload) != current.map (·.envelope.payload)))]

/-- The termination fold as `appStep` computes it from the chain's last world. -/
def terminationStep : Json :=
  let a : AppAction := .fold terminateOnly lifecyclePaid.outputs
  Json.mkObj [("action", actionToJson a), ("before", worldJson lastWorld)
    , ("result", match appStep lastWorld a with
        | .ok w' => Json.mkObj [("outcome", "accepted"), ("after", worldJson w')]
        | .error why => Json.mkObj [("outcome", "refused"), ("reason", toJson why)])]

/-! ## Controls -/

def check (ok : Bool) (line : String) : Json :=
  Json.mkObj [("control", toJson line), ("holds", toJson ok)]

def chainOk : Bool :=
  match chainResult with
  | .ok ws => ws.length == lifecycleActions.length && appConsistentB genesis0 && ws.all appConsistentB
  | .error _ => false

def lifecycleAfter : Option World :=
  match resultOf lifecyclePaid with
  | .ok (w', _) => some w'
  | .error _ => none

def lifecycleMintKey5 : Option Int :=
  match resultOf lifecyclePaid with
  | .ok (_, t) => some (assetKind t.mint (.active, 5))
  | .error _ => none

def appStepAgrees : Bool :=
  match appStep lastWorld (.fold terminateOnly lifecyclePaid.outputs), lifecycleAfter with
  | .ok w', some w'' => w' == w''
  | _, _ => false

def controls : List Json :=
  [ check (!appConsistentB malformedWorld)
      "malformed start is outside the invariant"
  , check ((resultOf malformedPaid).isOk)
      "malformed fold is accepted by the current law"
  , check (spentObserved malformedPaid == some false)
      "malformed boundary: the spent-removal observation is false (the spent output is live after the fold)"
  , check (additiveObserved malformedPaid == some true)
      "malformed boundary: the additive floors hold"
  , check (additiveObserved malformedShort == some false && refusalOf malformedShort != none)
      "malformed boundary short by one: floors fail and the fold is refused"
  , check chainOk
      "reached control: every step succeeds through appStep and every world observes the invariant"
  , check ((outputOfKey lastWorld 5).map (·.ref) == some 1 &&
      (outputOfKey lastWorld 5).map (·.envelope.payload) == some payload1)
      "reached control: the updated output is at reference 1 with the updated payload (original reference 0)"
  , check (appStepAgrees && spentObserved lifecyclePaid == some true)
      "reached control: the termination fold is accepted by appStep and the spent-removal observation is true"
  , check (lifecycleMintKey5 == some (-1) &&
      (lifecycleAfter.map fun x => trieGet x.registry.trie 5) == some (.known .terminal) &&
      (lifecycleAfter.map fun x => (outputOfKey x 5).isNone) == some true &&
      (lifecycleAfter.map appConsistentB) == some true)
      "reached control: key 5 burned (-1), Terminal, no live output, invariant after"
  , check (additiveObserved lifecyclePaid == some true)
      "reached control: the additive floors hold"
  , check (additiveObserved lifecycleShort == some false && refusalOf lifecycleShort != none)
      "reached control short by one: floors fail and the fold is refused" ]

def report : Json :=
  Json.mkObj [("id", "310-settlement-diagnostic-001"), ("base", "3b6d6e57ef3fcb2bbe6eccd2fcef0deeec3a7579")
    , ("chainOutcome", match chainResult with
        | .ok ws => toJson ws.length
        | .error why => toJson s!"refused: {why}")
    , ("genesis", worldJson genesis0)
    , ("lifecycle", Json.arr (traceChain genesis0 1 lifecycleActions).toArray)
    , ("referenceTrace", referenceTrace)
    , ("terminationStep", terminationStep)
    , ("cases", Json.arr #[caseJson malformedPaid, caseJson malformedShort,
        caseJson lifecyclePaid, caseJson lifecycleShort])
    , ("shortfallReasons", Json.mkObj [("malformed", toJson (refusalOf malformedShort))
        , ("reached", toJson (refusalOf lifecycleShort))])
    , ("controls", Json.arr controls.toArray)]

end SettlementDiagnostic

open SettlementDiagnostic in
def main : IO UInt32 := do
  IO.println report.pretty
  let failing := controls.filter fun c => (c.getObjValAs? Bool "holds").toOption != some true
  IO.println s!"diagnostic controls: {controls.length - failing.length} hold, {failing.length} fail"
  pure (if failing.isEmpty then 0 else 1)
