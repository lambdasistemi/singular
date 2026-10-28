import NoPin.Held.Value
import NoPin.Oracle

/-! Hypothetical #741 oracle. A query calls a named definition from explicit
public records. Canonical fold observations are computed with accepted root
functions. No theorem name, expected verdict or private booking file is an input. -/
namespace NoPin.Held
open Singular Lean

/-- Hypothesis under #741, not accepted law; generic public inputs. -/
structure Query where
  surface : Case
  hashes : List NoPin.HashEntry
  state : ApplicationState
  source : LockedOutput
  pending : Pending
  selected : List Pending
  signers : List Nat
  key : Key
  time : Nat
  funding : Nat
  fee : Nat
  physical : Option PhysicalView := none
  assets : Option TxView := none
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; actual physical singular-token census. -/
def physicalCount (s : ApplicationState) (key : Key) : Nat :=
  (s.outputs.map fun o => if (holdingOf o).control.key == key
    then (holdingOf o).quantity else 0).sum
/-- Hypothesis under #741, not accepted law; constructed attempted rejection consumes the pending reference. -/
def attemptedRejection (q : Query) (o : FoldObservation) : Rejection :=
  let transaction := { o.transaction.transaction with
    inputs := [foldWitnessInput q.pending.booking.request.reference],
    referenceInputs := [foldWitnessInput ⟨terminationWitnessFresh o.before, 0⟩] }
  { transaction := { o.transaction with transaction := transaction },
    stateReference := ⟨terminationWitnessFresh o.before, 0⟩,
    members := [(q.pending.booking.request.reference, .expired)] }
/-- Hypothesis under #741, not accepted law; the unmutated branch calls the accepted rejection judgement. -/
def rejected (m : Mutation) (q : Query) (o : FoldObservation) : Bool :=
  applyGuard m .rejectionDecision (!((rejectionAccepted o.before o.unspent (attemptedRejection q o)).isOk))
/-- Hypothesis under #741, not accepted law; exercise the permanent registry law at the actual folded key. -/
def permanent (m : Mutation) (q : Query) (o : FoldObservation) : Bool :=
  let c := o.after.registry.config
  let r : Request := {
    edge := .insertActive, key := q.key, owner := 42, output := 55,
    claimed := delta .insertActive, approval := some {
      policy := c.applicationPolicy, edge := .insertActive, key := q.key,
      owner := 42, destination := 55, assetName := approvalAssetName .insertActive q.key 42 55 } }
  applyGuard m .permanentDecision (!((step o.after.registry r).isOk))
/-- Hypothesis under #741, not accepted law; exhaustive public definition dispatch. -/
def runWith (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Bool :=
  let registry := q.pending.holding.control.registry
  let o := canonicalFold q.state q.selected q.time q.funding q.fee
  let v := q.physical.getD (canonicalPhysical q.selected o)
  let baseTx := canonicalLocal registry q.selected o v
  let tx := { baseTx with assets := q.assets.getD baseTx.assets }
  match q.surface with
  | .liveUpdate => liveSpend m .update q.source
  | .liveRelease => liveSpend m .release q.source
  | .genuine => genuine m hash code q.state.registry.config q.source
  | .booking => book m hash code q.state q.source q.pending q.signers
  | .rebooking => !(book m hash code q.state q.source q.pending q.signers)
  | .pendingRelease => pendingRelease m hash code q.state.registry.config q.pending tx
  | .projection => worldSingularSupply (projectWith m q.state) q.key == physicalCount q.state q.key
  | .coupling => couplingCheck m registry q.key
      (roleAsset hash code registry .witness q.key) tx.assets o
  | .discovery => (discoverWith m q.state).contains q.pending
  | .consumption => (discover (consumeWith m q.state o.transaction)).contains q.pending
  | .economicAvailability => economicAvailability m q.state q.pending q.time q.funding q.fee
  | .partition => valuePartitionWith m q.selected o v
  | .composed => composedWith m hash code registry q.selected o v
  | .rejection => rejected m q o
  | .permanent => permanent m q o
/-- Hypothesis under #741, not accepted law; explicit finite hash table oracle specialization. -/
def runQuery (m : Mutation) (q : Query) : Bool := runWith m (NoPin.lookupHash q.hashes) encode q
/-- Hypothesis under #741, not accepted law; no theorem-specific codec or expected value. -/
structure Scenario where
  query : Query
  mutation : Mutation
  deriving ToJson, FromJson

end NoPin.Held
