import Main.Base

/-! Economic parameters and transaction value controls. -/

open Singular
open Singular.Driver
open Lean

/-- Decode a configuration carrying nondefault economic parameters, fold a real
registration, then inspect the configuration the model writes. The values are
illustrative, not a choice of network parameters. -/
def parameterPreservationControl : Except String Unit := do
  let fields ← (toJson cfg).getObj?
  let parameters := [("registrationCost", toJson (17 : Nat)),
    ("minimumTip", toJson (3 : Nat)), ("bookingWidth", toJson (1 : Nat))]
  let input := Json.mkObj (fields.toList ++ parameters)
  let decoded ← (fromJson? input : Except String Config)
  let folded ← step { s0 with config := decoded } (req .insertActive 42 42 555)
  let written := toJson folded.state.config
  for (name, expected) in parameters do
    unless (match written.getObjVal? name with
      | .ok actual => actual == expected
      | .error _ => false) do
      throw s!"parameter preservation failed: {name}; supplied {expected.compress}; folded configuration {written.compress}"

/-- Absent fields retain their historical zero defaults. Each parameter is
independently pinned, and sizing is not imposed by the decoder. -/
def parameterCodecControl : Bool :=
  let fields := ["registrationCost", "minimumTip", "bookingWidth"]
  fields.all (fun name => match (toJson cfg).getObjVal? name with
    | .error _ => true | .ok _ => false) &&
  (match (fromJson? (toJson cfg) : Except String Config) with
    | .error _ => false
    | .ok old => old.registrationCost == 0 && old.minimumTip == 0 && old.bookingWidth == 0) &&
  [ { cfg with registrationCost := 17 }, { cfg with minimumTip := 3 },
    { cfg with bookingWidth := 100 } ].all (fun c =>
      !onlyRootChanged cfg c &&
      match (fromJson? (toJson c) : Except String Config) with
      | .ok back => back == c
      | .error _ => false)

/-- Values in these accounting scenarios are illustrative. Inputs deliberately
claim a value different from the unspent output, exposing trust in that claim. -/
def economicOutput (amount : Nat) : TxOutput :=
  { role := .owner, datum := .none, address := some 42, stateTokens := 0,
    config := none, commitment := none, assets := [((.active, 5), 1)], lovelace := amount }

def economicInput (ref : OutRef) : TxInput :=
  { role := .request, datum := .none, stateTokens := 0, approvals := 0,
    lovelace := 11, assets := [((.active, 5), 100)], ref := some ref }

def economicUnspent : Utxo :=
  [(⟨1, 0⟩, economicOutput 10), (⟨1, 1⟩, economicOutput 20)]

def economicTransaction : Tx :=
  { inputs := [economicInput ⟨1, 0⟩], outputs := [economicOutput 10],
    referenceInputs := [economicInput ⟨1, 1⟩], mint := [], signers := [], refunds := [] }

/-- A configured output's identity defaults to its own configuration, even
when the ambient registry differs. Explicit absence and foreign pairs survive
both the written form and the full output round trip. -/
def stateIdentityControls : List (String × Bool) := Id.run do
  let mut controls := []
  for c in [cfg, { cfg with registryId := cfg.registryId + 17 }] do
    let variants : List (String × Option TokenId × Option Json) :=
      [ ("default identity is omitted", some c.stateToken, none)
      , ("foreign name is explicit", some ⟨c.registryId, 1⟩,
          some (toJson ({ policy := c.registryId, name := 1 } : TokenId)))
      , ("foreign policy is explicit", some ⟨c.registryId + 1, 0⟩,
          some (toJson ({ policy := c.registryId + 1, name := 0 } : TokenId)))
      , ("missing identity is explicit null", none, some Json.null) ]
    for (story, token, expected) in variants do
      for count in [0, 1, 2] do
        let output :=
          { economicOutput 10 with config := some c, stateTokens := count, stateToken := token }
        let written := txOutputJson cfg output
        let fieldCorrect := match expected, written.getObjVal? "stateTokenId" with
          | none, .error _ => true
          | some value, .ok actual => actual == value
          | _, _ => false
        let roundTrip := match txOutputOfJson cfg written with
          | .ok back => back == output | .error _ => false
        controls := controls ++ [(story, fieldCorrect && roundTrip)]
    for token in [none, some c.stateToken] do
      let output := { economicOutput 10 with stateToken := token }
      let input := { economicInput ⟨1, 0⟩ with stateToken := token }
      let expected := token.map toJson
      for (story, written, roundTrip) in
          [("unconfigured output identity roundtrip", txOutputJson cfg output,
            match txOutputOfJson cfg (txOutputJson cfg output) with
              | .ok back => back == output | .error _ => false),
           ("input identity roundtrip", txInputJson cfg input,
            match txInputOfJson cfg (txInputJson cfg input) with
              | .ok back => back == input | .error _ => false)] do
        let fieldCorrect := match expected, written.getObjVal? "stateTokenId" with
          | none, .error _ => true
          | some value, .ok actual => actual == value
          | _, _ => false
        controls := controls ++ [(story, fieldCorrect && roundTrip)]
  return controls

