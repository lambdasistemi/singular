import Main.RejectionReadsState

/-! Observed fold transactions built from real bookings. Values are illustrative.
The legacy fold computes the expected registry continuation only; it does not
stand in for the missing economic judgement. No builder is the test subject. -/

open Singular

namespace FoldControls

structure Control where
  story : String
  world : World
  unspent : EconomicUtxo
  transaction : EconomicTransaction
  expected : Option String := none
  sweep : Bool := false

/-- The producer reaches both active keys by actual registry steps, then books
registrations and a termination. A third distinct registration exercises sums. -/
def world : Except String World := do
  let w ← RejectionReadControls.world
  book w (RejectionReadControls.registration 9 3)

def ordinary (address lovelace : Nat) : EconomicOutput :=
  { output := { economicOutput lovelace with address := some address, assets := [] },
    contents := { lovelace, trieReadyTags := [], applicationTags := [] } }

def fundingReference : OutRef := ⟨74, 0⟩

def unspent (w : World) : EconomicUtxo :=
  let observed := RejectionReadControls.observedUnspent w (RejectionReadControls.unspent w)
  observed.map (fun (ref, o) =>
    if ref == RejectionReadControls.stateReference then
      (ref, { o with output.lovelace := 7, contents.lovelace := 7 })
    else (ref, o)) ++ [(fundingReference, ordinary 555 10)]

/-- Adapt the authenticated booking to the legacy registry request vocabulary.
Its old approval is only a mathematical adapter, never an observed economic
application tag or a claim that termination needs one. -/
def legacyRegistration (r : RegistrationRequest) : Request :=
  { req .insertActive r.key r.refundAddress r.destination with
    registryId := r.registryId, submittedAt := r.submittedAt,
    datum := r.datum, claimed := [(.active, 1)] }

def legacyTermination (r : TerminationRequest) : Request :=
  { req .updateTerminal r.key 0 r.destination with
    registryId := r.registryId, claimed := [(.active, -1)] }

def withOutputs (c : Control) (outputs : List EconomicOutput) : Control :=
  { c with transaction := { c.transaction with
      outputs,
      transaction.outputs := outputs.map (·.output) } }

def changeOrdinary (c : Control) (delta : Int) : Control :=
  withOutputs c (c.transaction.outputs.map fun o =>
    if o.output.stateTokens == 0 && o.singularTags.isEmpty then
      let amount := (Int.ofNat o.output.lovelace + delta).toNat
      { o with output.lovelace := amount, contents.lovelace := amount }
    else o)

def changeCarrier (c : Control) (delta : Int) : Control :=
  withOutputs c (c.transaction.outputs.map fun o =>
    if !o.singularTags.isEmpty then
      let amount := (Int.ofNat o.output.lovelace + delta).toNat
      { o with output.lovelace := amount, contents.lovelace := amount }
    else o)

/-- Each reference is looked up in the real pending pools. The carrier takes
its tag, datum, address and value from that booking, with no hardcoded identity.
The transaction has one ordinary funding input and separate ordinary change.
The input's lovelace claim deliberately disagrees with its observed value. -/
def lawful (w : World) (story : String) (refs : List OutRef) (time : Nat) :
    Except String Control := do
  let mut actions : List Request := []
  let mut restored : List Holding := []
  let mut destinations : List EconomicOutput := []
  let mut trieTags : List TokenId := []
  let mut applications : List TokenId := []
  let mut singularMint : List (SingularTag × Int) := []
  let mut donation := 0
  let mut tips := 0
  for ref in refs do
    match w.pending.find? (fun b => b.request.reference == ref) with
    | some b =>
      let r := b.request
      actions := actions ++ [legacyRegistration r]
      let destination : EconomicOutput :=
        { ordinary r.destination r.carrierAda with
          output := { (ordinary r.destination r.carrierAda).output with
            role := .destination, datum := datumFormOf r.datum, datumValue := r.datum },
          singularTags := [w.registry.config.singularTag r.key] }
      destinations := destinations ++ [destination]
      trieTags := trieTags ++ r.contents.trieReadyTags
      applications := applications ++ r.contents.applicationTags.map applicationTagIdentity
      singularMint := singularMint ++ [(w.registry.config.singularTag r.key, 1)]
      donation := donation + r.registrationCost
      tips := tips + r.declaredTip
    | none =>
      let some b := w.terminations.find? (fun b => b.request.reference == ref)
        | throw "control requested an absent pending reference"
      let r := b.request
      actions := actions ++ [legacyTermination r]
      restored := restored ++ b.custodyInputs
      trieTags := trieTags ++ r.contents.trieReadyTags
      singularMint := singularMint ++ r.singularTags.map (fun tag => (tag, -1))
      donation := donation + (r.contents.lovelace - r.declaredTip)
      tips := tips + r.declaredTip
  let result ← foldBatch { w.registry with held := w.registry.held ++ restored } actions
  let state : EconomicOutput :=
    { output := { RejectionReadControls.stateOutput w with
        config := some result.state.config, lovelace := 7 },
      contents := { lovelace := 7, trieReadyTags := [], applicationTags := [] } }
  let outputs := state :: destinations ++ [ordinary 555 (10 + tips - 1)]
  let tx : Tx :=
    { inputs := [RejectionReadControls.input RejectionReadControls.stateReference] ++
        refs.map RejectionReadControls.input ++ [economicInput fundingReference],
      outputs := outputs.map (·.output), mint := [], signers := [], refunds := [],
      validity := some ⟨time, time + 1⟩, fee := 1, donation }
  pure {
    story, world := w, unspent := unspent w,
    transaction := {
      transaction := tx, identity := 80, outputs,
      trieReadyMint := trieTags.map (fun tag => (tag, -1)),
      applicationMint := applications.map (fun tag => (tag, -1)), singularMint } }

/-- The adversarial observation changes the actual unspent request contents;
the real booked record remains fixed, so the fold must reject the substitution. -/
def changeApplication (c : Control) (tags : List Approval) : Control :=
  { c with unspent := c.unspent.map fun (ref, o) =>
    if ref == ({ tx := 71, index := 1 } : OutRef) then
      (ref, { o with contents.applicationTags := tags })
    else (ref, o) }

end FoldControls
