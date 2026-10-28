import NoPin.Held.Oracle
import Singular.Statements.RejectionProtection

/-! Explicit inversion conditions for the #741 hypotheses, not accepted law.
These state the input guards and effects; they do not read mutation selectors. -/
namespace NoPin.Held
open Singular

/-- Hypothesis under #741, not accepted law; explicit live-state classification. -/
def isLive : LockedOutput → Bool | .live _ => true | .pending _ => false
/-- Hypothesis under #741, not accepted law; full genuine-output conditions. -/
def genuineConditions (hash : Hash) (code : Codec) (c : Config) (o : LockedOutput) : Bool :=
  let h := holdingOf o
  h.token == roleAsset hash code h.control.registry .witness h.control.key &&
  h.quantity == 1 && h.provenance == h.token && h.rootHolding.key == h.control.key &&
  h.rootHolding.kind == .active && match o with
  | .live _ => true
  | .pending p => h.reference == p.booking.request.reference &&
      h.lovelace == p.booking.request.contents.lovelace + h.control.deposit &&
      terminationExactContents c p.booking.request &&
      (p.booking.custodyInputs == [h.rootHolding] && p.booking.request.key == h.control.key)
/-- Hypothesis under #741, not accepted law; full controller-authorized booking conditions. -/
def bookingConditions (hash : Hash) (code : Codec) (q : Query) : Bool :=
  match q.source with
  | .pending _ => false
  | .live h =>
    q.state.outputs.contains q.source && genuine .none hash code q.state.registry.config q.source &&
    q.signers.contains h.control.controller && q.pending.holding.family == h.family &&
    q.pending.holding.control == h.control &&
    (q.pending.holding.token == h.token && q.pending.holding.quantity == 1 &&
      q.pending.holding.provenance == h.provenance && q.pending.holding.rootHolding == h.rootHolding) &&
    q.pending.holding.payload == h.payload &&
    (q.pending.holding.reference == q.pending.booking.request.reference && q.pending.holding.reference != h.reference) &&
    q.pending.holding.lovelace == q.pending.booking.request.contents.lovelace + q.pending.holding.control.deposit &&
    q.pending.holding.control.deposit <= q.pending.holding.lovelace &&
    (h.control.registry == q.state.registryIdentity && q.pending.booking.custodyInputs == [h.rootHolding] && q.pending.booking.request.key == h.control.key) &&
    (bookTermination (project q.state) q.pending.booking).isOk
/-- Hypothesis under #741, not accepted law; exact local release conditions under the new settlement ruling. -/
def releaseConditions (hash : Hash) (code : Codec) (c : Config) (p : Pending) (tx : LocalTransaction) : Bool :=
  genuine .none hash code c (.pending p) &&
  (tx.spent.contains p && tx.assets.spent.contains p.holding.reference) &&
  decide (tx.assets.spent.Nodup ∧ (tx.spent.map (·.holding.reference)).Nodup ∧
    (tx.payments.map (·.index)).Nodup) && mintQty tx.assets p.holding.token == -1 &&
  releasedTo tx.spent p.holding.family p.holding.control.controller <= localPayments tx p.holding.control.controller
/-- Hypothesis under #741, not accepted law; custody census comes from live tags, never addresses. -/
def censusWorld (s : ApplicationState) : World :=
  let holdings := s.outputs.filterMap fun o => match o with | .live h => some h.rootHolding | _ => none
  let pending := s.outputs.filterMap fun o => match o with | .pending p => some p.booking | _ => none
  { registry := { s.registry with held := holdings }, pending := s.registrations,
    terminations := pending, treasury := s.treasury }
/-- Hypothesis under #741, not accepted law; complete disjoint-value conditions. -/
def partitionConditions (ps : List Pending) (o : FoldObservation) (v : PhysicalView) : Bool :=
  v.inputs == (economicInputs o).map (fun p => (p.1, p.2 + inputDeposit ps p.1)) &&
  v.outputs == o.transaction.outputs.zipIdx.map (fun (out, index) =>
    PhysicalOutput.mk index out.output.address (out.output.lovelace + allocated v index)) &&
  decide (v.allocations.map Prod.fst).Nodup && v.allocations.all (fun a => a.1 < v.outputs.length) &&
  ps.all (fun p => ((v.outputs.filter fun out => out.address == some p.holding.control.controller).map
    (fun out => allocated v out.index)).sum == controllerDeposit ps p.holding.control.controller)
/-- Hypothesis under #741, not accepted law; each public inversion's full unselected conditions. -/
def expectedWith (hash : Hash) (code : Codec) (q : Query) : Bool :=
  let registry := q.pending.holding.control.registry
  let o := canonicalFold q.state q.selected q.time q.funding q.fee
  let v := q.physical.getD (canonicalPhysical q.selected o)
  let baseTx := canonicalLocal registry q.selected o v
  let tx := { baseTx with assets := q.assets.getD baseTx.assets }
  match q.surface with
  | .liveUpdate | .liveRelease => isLive q.source
  | .genuine => genuineConditions hash code q.state.registry.config q.source
  | .booking => bookingConditions hash code q
  | .rebooking => !bookingConditions hash code q
  | .pendingRelease => releaseConditions hash code q.state.registry.config q.pending tx
  | .projection => worldSingularSupply (censusWorld q.state) q.key == physicalCount q.state q.key
  | .coupling => decide (observationCorrespondence registry q.key
      (roleAsset hash code registry .witness q.key) tx.assets o) && acceptedFold o &&
      ((foldMembers o.before o.transaction).any fun member => match member with
        | .termination b => b.request.key == q.key | _ => false) &&
      trieGet o.after.registry.trie q.key == .known .terminal
  | .discovery => q.state.outputs.contains (.pending q.pending)
  | .consumption => q.state.outputs.contains (.pending q.pending) &&
      !inputsContainReference o.transaction.transaction.inputs q.pending.holding.reference
  | .economicAvailability => (foldAccepted (project q.state)
      (terminationWitnessUnspent (project q.state) q.funding)
      (terminationWitnessTransaction (project q.state) q.pending.booking q.time q.funding q.fee)).isOk
  | .partition => partitionConditions q.selected o v
  | .composed => acceptedFold o && valuePartition q.selected o v && physicalBalanced o v &&
      q.selected.all (fun p => pendingRelease .none hash code o.before.registry.config p
        (canonicalLocal registry q.selected o v))
  | .rejection => !((rejectionAccepted o.before o.unspent (attemptedRejection q o)).isOk)
  | .permanent => permanent .none q o

/-- Hypothesis under #741, not accepted law; oracle specialization of explicit conditions. -/
def expected (q : Query) : Bool := expectedWith (NoPin.lookupHash q.hashes) encode q

end NoPin.Held
