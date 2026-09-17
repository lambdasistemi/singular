import Singular.Model
open Singular
open Lean

/-! The generic registry-mode corpus: every R2 edge accepted, the full
complement of R2 refused with its observable reason, the codec both ways, the
read bound to the intermediate root, custody and R-ADA value flow, the mint
check and the zero-request rule. Expectations are authored from the mandate;
results are computed from the model. -/

def cfg : Config :=
  { root := rootOf [], maxFee := 1, processTime := 2, retractTime := 3
  , applicationPolicy := 7, activePolicy := 8, absentPolicy := 9, terminalPolicy := 10 }

def s0 : RegistryState := { config := cfg, trie := [], custody := [], held := [] }

def apFor (e : Edge) (k o d : Nat) : Option Approval :=
  some { policy := 7, edge := e, key := k, owner := o, destination := d
       , assetName := approvalAssetName e k o d }

/-- A canonical booked key: known active, one active token at output 555. -/
def booked (s : RegistryState) (k : Nat) : RegistryState :=
  match step s ({ edge := .insertActive, key := k, owner := 42, output := 555
                , approval := apFor .insertActive k 42 555 } : Request) with
  | .ok r => r.state
  | .error _ => s

/-- A canonical witnessed-absent key: known absent, custody with refund 91 and
value 200 named by the witness. -/
def witnessed (s : RegistryState) (k : Nat) : RegistryState :=
  match step s ({ edge := .insertAbsent, key := k, owner := 91, refundAddress := 91
                , deposit := 200, approval := apFor .insertAbsent k 91 0 } : Request) with
  | .ok r => r.state
  | .error _ => s

def req (e : Edge) (k : Nat) (owner : Nat) (out : Nat) : Request :=
  let target : Request := { edge := e, key := k, owner := owner, output := out }
  { edge := e, key := k, owner := owner, output := out
  , approval := apFor e k owner (requestDestination target) }

structure Case where
  id : String
  status : String := "modeled"
  expectedAccept : Bool
  expectedReason : String := ""
  actual : Except String Result

def runCase (id : String) (accept : Bool) (reason : String) (s : RegistryState)
    (r : Request) : Case :=
  { id := id, expectedAccept := accept, expectedReason := reason
  , actual := step s r }

def caseActualString (c : Case) : String :=
  match c.actual with
  | .ok _ => s!"accepted(expected={c.expectedAccept})"
  | .error e => s!"refused:{e}(expectedAccept={c.expectedAccept},reason={c.expectedReason})"

def correct (c : Case) : Bool :=
  match c.actual with
  | .ok _ => c.expectedAccept
  | .error e => !c.expectedAccept && e == c.expectedReason

/-- A canonical retired key: known terminal (booked then retired). -/
def retiredState : RegistryState :=
  match step (booked s0 42) (req .updateTerminal 42 42 555) with
  | .ok r => r.state | .error _ => s0

-- accepted edges (one per R2 row, with its delta observed in the result)
def accInsertAbsent : Case :=
  runCase "GA01-insert-absent-accepted" true "" (witnessed s0 7)
    (req .insertAbsent 8 91 0)
def accInsertActive : Case :=
  runCase "GA02-insert-active-accepted" true "" s0 (req .insertActive 42 42 555)
def accUpdateActive : Case :=
  runCase "GA03-update-active-accepted" true "" (witnessed s0 42)
    (req .updateActive 42 42 555)
def accUpdateTerminal : Case :=
  runCase "GA04-update-terminal-accepted" true "" (booked s0 42)
    (req .updateTerminal 42 42 555)
def accDeleteAbsent : Case :=
  runCase "GA05-delete-absent-accepted" true "" (witnessed s0 42)
    (req .deleteAbsent 42 91 0)
def accDeleteActive : Case :=
  runCase "GA06-delete-active-accepted" true "" (booked s0 42)
    (req .deleteActive 42 42 0)
def accWitnessTerminal : Case :=
  runCase "GA07-witness-terminal-accepted" true "" retiredState
    ({ edge := .witnessTerminal, key := 42, output := 700 } : Request)

