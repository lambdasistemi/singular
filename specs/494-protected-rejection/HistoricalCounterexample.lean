import Singular.Model

/-! Historical behavior at 6efe1f119a2332484e690b4c128c4bc5fd4d689b.
This is evidence of the defect, not the desired rejection specification.
Run against that revision with Lean 4.25.0 after `lake build Singular.Model`:
  lake env lean --run specs/494-protected-rejection/HistoricalCounterexample.lean
The old model has no fold-time admission. The supplied finite interval records
the concrete live-request story but does not establish a ledger time check.
-/

namespace ProtectedRejectionHistorical
open Singular

def initial : RegistryState :=
  { config := { root := rootOf [], maxFee := 100, processTime := 1000,
                retractTime := 500, applicationPolicy := 1, activePolicy := 2,
                absentPolicy := 3, terminalPolicy := 4 }
    trie := [], custody := [], held := [] }

def request : Request :=
  { edge := .insertActive, key := 5, owner := 42, output := 99,
    deposit := 2000000, tip := 1000000, reference := 7,
    claimed := delta .insertActive,
    approval := some
      { policy := 1, edge := .insertActive, key := 5,
        owner := 42, destination := 99,
        assetName := approvalAssetName .insertActive 5 42 99 } }

def witness : RetractWitness :=
  { submittedAt := 10000, validFrom := 10001, validTo := 10002,
    signatories := [] }

def counterexample : Bool :=
  refusal initial request == none &&
  witness.submittedAt ≤ witness.validFrom &&
  witness.validFrom < witness.validTo &&
  witness.validTo ≤ witness.submittedAt + initial.config.processTime &&
  match admittedExitStep initial (.fold request.edge) request witness,
        admittedExitStep initial .reject request witness,
        admittedTxOfExit initial .reject request witness (request.deposit + request.tip) with
  | .ok folded, .ok rejected, .ok tx =>
      trieGet folded.state.trie request.key == .known .active &&
      rejected.state == initial && rejected.mint == [] &&
      rejected.paid == [(request.owner, request.deposit)] &&
      tx.signers == [] &&
      exitRefusal initial.config .reject request witness tx.inputs tx.outputs == none &&
      (tx.inputs.map (·.lovelace)).foldl (· + ·) 0 -
        (tx.outputs.map (·.lovelace)).foldl (· + ·) 0 == request.tip
  | _, _, _ => false

end ProtectedRejectionHistorical

def main : IO Unit := do
  unless ProtectedRejectionHistorical.counterexample do
    throw (IO.userError "Historical unguarded-rejection counterexample did not reproduce")
  IO.println "REPRODUCED: foldable insertion rejected without signers; state unchanged; deposit refunded; tip remains outside modeled outputs."
  IO.println "LIMIT: model evidence only; no ledger fees, submission, or compiled-validator execution."
