import Main.Base

/-! Registration, retirement and keyed-mint transaction fixtures. -/

open Singular
open Singular.Driver
open Lean

/-! ### transaction-correspondence — the `insertActive` transaction row and the keyed mint rows (#173)

Every field of the rows below is read off a fold this file executes or off the
model definition `Singular.Statements.insert_active_transaction_row` and
`Singular.Statements.fold_batch_claimed_mint_by_kind_key` constrain. The two
statement identities are the compiled ones; the coverage suite reconciles them
against `lean/theorem-debt.json`, so a statement edited without re-exporting the
manifest detaches the row from its proof and is caught there. -/

def transactionRowTheorem : String := "Singular.Statements.insert_active_transaction_row"
def transactionRowStatement : String :=
  "6073c296c90657ef193368669ef07ce6d97eddaa9d2059771e23fe156b61b868"
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
def retirementRowTheorem : String := "Singular.Statements.update_terminal_transaction_row"
def retirementRowStatement : String :=
  "d2402d0c08b3df1258ddf354ef7e4855ceec1dae5f1fe763e0f0189aacb0b560"

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
  , ("GT02-update-terminal-absent-refused", "not-booked", legacyAbsent s0 42)
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

/-- The signature sets each admitted fold is folded again with: one signer, and
two signatures from different keys. -/
def signatureSets : List (List (List Nat)) := [[[1]], [[2], [3, 4]]]

/-- The fold of one accepted case, with an approval to sign. `witnessTerminal`
needs none, so its request is given a stray one — admitted all the same — or
changing the signature set would change nothing and exhibit nothing. -/
def signedAction (c : Case) : Request :=
  match c.action.approval with
  | some _ => c.action
  | none => { c.action with approval := apFor c.action.edge c.action.key c.action.owner
                                          (requestDestination c.action) }

def sameTx : Except String Tx → Except String Tx → Bool
  | .ok a, .ok b => a == b
  | .error x, .error y => x == y
  | _, _ => false

def sameStep : Except String Result → Except String Result → Bool
  | .ok a, .ok b => a == b
  | .error x, .error y => x == y
  | _, _ => false

/-- What an accepted edge violates of `fold_requires_no_signer`: the model built
no transaction for the admitted fold, the transaction requires a signer, the
signature set did not change the request, or the step or the transaction moved
with it. One row per edge, all seven. -/
def signerFailures : List String :=
  [accInsertActive, accUpdateTerminal].flatMap fun c =>
    let r := signedAction c
    match txOf c.before r txLovelace with
    | .error why => [s!"{c.id}: the model built no transaction ({why})"]
    | .ok tx =>
      (if tx.signers.isEmpty then [] else [s!"{c.id}: requires signers {tx.signers}"]) ++
      signatureSets.flatMap fun sigs =>
        let signed := withSignatures r sigs
        (if signed == r then [s!"{c.id}: signatures {sigs} left the request unchanged"] else []) ++
        (if sameStep (step c.before signed) (step c.before r) then []
         else [s!"{c.id}: the step moved with signatures {sigs}"]) ++
        (if sameTx (txOf c.before signed txLovelace) (txOf c.before r txLovelace) then []
         else [s!"{c.id}: the transaction moved with signatures {sigs}"])


def cases : List Case := [accInsertActive, accUpdateTerminal] ++ refusals ++ readRows ++ custodyRows

def caseJson (c : Case) : Json :=
  Json.mkObj [("id", toJson c.id), ("status", toJson c.status),
    ("expectedAccept", toJson c.expectedAccept),
    ("expectedReason", toJson c.expectedReason),
    ("before", toJson c.before), ("action", toJson c.action),
    ("result", match c.actual with
      | .ok r => Json.mkObj [("accepted", toJson true), ("state", toJson r.state)]
      | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)])]