-- R3 complement refusals: every non-R2 (edge, before) pair
def refusals : List Case :=
  let taken := booked s0 42            -- known active
  let retired := match step (booked s0 42) (req .updateTerminal 42 42 555) with
    | .ok r => r.state | .error _ => taken -- known terminal
  let absent := witnessed s0 42        -- known absent
  [ runCase "GR01-insert-absent-on-active" false "key-exists" taken (req .insertAbsent 42 91 0)
  , runCase "GR02-insert-active-on-active" false "key-exists" taken (req .insertActive 42 42 555)
  , runCase "GR03-insert-absent-on-terminal" false "key-exists" retired (req .insertAbsent 42 91 0)
  , runCase "GR04-insert-active-on-terminal" false "key-exists" retired (req .insertActive 42 42 555)
  , runCase "GR05-insert-active-on-absent" false "key-exists" absent (req .insertActive 42 42 555)
  , runCase "GR06-update-active-on-unknown" false "key-unknown" s0 (req .updateActive 42 42 555)
  , runCase "GR07-update-active-on-active" false "already-booked" taken (req .updateActive 42 42 555)
  , runCase "GR08-update-active-on-terminal" false "terminal-immutable" retired
      (req .updateActive 42 42 555)
  , runCase "GR09-update-terminal-on-unknown" false "key-unknown" s0 (req .updateTerminal 42 42 555)
  , runCase "GR10-update-terminal-on-absent" false "not-booked" absent (req .updateTerminal 42 42 555)
  , runCase "GR11-update-terminal-on-terminal" false "terminal-immutable" retired
      (req .updateTerminal 42 42 555)
  , runCase "GR12-delete-absent-on-unknown" false "key-unknown" s0 (req .deleteAbsent 42 91 0)
  , runCase "GR13-delete-absent-on-active" false "not-absent" taken (req .deleteAbsent 42 91 0)
  , runCase "GR14-delete-absent-on-terminal" false "terminal-immutable" retired
      (req .deleteAbsent 42 91 0)
  , runCase "GR15-delete-active-on-unknown" false "key-unknown" s0 (req .deleteActive 42 42 0)
  , runCase "GR16-delete-active-on-absent" false "not-active" absent (req .deleteActive 42 42 0)
  , runCase "GR17-delete-active-on-terminal" false "terminal-immutable" retired
      (req .deleteActive 42 42 0)
  , runCase "GR18-read-active-refused" false "read-active" taken
      (req .witnessTerminal 42 0 700)
  , runCase "GR19-read-absent-refused" false "read-absent" absent
      (req .witnessTerminal 42 0 700)
  , runCase "GR20-read-unknown-refused" false "read-unknown" s0
      (req .witnessTerminal 42 0 700)
  , runCase "GR21-insert-absent-no-approval" false "no-approval" s0
      ({ edge := .insertAbsent, key := 42, owner := 91, refundAddress := 91, deposit := 200 } : Request)
  , runCase "GR22-insert-active-other-policy" false "no-approval" s0
      ({ edge := .insertActive, key := 42, owner := 42, output := 555, approval := some ({ policy := 8, edge := .insertActive, key := 42, owner := 42, destination := 555, assetName := approvalAssetName .insertActive 42 42 555 } : Approval) } : Request)
  , runCase "GR23-insert-active-mismatched-tuple" false "approval-mismatch" s0
      ({ edge := .insertActive, key := 42, owner := 42, output := 555, approval := some ({ policy := 7, edge := .insertActive, key := 43, owner := 42, destination := 555, assetName := approvalAssetName .insertActive 43 42 555 } : Approval) } : Request)]

-- the read-position controls
def readRows : List Case :=
  [ runCase "GD01-read-terminal-accepted" true "" retiredState
      ({ edge := .witnessTerminal, key := 42, output := 700 } : Request)
  , runCase "GD02-read-before-establishing" false "read-unknown" s0
      ({ edge := .witnessTerminal, key := 42, output := 700 } : Request)
  ]

-- GC: the custody census (D-CUST). An absent token lives in the cage's own
-- custody, so the two edges that consume one are refused when it is missing
-- even though the leaf says absent, and the census is exactly the outstanding
-- absent tokens.
def custodyRows : List Case :=
  let absentNoCustody : RegistryState :=
    { (witnessed s0 42) with custody := [] }
  [ runCase "GC01-update-active-without-custody" false "custody-missing"
      absentNoCustody (req .updateActive 42 42 555)
  , runCase "GC02-delete-absent-without-custody" false "custody-missing"
      absentNoCustody (req .deleteAbsent 42 91 0)
  , runCase "GC03-update-active-with-custody" true "" (witnessed s0 42)
      (req .updateActive 42 42 555)
  , runCase "GC04-delete-absent-with-custody" true "" (witnessed s0 42)
      (req .deleteAbsent 42 91 0)
  ]

-- fold-level rows: zero batch, mint mismatch, read inside batch at position
def foldRows : List (String × Bool × String) :=
  [ ("GF01-empty-fold-refused", false, "empty-fold")
  , ("GF02-batch-accepted", true, "")
  , ("GF03-mint-mismatch-refused", false, "net-mint-mismatch") ]

def batchOk : Bool :=
  match foldBatch s0
    [ { edge := .insertAbsent, key := 5, owner := 91, refundAddress := 91, deposit := 50
      , approval := apFor .insertAbsent 5 91 0, claimed := [(.absent, 1)] }
    , { edge := .updateActive, key := 5, owner := 42, output := 555
      , approval := apFor .updateActive 5 42 555, claimed := [(.absent, -1), (.active, 1)] } ] with
  | .ok _ => true | .error _ => false

