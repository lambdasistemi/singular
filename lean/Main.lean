import Main.Base
import Main.Transactions
import Main.Payments
import Main.Exits
import Main.Retraction
import Main.Economics
import Singular.Driver
import Singular.Economics
open Singular
open Singular.Driver
open Lean

/-! The generic registry-mode corpus: the two admitted edges and the excluded
wire tags refused with their observable reasons, the codec both ways, the
read bound to the intermediate root, custody and custody-lovelace-refund value flow, the mint
check and the zero-request rule. Expectations are authored from the mandate;
results are computed from the model. -/

def batchOk : Bool :=
  match foldBatch s0
    [ { req .insertActive 5 42 555 with claimed := [(.active, 1)] }
    , { req .insertActive 6 42 556 with claimed := [(.active, 1)] } ] with
  | .ok _ => true | .error _ => false

def main : IO Unit := do
  let stdout ← IO.getStdout
  match parameterPreservationControl with
  | .ok () => pure ()
  | .error reason => throw (IO.userError reason)
  unless parameterCodecControl do
    throw (IO.userError "economic parameter defaults, pins or roundtrip failed")
  for (story, correct) in stateIdentityControls do
    unless correct do throw (IO.userError s!"state token identity: {story}")
  for (story, correct) in economicControls do
    unless correct do throw (IO.userError s!"transaction vocabulary: {story}")
  for c in cases do
    unless correct c do
      throw (IO.userError s!"scenario expectation failed: {c.id}: {caseActualString c}")
  unless batchOk do throw (IO.userError "GF02 batch-accepted failed")
  unless batchEmpty == some "empty-fold" do throw (IO.userError "GF01 empty-fold failed")
  unless batchMint == some "net-mint-mismatch" do throw (IO.userError "GF03 mint failed")
  for (id, expectNonEmpty, paid) in adaRows do
    let ok := if expectNonEmpty then !paid.isEmpty && paid.all (fun p => p.1 == 91) else paid.isEmpty
    unless ok do throw (IO.userError s!"{id}: {repr paid}")
  for (id, expectSome, res, _) in codecRows do
    let ok := if expectSome then res.isSome else res.isNone
    unless ok do throw (IO.userError s!"{id} failed")
  unless configRow do throw (IO.userError "GD-config roundtrip failed")
  -- transaction-correspondence: the transaction row and the keyed mint rows are verdicts, not claims
  unless (match txResult with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence insertActive transaction was refused")
  unless (match txBuilt with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence the model built no transaction for an admitted insertActive")
  unless txSecondReason == "key-exists" do
    throw (IO.userError s!"Transaction correspondence second insertActive: {txSecondReason}")
  unless approvalsIn txRequest == 1 do throw (IO.userError "Transaction correspondence approval count")
  unless lovelaceCoversTip cfg txLovelace do throw (IO.userError "Transaction correspondence tip not covered")
  unless destinationDatumBinds txRequest do throw (IO.userError "Transaction correspondence destination datum")
  unless openAdmitsEveryTuple cfg do throw (IO.userError "Transaction correspondence open policy admission")
  unless !crossRegistrySeparation cfg otherRegistry txRequest do
    throw (IO.userError "Transaction correspondence cross-registry separation is a non-goal, not a promise")
  unless (match foldActions s0 keyedWrongKey with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence wrong-key batch: a request failed to apply, so the refusal is not the keyed guard's")
  unless foldReason (foldBatch s0 keyedAccepted) == "" do
    throw (IO.userError "Transaction correspondence keyed accepted row refused")
  unless foldReason (foldBatch s0 keyedWrongKey) == "net-mint-mismatch" do
    throw (IO.userError s!"Transaction correspondence wrong-key row: {foldReason (foldBatch s0 keyedWrongKey)}")
  -- #177: the transaction an admitted updateTerminal builds is a verdict too
  unless (match retireResult with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence updateTerminal was refused at a booked key")
  unless (match retireTx with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence the model built no transaction for an admitted updateTerminal")
  unless retireBurnSourced do
    throw (IO.userError s!"Transaction correspondence updateTerminal burns {repr retireBurned} and its inputs spend {repr retireSpent}: the burn has no source")
  unless retireOutputsPositive do
    throw (IO.userError "Transaction correspondence updateTerminal: an output is left holding a quantity an output cannot hold")
  unless (match retireTx with
      | .ok tx => tx.refunds == [(retireRequest.owner, retireRequest.deposit)] && tx.signers.isEmpty
      | .error _ => false) do
    throw (IO.userError "Transaction correspondence updateTerminal: refunds are not the deposit back to the owner, or a signer is required")
  for (id, expected, before) in retirementRefusalRows do
    unless retireRefusal before == expected do
      throw (IO.userError s!"{id}: {retireRefusal before} (expected {expected})")
  unless signerFailures.isEmpty do
    throw (IO.userError s!"a fold requires a signer: {signerFailures}")
  unless admissionFailures.isEmpty do
    throw (IO.userError s!"retraction admission: {admissionFailures}")
  unless admittedExitFailures.isEmpty do
    throw (IO.userError s!"admitted exit: {admittedExitFailures}")
  unless judgementFailures.isEmpty do
    throw (IO.userError s!"judgement: {judgementFailures}")
  unless leafByte .unknown == 0xFF do
    throw (IO.userError "the unknown lookup answer lost its 0xFF codec byte")
  unless batchEmpty.isSome && batchMint.isSome do throw (IO.userError "fold rows failed")
  let foldJson := foldRows.map fun p =>
    Json.mkObj [("id", p.1), ("ok", p.2.1), ("reason", p.2.2),
      ("verified", Json.mkObj [("empty", batchEmpty == some "empty-fold"),
        ("batch", batchOk), ("mint", batchMint == some "net-mint-mismatch")])]
  let adaJson := adaRows.map fun p =>
    Json.mkObj [("id", p.1), ("paidTo", toJson ((p.2.2).map (·.1)))]
  let codecJson := codecRows.map fun p =>
    Json.mkObj [("id", p.1), ("decodes", p.2.2.1.isSome), ("expectedDecodes", p.2.1),
      ("bytes", toJson p.2.2.2)]
  let json := Json.mkObj
    [ ("schema", toJson "singular-logical-corpus-v2")
    , ("cases", toJson (cases.map caseJson))
    , ("folds", toJson foldJson)
    , ("ada", toJson adaJson)
    , ("codec", toJson codecJson)
    , ("configRoundtrip", toJson configRow)
    , ("economicControls", toJson (economicControls.map fun (story, result) =>
        Json.mkObj [("story", toJson story), ("result", toJson result)]))
    , ("tokenPolicies", tokenPoliciesJson)
    , ("transactions", Json.arr #[transactionRowJson, retirementRowJson])
    , ("keyedMintRows", Json.arr
        #[ keyedMintRowJson "GK01-two-keys-accepted" keyedAccepted
         , keyedMintRowJson "GK02-same-kind-wrong-key-refused" keyedWrongKey ])
    , ("model", toJson cfg) ]
  stdout.putStrLn json.compress
