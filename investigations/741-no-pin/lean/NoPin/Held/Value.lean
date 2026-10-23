import NoPin.Held.Model

/-! Hypothetical value partition under #741, not accepted law. Protected
application deposits are disjoint from the root's exact termination contents.
This is an explicit projection debt, not an assertion that the root observes
an unprojected physical output or that either transaction is ledger accepted. -/

namespace NoPin.Held
open Singular Lean

/-- Hypothesis under #741, not accepted law; physical output observation. -/
structure PhysicalOutput where
  index : Nat
  address : Option Nat
  lovelace : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; deposit slices are explicit by output index. -/
structure PhysicalView where
  inputs : List (OutRef × Nat)
  outputs : List PhysicalOutput
  allocations : List (Nat × Nat)
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; all released deposits owed to one key. -/
def controllerDeposit (ps : List Pending) (controller : Nat) : Nat :=
  ((ps.filter fun p => p.holding.control.controller == controller).map
    (·.holding.control.deposit)).sum
/-- Hypothesis under #741, not accepted law; deposit physically added at this input. -/
def inputDeposit (ps : List Pending) (ref : OutRef) : Nat :=
  ((ps.filter fun p => p.holding.reference == ref).map (·.holding.control.deposit)).sum
/-- Hypothesis under #741, not accepted law; sum repeated slice identities rather than losing one. -/
def allocated (v : PhysicalView) (index : Nat) : Nat :=
  ((v.allocations.filter fun a => a.1 == index).map (·.2)).sum
/-- Hypothesis under #741, not accepted law; actual selected economic inputs. -/
def economicInputs (o : FoldObservation) : List (OutRef × Nat) :=
  o.transaction.transaction.inputs.filterMap fun input => input.ref.bind fun ref =>
    (economicLookup o.unspent ref).map fun output => (ref, output.output.lovelace)
/-- Hypothesis under #741, not accepted law; value partition, not a second economic fold. -/
def valuePartitionWith (m : Mutation) (ps : List Pending) (o : FoldObservation) (v : PhysicalView) : Bool :=
  applyGuard m .partitionInputs (v.inputs == (economicInputs o).map (fun p => (p.1, p.2 + inputDeposit ps p.1))) &&
  applyGuard m .partitionOutputs (v.outputs == o.transaction.outputs.zipIdx.map (fun (out, index) =>
    PhysicalOutput.mk index out.output.address (out.output.lovelace + allocated v index))) &&
  applyGuard m .partitionDistinct (decide (v.allocations.map Prod.fst).Nodup) &&
  applyGuard m .partitionIndices (v.allocations.all (fun a => a.1 < v.outputs.length)) &&
  applyGuard m .partitionController (ps.all (fun p =>
    ((v.outputs.filter fun out => out.address == some p.holding.control.controller).map
      (fun out => allocated v out.index)).sum == controllerDeposit ps p.holding.control.controller))
/-- Hypothesis under #741, not accepted law; unmutated value partition. -/
def valuePartition (ps : List Pending) (o : FoldObservation) (v : PhysicalView) : Bool :=
  valuePartitionWith .none ps o v
/-- Hypothesis under #741, not accepted law; observed physical lovelace conservation. -/
def physicalBalanced (o : FoldObservation) (v : PhysicalView) : Bool :=
  (v.inputs.map Prod.snd).sum == (v.outputs.map (·.lovelace)).sum +
    o.transaction.transaction.fee + o.transaction.transaction.donation
/-- Hypothesis under #741, not accepted law; root outcome executed, never a typed acceptance bit. -/
def acceptedFold (o : FoldObservation) : Bool :=
  match foldAccepted o.before o.unspent o.transaction with
  | .ok after => after == o.after
  | .error _ => false
/-- Hypothesis under #741, not accepted law; build a mathematical fold from public pending data.
The unchanged foldBatch and foldAccepted remain its decision owners. -/
def canonicalResult (s : ApplicationState) (ps : List Pending) : Result :=
  let world := project s
  let members := ps.map (fun p => FoldMember.termination p.booking)
  (foldBatch (foldProjectedRegistry world)
    (members.map (foldLegacyRequest world.registry.config))).toOption.getD
      (emptyResult (foldProjectedRegistry world))