def economicControls : List (String × Bool) :=
  let tx := economicTransaction
  let after := applyTx economicUnspent 2 tx
  let later := { tx with inputs := [economicInput ⟨1, 1⟩], referenceInputs := [economicInput ⟨1, 0⟩] }
  let state := { economicOutput 10 with stateTokens := 1, stateToken := some cfg.stateToken }
  let stateSet : Utxo := [(⟨1, 0⟩, state)]
  let stateTx := { tx with outputs := [state], referenceInputs := [] }
  let empty : Tx := { inputs := [], outputs := [], mint := [], signers := [], refunds := [] }
  [ ("a balanced transaction reads values from the unspent set", balanced economicUnspent tx)
  , ("a spent reference is refused as a reference", inputsPresent after later == some "reference-input-missing")
  , ("a missing spent input has its own reason", inputsPresent after tx == some "spent-input-missing")
  , ("reference inputs remain unspent", after.contains (⟨1, 1⟩, economicOutput 20))
  , ("new outputs receive their position", after.contains (⟨2, 0⟩, economicOutput 10))
  , ("inflation is refused despite the input claim", !balanced economicUnspent { tx with outputs := [economicOutput 11] })
  , ("deflation needs an explicit fee or donation", !balanced economicUnspent { tx with outputs := [economicOutput 9] })
  , ("fee and donation explain the difference", balanced economicUnspent { tx with outputs := [economicOutput 7], fee := 1, donation := 2 })
  , ("a native asset cannot be created without mint", !balanced economicUnspent { tx with outputs := [{ economicOutput 10 with assets := [((.active, 5), 2)] }] })
  , ("mint accounts for a native asset", balanced economicUnspent { tx with outputs := [{ economicOutput 10 with assets := [((.active, 5), 2)] }], mint := [((.active, 5), 1)] })
  , ("duplicate input claims cannot supply extra value", !balanced economicUnspent { tx with inputs := tx.inputs ++ tx.inputs, outputs := [economicOutput 20] })
  , ("the state token is conserved", balanced stateSet stateTx)
  , ("another state token name is refused", !balanced stateSet { stateTx with outputs := [{ state with stateToken := some ⟨cfg.registryId, 1⟩ }] })
  , ("another state token policy is refused", !balanced stateSet { stateTx with outputs := [{ state with stateToken := some ⟨cfg.registryId + 1, 0⟩ }] })
  , ("zero donation is omitted", !(Driver.txFields cfg empty).any (fun p => p.1 == "donation"))
  , ("positive donation is written", (Driver.txFields cfg { empty with donation := 2 }).contains ("donation", toJson (2 : Nat)))
  , ("old transaction defaults roundtrip", match txOfJson cfg (txJson cfg empty) with | .ok back => back == empty | .error _ => false)
  , ("all transaction extensions roundtrip", let full := { stateTx with validity := some ⟨2, 4⟩, fee := 1, donation := 2, referenceInputs := tx.referenceInputs }
      match txOfJson cfg (txJson cfg full) with | .ok back => back == full | .error _ => false)
  , ("the interval includes only its lower end", decide (({ lower := 2, upper := 4 } : Interval).contains 2) && !decide (({ lower := 2, upper := 4 } : Interval).contains 4)) ]