def batchEmpty : Option String :=
  match foldBatch s0 [] with
  | .error e => some e | .ok _ => none

def batchMint : Option String :=
  match foldBatch s0
    [ { edge := .insertAbsent, key := 5, owner := 91, refundAddress := 91, deposit := 50
      , approval := apFor .insertAbsent 5 91 0, claimed := [(.absent, 2)] } ] with
  | .error e => some e | .ok _ => none

-- R-ADA value flow: the inserter (91) is paid, not the consumer's output
def adaRows : List (String × Bool × (List (Nat × Nat))) :=
  [ ("GAda-update-active-pays-refund", true,
      match step (witnessed s0 42) (req .updateActive 42 42 555) with
      | .ok r => r.paid | .error _ => [])
  , ("GAda-delete-absent-pays-refund", true,
      match step (witnessed s0 42) (req .deleteAbsent 42 91 0) with
      | .ok r => r.paid | .error _ => []) ]

-- codec rows
def codecRows : List (String × Bool × Option State) :=
  [ ("GC01-decode-absent", true, decodeState [0].toByteArray)
  , ("GC02-decode-active", true, decodeState [1].toByteArray)
  , ("GC03-decode-terminal", true, decodeState [2].toByteArray)
  , ("GC04-decode-03-refused", false, decodeState [3].toByteArray)
  , ("GC05-decode-empty-refused" , false, decodeState [].toByteArray)
  , ("GC06-decode-naming-era-refused" , false,
      decodeState (ByteArray.mk #[(104 : UInt8), 101, 108, 108, 111]))
  , ("GC07-decode-two-bytes-refused" , false, decodeState [0, 1].toByteArray) ]

def configRow : Bool :=
  match (fromJson? (toJson cfg) : Except String Config) with
  | .ok c => c == cfg
  | .error _ => false

def cases : List Case := [accInsertAbsent, accInsertActive, accUpdateActive,
  accUpdateTerminal, accDeleteAbsent, accDeleteActive, accWitnessTerminal] ++ refusals ++ readRows ++ custodyRows

def caseJson (c : Case) : Json :=
  Json.mkObj [("id", toJson c.id), ("status", toJson c.status),
    ("expectedAccept", toJson c.expectedAccept),
    ("expectedReason", toJson c.expectedReason),
    ("result", match c.actual with
      | .ok r => Json.mkObj [("accepted", toJson true), ("state", toJson r.state)]
      | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)])]

def main : IO Unit := do
  let stdout ← IO.getStdout
  for c in cases do
    unless correct c do
      throw (IO.userError s!"scenario expectation failed: {c.id}: {caseActualString c}")
  unless batchOk do throw (IO.userError "GF02 batch-accepted failed")
  unless batchEmpty == some "empty-fold" do throw (IO.userError "GF01 empty-fold failed")
  unless batchMint == some "net-mint-mismatch" do throw (IO.userError "GF03 mint failed")
  for (id, expectNonEmpty, paid) in adaRows do
    let ok := if expectNonEmpty then !paid.isEmpty && paid.all (fun p => p.1 == 91) else paid.isEmpty
    unless ok do throw (IO.userError s!"{id}: {repr paid}")
  for (id, expectSome, res) in codecRows do
    let ok := if expectSome then res.isSome else res.isNone
    unless ok do throw (IO.userError s!"{id} failed")
  unless configRow do throw (IO.userError "GD-config roundtrip failed")
  unless batchEmpty.isSome && batchMint.isSome do throw (IO.userError "fold rows failed")
  let foldJson := foldRows.map fun p =>
    Json.mkObj [("id", p.1), ("ok", p.2.1), ("reason", p.2.2),
      ("verified", Json.mkObj [("empty", batchEmpty == some "empty-fold"),
        ("batch", batchOk), ("mint", batchMint == some "net-mint-mismatch")])]
  let adaJson := adaRows.map fun p =>
    Json.mkObj [("id", p.1), ("paidTo", toJson ((p.2.2).map (·.1)))]
  let codecJson := codecRows.map fun p =>
    Json.mkObj [("id", p.1), ("decodes", p.2.2.isSome), ("expectedDecodes", p.2.1)]
  let json := Json.mkObj
    [ ("schema", toJson "singular-logical-corpus-v2")
    , ("cases", toJson (cases.map caseJson))
    , ("folds", toJson foldJson)
    , ("ada", toJson adaJson)
    , ("codec", toJson codecJson)
    , ("configRoundtrip", toJson configRow)
    , ("model", toJson cfg) ]
  stdout.putStrLn json.compress
