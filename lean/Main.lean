import Singular.Driver
open Singular
open Singular.Driver
open Lean

/-! The generic registry-mode corpus: every R2 edge accepted, the full
complement of R2 refused with its observable reason, the codec both ways, the
read bound to the intermediate root, custody and R-ADA value flow, the mint
check and the zero-request rule. Expectations are authored from the mandate;
results are computed from the model. -/

/-- The open application's policy id. It is unparameterised: one policy id, one
blueprint, no applied hash to derive, and therefore no cross-registry
separation to promise. -/
def openPolicyHash : Nat := 7

def cfg : Config :=
  { root := rootOf [], maxFee := 1, processTime := 2, retractTime := 3
  , applicationPolicy := openPolicyHash, activePolicy := 8, absentPolicy := 9
  , terminalPolicy := 10 }

def s0 : RegistryState := { config := cfg, trie := [], custody := [], held := [] }

def apFor (e : Edge) (k o d : Nat) : Option Approval :=
  some { policy := openPolicyHash, edge := e, key := k, owner := o, destination := d
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
  before : RegistryState
  action : Request
  actual : Except String Result

def runCase (id : String) (accept : Bool) (reason : String) (s : RegistryState)
    (r : Request) : Case :=
  { id := id, expectedAccept := accept, expectedReason := reason
  , before := s, action := r, actual := step s r }

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
  let activeNoToken : RegistryState :=
    { (booked s0 42) with held := [] }
  [ runCase "GC01-update-active-without-custody" false "custody-missing"
      absentNoCustody (req .updateActive 42 42 555)
  , runCase "GC02-delete-absent-without-custody" false "custody-missing"
      absentNoCustody (req .deleteAbsent 42 91 0)
  , runCase "GC03-update-active-with-custody" true "" (witnessed s0 42)
      (req .updateActive 42 42 555)
  , runCase "GC04-delete-absent-with-custody" true "" (witnessed s0 42)
      (req .deleteAbsent 42 91 0)
  , runCase "GC05-update-terminal-without-token" false "token-missing"
      activeNoToken (req .updateTerminal 42 42 555)
  , runCase "GC06-delete-active-without-token" false "token-missing"
      activeNoToken (req .deleteActive 42 42 555)
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
/-- Each codec row carries the bytes it decodes, so a consumer replays the row
rather than trusting its verdict. -/
def codecInputs : List (String × Bool × List Nat) :=
  [ ("GC01-decode-absent", true, [0])
  , ("GC02-decode-active", true, [1])
  , ("GC03-decode-terminal", true, [2])
  , ("GC04-decode-03-refused", false, [3])
  , ("GC05-decode-empty-refused", false, [])
  , ("GC06-decode-naming-era-refused", false, [104, 101, 108, 108, 111])
  , ("GC07-decode-two-bytes-refused", false, [0, 1]) ]

def codecRows : List (String × Bool × Option State × List Nat) :=
  codecInputs.map fun (id, expected, bytes) =>
    (id, expected, decodeState (bytes.map (fun n => (n.toUInt8))).toByteArray, bytes)

def configRow : Bool :=
  match (fromJson? (toJson cfg) : Except String Config) with
  | .ok c => c == cfg
  | .error _ => false

/-! ### T1 — the `insertActive` transaction row and the keyed mint rows (#173)

Every field of the rows below is read off a fold this file executes or off the
model definition `Singular.Statements.insert_active_transaction_row` and
`Singular.Statements.fold_batch_claimed_mint_by_kind_key` constrain. The two
statement identities are the compiled ones; the coverage suite reconciles them
against `lean/theorem-debt.json`, so a statement edited without re-exporting the
manifest detaches the row from its proof and is caught there. -/

def transactionRowTheorem : String := "Singular.Statements.insert_active_transaction_row"
def transactionRowStatement : String :=
  "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
def keyedMintTheorem : String := "Singular.Statements.fold_batch_claimed_mint_by_kind_key"
def keyedMintStatement : String :=
  "9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988"

/-- The lovelace the request input carries, above the registry's tip ceiling. -/
def txLovelace : Nat := 5

/-- The request this row folds: one `insertActive` at key 42 routed to output
555, claiming exactly the active token it mints. -/
def txRequest : Request :=
  { req .insertActive 42 42 555 with claimed := [(.active, 1)] }

def txResult : Except String Result := step s0 txRequest

/-- A second `insertActive` at the same key, folded against the state the first
produced. -/
def txSecond : Except String Result :=
  match txResult with
  | .ok r => step r.state txRequest
  | .error why => .error why

def txSecondReason : String :=
  match txSecond with | .ok _ => "" | .error why => why

/-- A second registry pinning the same open policy and differing in every other
field it may differ in: the frame in which cross-registry separation is observed
to be absent. -/
def otherRegistry : Config :=
  { cfg with maxFee := 9, processTime := 20, retractTime := 30
           , activePolicy := 80, absentPolicy := 90, terminalPolicy := 100 }

/-- The transaction this row is about, built by the model from the executed
step. -/
def txBuilt : Except String Tx := txOf s0 txRequest txLovelace

def transactionRowJson : Json :=
  match txBuilt, txResult, txSecond with
  | .ok tx, .ok r, .error why =>
    Json.mkObj
      [ ("profile", "insertActive")
      , ("accepted", toJson true)
      , ("theorem", toJson transactionRowTheorem)
      , ("statementSha256", toJson transactionRowStatement)
      , ("applicationPolicy", toJson cfg.applicationPolicy)
      , ("openPolicy", Json.mkObj
          [ ("hash", toJson openPolicyHash)
          , ("parameters", toJson openPolicyParameters)
          , ("admitsAnyTuple", toJson (openAdmitsEveryTuple cfg))
          , ("crossRegistrySeparation",
              toJson (crossRegistrySeparation cfg otherRegistry txRequest)) ])
      , ("transaction", txJson cfg tx)
      , ("tip", toJson cfg.maxFee)
      , ("lovelaceCoversTip", toJson (lovelaceCoversTip cfg txLovelace))
      , ("claimed", assetsJson cfg (requestClaim txRequest))
      , ("onlyRootChanges", toJson (onlyRootChanged cfg r.state.config
          && r.state.config.root == rootOf r.state.trie))
      , ("destinationDatumBinds", toJson (destinationDatumBinds txRequest))
      , ("activeQuantity", toJson (kindCount r.state .active txRequest.key))
      , ("secondInsert", Json.mkObj [("accepted", toJson false), ("reason", toJson why)]) ]
  | _, _, _ => Json.mkObj [("profile", "insertActive"), ("accepted", toJson false)]

/-- An insertion from genesis with a refund address different from the key. -/
def absentRequest : Request :=
  { req .insertAbsent 42 91 0 with refundAddress := 91, deposit := 200, claimed := [(.absent, 1)] }

def absentResult : Except String Result := step s0 absentRequest

def absentTx : Except String Tx := txOf s0 absentRequest txLovelace

def absentRowTheorem : String := "Singular.Statements.insert_absent_transaction_row"
def absentRowStatement : String := "cbe444a5bddadef89cba2f1459a597a010531e396a90be4a798fdccc5633fb46"

/-- Check the constructed value independently of its constructors, so changing
those constructors cannot silently change the exported expectations. -/
def absentTxCorrect : Bool :=
  match absentTx, absentResult with
  | .ok tx, .ok t =>
    tx ==
      { inputs :=
          [ { role := .state, datum := .inline, stateTokens := 1, approvals := 0, lovelace := 0 }
          , { role := .request, datum := .inline, stateTokens := 0, approvals := 1
            , lovelace := txLovelace } ]
      , outputs :=
          [ { role := .state, datum := .inline, address := none, stateTokens := 1
            , config := some t.state.config, commitment := none, assets := [] }
          , { role := .destination, datum := .inline, address := some 0, stateTokens := 0
            , config := none, commitment := some (approvalAssetName .insertAbsent 42 91 0)
            , assets := [] }
          , { role := .cage, datum := .inline, address := some 0, stateTokens := 0
            , config := none, commitment := none, assets := [((.absent, 42), 1)]
            , custodyDatum := some [91], lovelace := 200 } ]
      , mint := [((.absent, 42), 1)], signers := [], refunds := [] } &&
    (tx.outputs.filter (fun o => o.role == .cage)).map custodyKey == [some 42] &&
    t.state.trie == trieSet s0.trie 42 (.known .absent) &&
    onlyRootChanged cfg t.state.config && t.state.config.root == rootOf t.state.trie &&
    t.state.custody == [{ key := 42, refundAddress := 91, value := 200 }] &&
    t.state.held == [] && custodyCount t.state 42 == 1 &&
    lovelaceCoversTip cfg txLovelace && destinationDatumBinds absentRequest
  | _, _ => false

def absentRowJson : Json :=
  match absentTx, absentResult with
  | .ok tx, .ok t => Json.mkObj
      [ ("profile", "insertAbsent"), ("accepted", toJson absentTxCorrect)
      , ("theorem", toJson absentRowTheorem), ("statementSha256", toJson absentRowStatement)
      , ("request", toJson absentRequest), ("transaction", txJson cfg tx)
      , ("recoveredKeys", toJson ((tx.outputs.filter (fun o => o.role == .cage)).map custodyKey))
      , ("claimed", assetsJson cfg (requestClaim absentRequest))
      , ("onlyRootChanges", toJson (onlyRootChanged cfg t.state.config))
      , ("rootMatchesTrie", toJson (t.state.config.root == rootOf t.state.trie))
      , ("absentQuantity", toJson (custodyCount t.state 42))
      , ("lovelaceCoversTip", toJson (lovelaceCoversTip cfg txLovelace))
      , ("destinationDatumBinds", toJson (destinationDatumBinds absentRequest)) ]
  | _, _ => Json.mkObj [("profile", "insertAbsent"), ("accepted", toJson false)]

/-! ### T1 — the `updateTerminal` transaction row (#177)

Retirement is the first row in this corpus whose mint is negative, and a
negative mint is the one thing a transaction cannot simply assert: the token has
to be spent from somewhere. The state below is the one the accepted
`insertActive` produced, so the active witness this fold burns is the very token
that edge minted, and the verdicts read the built value rather than the logical
step. -/

def retirementRowTheorem : String := "Singular.Statements.update_terminal_transaction_row"
def retirementRowStatement : String :=
  "c85a4eb0a61907d71a0861658097e7ab839655023e39bfc4e11a8209553e31c2"

/-- The state an accepted `insertActive` at key 42 produced: the leaf reads
`Active` and its one active token is held at output 555. -/
def retireState : RegistryState := booked s0 42

/-- The retirement this row folds: `updateTerminal` at key 42, claiming exactly
the active token it burns. -/
def retireRequest : Request :=
  { req .updateTerminal 42 42 555 with claimed := [(.active, -1)] }

def retireResult : Except String Result := step retireState retireRequest

def retireTx : Except String Tx := txOf retireState retireRequest txLovelace

/-- The assets the built transaction destroys, read off its own mint rather than
off the edge — a row that counted the edge's delta would agree with itself. -/
def retireBurned : List (Asset × Int) :=
  match retireTx with
  | .ok tx => tx.mint.filter (fun p => p.2 < 0)
  | .error _ => []

/-- The tokens the built transaction's inputs bring in. -/
def retireSpent : List (Asset × Int) :=
  match retireTx with
  | .ok tx => tx.inputs.flatMap (·.assets)
  | .error _ => []

/-- Every burned asset is spent by an input, at the same `(kind, key)` and the
same quantity: the burn's source, stated over the whole mint rather than over
the one token this edge happens to destroy. -/
def retireBurnSourced : Bool :=
  !retireBurned.isEmpty && retireBurned.all fun p =>
    assetKind retireSpent p.1 == -p.2

/-- No output is left holding a quantity an output cannot hold. -/
def retireOutputsPositive : Bool :=
  match retireTx with
  | .ok tx => tx.outputs.all fun o => o.assets.all fun p => 0 < p.2
  | .error _ => false

/-- The same retirement request folded from a state whose leaf for key 42 is
elsewhere in its life, or whose active token is gone: the refusals, observed at
the transaction the consumer would have to build. -/
def retireRefusal (s : RegistryState) : String :=
  match txOf s retireRequest txLovelace with
  | .ok _ => "" | .error why => why

def retireWithoutToken : RegistryState := { retireState with held := [] }

def retirementRefusalRows : List (String × String × RegistryState) :=
  [ ("GT01-update-terminal-unknown-refused", "key-unknown", s0)
  , ("GT02-update-terminal-absent-refused", "not-booked", witnessed s0 42)
  , ("GT03-update-terminal-terminal-refused", "terminal-immutable", retiredState)
  , ("GT04-update-terminal-without-token-refused", "token-missing", retireWithoutToken) ]

def retirementRowJson : Json :=
  match retireTx, retireResult with
  | .ok tx, .ok r =>
    Json.mkObj
      [ ("profile", "updateTerminal")
      , ("accepted", toJson true)
      , ("theorem", toJson retirementRowTheorem)
      , ("statementSha256", toJson retirementRowStatement)
      , ("applicationPolicy", toJson cfg.applicationPolicy)
      , ("transaction", txJson cfg tx)
      , ("tip", toJson cfg.maxFee)
      , ("lovelaceCoversTip", toJson (lovelaceCoversTip cfg txLovelace))
      , ("claimed", assetsJson cfg (requestClaim retireRequest))
      , ("burned", assetsJson cfg retireBurned)
      , ("spentByInputs", assetsJson cfg retireSpent)
      , ("burnSourced", toJson retireBurnSourced)
      , ("outputsHoldOnlyPositiveQuantities", toJson retireOutputsPositive)
      , ("onlyRootChanges", toJson (onlyRootChanged cfg r.state.config
          && r.state.config.root == rootOf r.state.trie))
      , ("leafAfter", leafJson (trieGet r.state.trie retireRequest.key))
      , ("destinationDatumBinds", toJson (destinationDatumBinds retireRequest))
      , ("activeQuantityBefore", toJson (kindCount retireState .active retireRequest.key))
      , ("activeQuantityAfter", toJson (kindCount r.state .active retireRequest.key))
      , ("refusals", Json.arr ((retirementRefusalRows.map fun row =>
          Json.mkObj [("id", toJson row.1), ("accepted", toJson false),
            ("reason", toJson (retireRefusal row.2.2))]).toArray)) ]
  | _, _ => Json.mkObj [("profile", "updateTerminal"), ("accepted", toJson false)]

/-- Two booking requests at two distinct keys, each claiming its own token: the
accepted row at `n > 1` keys. -/
def keyedAccepted : List Request :=
  [ { req .insertActive 5 42 555 with claimed := [(.active, 1)] }
  , { req .insertActive 6 42 555 with claimed := [(.active, 1)] } ]

/-- The same two keys and the same per-kind total, at the wrong key: the first
request claims both active tokens and the second claims none. A per-kind guard
accepts this batch; the keyed guard refuses it. -/
def keyedWrongKey : List Request :=
  [ { req .insertActive 5 42 555 with claimed := [(.active, 2)] }
  , { req .insertActive 6 42 555 with claimed := [] } ]

def foldReason (v : Except String Result) : String :=
  match v with | .ok _ => "" | .error why => why

def keyedMintRowJson (id : String) (batch : List Request) : Json :=
  let verdict := foldBatch s0 batch
  let applied := match foldActions s0 batch with | .ok _ => true | .error _ => false
  Json.mkObj
    [ ("id", id)
    , ("requestsApplied", toJson applied)
    , ("perKindTotalsAgree", toJson
        ([TokenKind.active, .absent, .terminal].all fun k =>
          assetKindTotal (claimedMint batch) k == assetKindTotal (actualMint batch) k))
    , ("theorem", toJson keyedMintTheorem)
    , ("statementSha256", toJson keyedMintStatement)
    , ("accepted", toJson (match verdict with | .ok _ => true | .error _ => false))
    , ("reason", toJson (foldReason verdict))
    , ("claimed", assetsJson cfg (claimedMint batch))
    , ("actual", assetsJson cfg (actualMint batch)) ]

def tokenPoliciesJson : Json :=
  Json.mkObj
    [ ("active", toJson (kindPolicy cfg .active))
    , ("absent", toJson (kindPolicy cfg .absent))
    , ("terminal", toJson (kindPolicy cfg .terminal)) ]

/-- A deleted key is a non-member. Each row deletes key 42 from a registry that
stored it, alone or beside key 8, and names the registry the same requests build
without key 42. Both sides are computed by the model; nothing is typed. -/
def deletionRows : List (String × Except String Result × RegistryState) :=
  [ ("deleteAbsent of the only key",
      step (witnessed s0 42) (req .deleteAbsent 42 91 0), s0)
  , ("deleteAbsent beside another key",
      step (witnessed (witnessed s0 8) 42) (req .deleteAbsent 42 91 0), witnessed s0 8)
  , ("deleteActive of the only key",
      step (booked s0 42) (req .deleteActive 42 42 0), s0)
  , ("deleteActive beside another key",
      step (booked (booked s0 8) 42) (req .deleteActive 42 42 0), booked s0 8) ]

/-- What a deletion row violates: a stored `unknown` leaf, a registry other than
the one that never stored the key, a lookup other than `unknown`, or a later
`updateTerminal` of the key refused for a reason other than `key-unknown`. -/
def deletionFailures : List String :=
  deletionRows.flatMap fun (name, result, never) =>
    match result with
    | .error why => [s!"{name}: refused {why}"]
    | .ok t =>
      (if t.state.trie.all (fun p => p.2 != .unknown) then []
       else [s!"{name}: trie stores an unknown leaf {repr t.state.trie}"]) ++
      (if t.state.trie == never.trie then []
       else [s!"{name}: trie {repr t.state.trie} != {repr never.trie}"]) ++
      (if t.state.config.root == never.config.root then []
       else [s!"{name}: root {repr t.state.config.root.toList} != {repr never.config.root.toList}"]) ++
      (if t.state == never then []
       else [s!"{name}: registry differs from the one that never stored the key"]) ++
      (if trieGet t.state.trie 42 == .unknown then []
       else [s!"{name}: lookup of the deleted key is {repr (trieGet t.state.trie 42)}"]) ++
      (match step t.state (req .updateTerminal 42 42 555) with
       | .error "key-unknown" => []
       | .error why => [s!"{name}: updateTerminal after deletion refused {why}"]
       | .ok _ => [s!"{name}: updateTerminal after deletion accepted"])

def cases : List Case := [accInsertAbsent, accInsertActive, accUpdateActive,
  accUpdateTerminal, accDeleteAbsent, accDeleteActive, accWitnessTerminal] ++ refusals ++ readRows ++ custodyRows

def caseJson (c : Case) : Json :=
  Json.mkObj [("id", toJson c.id), ("status", toJson c.status),
    ("expectedAccept", toJson c.expectedAccept),
    ("expectedReason", toJson c.expectedReason),
    ("before", toJson c.before), ("action", toJson c.action),
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
  for (id, expectSome, res, _) in codecRows do
    let ok := if expectSome then res.isSome else res.isNone
    unless ok do throw (IO.userError s!"{id} failed")
  unless configRow do throw (IO.userError "GD-config roundtrip failed")
  -- T1: the transaction row and the keyed mint rows are verdicts, not claims
  unless (match txResult with | .ok _ => true | .error _ => false) do
    throw (IO.userError "T1 insertActive transaction was refused")
  unless (match txBuilt with | .ok _ => true | .error _ => false) do
    throw (IO.userError "T1 the model built no transaction for an admitted insertActive")
  unless txSecondReason == "key-exists" do
    throw (IO.userError s!"T1 second insertActive: {txSecondReason}")
  unless approvalsIn txRequest == 1 do throw (IO.userError "T1 approval count")
  unless lovelaceCoversTip cfg txLovelace do throw (IO.userError "T1 tip not covered")
  unless destinationDatumBinds txRequest do throw (IO.userError "T1 destination datum")
  unless openAdmitsEveryTuple cfg do throw (IO.userError "T1 open policy admission")
  unless !crossRegistrySeparation cfg otherRegistry txRequest do
    throw (IO.userError "T1 cross-registry separation is a non-goal, not a promise")
  unless (match foldActions s0 keyedWrongKey with | .ok _ => true | .error _ => false) do
    throw (IO.userError "T1 wrong-key batch: a request failed to apply, so the refusal is not the keyed guard's")
  unless foldReason (foldBatch s0 keyedAccepted) == "" do
    throw (IO.userError "T1 keyed accepted row refused")
  unless foldReason (foldBatch s0 keyedWrongKey) == "net-mint-mismatch" do
    throw (IO.userError s!"T1 wrong-key row: {foldReason (foldBatch s0 keyedWrongKey)}")
  unless absentTxCorrect do
    throw (IO.userError "T1 insertAbsent constructed transaction violates refund-only custody row")
  -- #177: the transaction an admitted updateTerminal builds is a verdict too
  unless (match retireResult with | .ok _ => true | .error _ => false) do
    throw (IO.userError "T1 updateTerminal was refused at a booked key")
  unless (match retireTx with | .ok _ => true | .error _ => false) do
    throw (IO.userError "T1 the model built no transaction for an admitted updateTerminal")
  unless retireBurnSourced do
    throw (IO.userError s!"T1 updateTerminal burns {repr retireBurned} and its inputs spend {repr retireSpent}: the burn has no source")
  unless retireOutputsPositive do
    throw (IO.userError "T1 updateTerminal: an output is left holding a quantity an output cannot hold")
  unless (match retireTx with | .ok tx => tx.refunds.isEmpty && tx.signers.isEmpty | .error _ => false) do
    throw (IO.userError "T1 updateTerminal: refunds or required signers are not empty")
  for (id, expected, before) in retirementRefusalRows do
    unless retireRefusal before == expected do
      throw (IO.userError s!"{id}: {retireRefusal before} (expected {expected})")
  unless deletionFailures.isEmpty do
    throw (IO.userError s!"deletion keeps the key: {deletionFailures}")
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
    , ("tokenPolicies", tokenPoliciesJson)
    , ("transactions", Json.arr #[transactionRowJson, absentRowJson, retirementRowJson])
    , ("keyedMintRows", Json.arr
        #[ keyedMintRowJson "GK01-two-keys-accepted" keyedAccepted
         , keyedMintRowJson "GK02-same-kind-wrong-key-refused" keyedWrongKey ])
    , ("model", toJson cfg) ]
  stdout.putStrLn json.compress