/-- Hypothesis under #741, not accepted law; actual economic transaction producer. -/
def canonicalTransaction (s : ApplicationState) (ps : List Pending) (time funding fee : Nat) : EconomicTransaction :=
  let world := project s
  let members := ps.map (fun p => FoldMember.termination p.booking)
  let result := canonicalResult s ps
  let controllers := (ps.map (·.holding.control.controller)).eraseDups
  let outputs := [foldWitnessState result.state.config,
    foldWitnessOrdinary (funding + (foldObligations members).tips - fee)] ++
      controllers.map (fun controller => { foldWitnessOrdinary 0 with
        output := { (foldWitnessOrdinary 0).output with address := some controller } })
  {
    transaction := {
      inputs := ps.map (fun p => foldWitnessInput p.booking.request.reference) ++
        [foldWitnessInput ⟨terminationWitnessFresh world, 0⟩,
         foldWitnessInput ⟨terminationWitnessFresh world, 1⟩],
      outputs := outputs.map (·.output), mint := [], signers := [], refunds := [],
      validity := some ⟨time, time + 1⟩, fee, donation := (foldObligations members).donation },
    identity := terminationWitnessFresh world + 1, outputs,
    trieReadyMint := (ps.flatMap (·.booking.request.contents.trieReadyTags)).map (fun tag => (tag, -1)),
    applicationMint := [], singularMint := foldMint world.registry.config members }

/-- Hypothesis under #741, not accepted law; execute the unchanged fold observation. -/
def canonicalFold (s : ApplicationState) (ps : List Pending) (time funding fee : Nat) : FoldObservation :=
  let world := project s
  let result := canonicalResult s ps
  let transaction := canonicalTransaction s ps time funding fee
  { registryIdentity := s.registryIdentity, before := world, after := foldEffect world transaction result,
    unspent := terminationWitnessUnspent world funding, transaction }
/-- Hypothesis under #741, not accepted law; construct the disjoint physical deposit slice. -/
def canonicalPhysical (ps : List Pending) (o : FoldObservation) : PhysicalView :=
  let controllers := (ps.map (·.holding.control.controller)).eraseDups
  let allocations := controllers.zipIdx.map fun (controller, index) =>
    (index + 2, controllerDeposit ps controller)
  let base : PhysicalView := {
    inputs := (economicInputs o).map (fun p => (p.1, p.2 + inputDeposit ps p.1)),
    outputs := [], allocations }
  { base with outputs := o.transaction.outputs.zipIdx.map fun (out, index) =>
      ⟨index, out.output.address, out.output.lovelace + allocated base index⟩ }
/-- Hypothesis under #741, not accepted law; concrete-to-root asset mapping remains debt. -/
def canonicalAssetView (registry : TokenId) (ps : List Pending) (o : FoldObservation) : TxView :=
  { spent := o.transaction.transaction.inputs.filterMap (·.ref),
    outputs := o.transaction.outputs.map (fun out =>
      ⟨if out.output.stateTokens == 0 then [] else [(registry, out.output.stateTokens)]⟩),
    mint := ps.map (fun p => (p.holding.token, -1)), invoked := [registry.policy] }
/-- Hypothesis under #741, not accepted law; local payment values obtained from physical outputs. -/
def canonicalLocal (registry : TokenId) (ps : List Pending) (o : FoldObservation)
    (v : PhysicalView) : LocalTransaction :=
  { assets := canonicalAssetView registry ps o, spent := ps,
    payments := v.outputs.filterMap fun out => out.address.map fun controller =>
      ⟨out.index, controller, out.lovelace⟩ }
/-- Hypothesis under #741, not accepted law; composed observation, not ledger acceptance. -/
def composedWith (m : Mutation) (hash : Hash) (code : Codec) (registry : TokenId) (ps : List Pending)
    (o : FoldObservation) (v : PhysicalView) : Bool :=
  applyGuard m .composedEconomic (acceptedFold o) &&
  applyGuard m .composedPartition (valuePartition ps o v) &&
  applyGuard m .composedBalance (physicalBalanced o v) &&
  applyGuard m .composedLocal (ps.all (fun p => pendingRelease .none hash code o.before.registry.config p
      (canonicalLocal registry ps o v)))
/-- Hypothesis under #741, not accepted law; unmutated composition. -/
def composed := composedWith .none

end NoPin.Held
