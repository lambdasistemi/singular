import Singular.Model.Routing
import Singular.Model.Payments

/-! Executed exits, transaction construction and the public fold builder. -/

namespace Singular
open Lean

/-- One exit as a model step. A fold of edge `e` is exactly `step` when the
request names `e`, and is refused `exit-edge-mismatch` otherwise. A reject or a
retract carries no admission here: it leaves the registry state as it was and
mints nothing; a retraction's admission stands in front of this step, in
`admittedExitStep`. Every exit pays what it owes, each payment recorded by
`paymentPaid`; supported registry steps create no additional custody refunds. -/
def exitStep (state : RegistryState) (exit : Exit) (request : Request) : Except String Result :=
  let executed : Except String Result :=
    match exit with
    | .fold e => if request.edge == e then step state request else .error "exit-edge-mismatch"
    | .reject | .retract => .ok (emptyResult state)
  match executed with
  | .error why => .error why
  | .ok t => .ok { t with paid := (obligations exit request).map paymentPaid ++ t.paid }

/-- One owner output per owner payment, at the owner's key, carrying the
payment's floor: presenting its datum in `datum` and naming `commitment`, or, for
a return bound to a request, an inline datum presenting that request's reference
and returning nothing else. -/
def ownerOutputs (datum : DatumForm) (commitment : Option Nat) (payments : List Payment) :
    List TxOutput :=
  payments.filterMap fun payment =>
    match payment.recipient with
    | .owner key =>
      some { role := .owner, datum := datum, address := some key, stateTokens := 0
           , config := none, commitment := commitment, assets := []
           , lovelace := payment.atLeast }
    | .bound key reference =>
      some { role := .owner, datum := .inline, address := some key, stateTokens := 0
           , config := none, commitment := Option.none, assets := []
           , lovelace := payment.atLeast, reference := some reference }
    | _ => Option.none

/-- The transaction an exit builds, or the model's refusal. A fold's spends the
registry's state and the request, and the tokens its mint destroys; it moves the
state, delivers to the destination the request names, locks custody when its edge
routes a token there, and pays the owner one output per owner payment: an
output with no datum that returns the request's approval, so it names that
approval's asset name as its commitment. A reject is settled inside a
transaction that spends the registry's state and returns it unchanged, beside the
request it spends, and refunds the owner as a fold delivering nothing does, with
no datum and the request's approval; it requires no signer. A retract is its own
transaction, spending only the request, returning everything it held through one
output whose inline datum is the request's own reference, and requiring the
owner's signature, as the chain does (refusing a retract without it is admission,
`retractAdmission`, checked in front of this builder by `admittedTxOfExit`). Every
output that pays a recipient carries the lovelace the exit owes it — the destination output its summed destination floor, the cage
output the deposit — and the transaction refunds exactly what the exit pays. -/
def txOfExit (state : RegistryState) (exit : Exit) (request : Request) (lovelace : Nat) :
    Except String Tx :=
  match exitStep state exit request with
  | .error why => .error why
  | .ok t =>
    let owed := obligations exit request
    let requestInput : TxInput :=
      { role := .request, datum := registryDatumForm
      , stateTokens := 0, approvals := approvalsIn request, lovelace := lovelace }
    let stateInput : TxInput :=
      { role := .state, datum := registryDatumForm
      , stateTokens := registryStateTokens, approvals := 0, lovelace := 0 }
    match exit with
    | .fold _ =>
      let destinationFloor := owedTo (.destination (requestDestination request) request.datum) owed
      .ok { inputs := [stateInput, requestInput] ++ txBurnInputs state t request
          , outputs := txStateOutput t
              :: (txDestinationOutputs t request).map
                  (fun o => { o with lovelace := destinationFloor })
              ++ ownerOutputs .none (request.approval.map (·.assetName)) owed
          , mint := t.mint
          , signers := requiredSigners request
          , refunds := t.paid }
    | .reject =>
      .ok { inputs := [stateInput, requestInput]
          , outputs := txStateOutput t
              :: ownerOutputs .none (request.approval.map (·.assetName)) owed
          , mint := t.mint, signers := [], refunds := t.paid }
    | .retract =>
      .ok { inputs := [requestInput], outputs := ownerOutputs .inline Option.none owed
          , mint := t.mint, signers := [request.owner], refunds := t.paid }

/-- The transaction an admitted single-request fold builds, or the model's own
refusal: the transaction of the fold exit the request names. -/
def txOf (s : RegistryState) (r : Request) (lovelace : Nat) : Except String Tx :=
  txOfExit s (.fold r.edge) r lovelace

/-! ### What a folder reads

A folder builds a fold from what the chain shows and nothing else: the registry
state its outputs commit to, with every holding and the datum its output carries,
and the requests pending at the cage, each carrying its datum. No booker's file
is an input. -/

/-- The public view of a registry: the state as its outputs show it, the holdings
among it with their datums, and the pending requests as they sit at the cage. It
has no other field. -/
structure PublicView where
  registry : RegistryState
  pending : List Request

/-- The public view of a state and the requests pending against it. -/
def publicView (s : RegistryState) (pending : List Request) : PublicView :=
  { registry := s, pending := pending }

/-- The fold any party builds from a public view: the transaction of the pending
request sitting at `reference`, or a refusal when no pending request sits there. -/
def buildFold (view : PublicView) (reference : Nat) (lovelace : Nat) : Except String Tx :=
  match view.pending.find? (·.reference == reference) with
  | some r => txOf view.registry r lovelace
  | none => .error "request-not-pending"


end Singular
