import Singular.Model

/-! Transaction serialization shared by the driver and corpus. -/

namespace Singular.Driver
open Lean

/-! ## Serialization, promoted from the corpus producer -/

/-- One keyed asset, spelled with the on-chain identity the model pins: the
kind's policy and the asset name, which is the key. -/
def assetJson (c : Config) (p : Asset × Int) : Json :=
  Json.mkObj
    [ ("kind", toJson p.1.1), ("key", toJson p.1.2)
    , ("policy", toJson (kindPolicy c p.1.1))
    , ("assetName", toJson (tokenAssetName p.1.1 p.1.2))
    , ("quantity", toJson p.2) ]

def assetsJson (c : Config) (ds : List (Asset × Int)) : Json :=
  Json.arr ((ds.map (assetJson c)).toArray)

def txRoleName : TxRole → String
  | .state => "state" | .request => "request"
  | .destination => "destination" | .cage => "cage"
  | .witness => "witness" | .owner => "owner"

def txInputJson (c : Config) (i : TxInput) : Json :=
  Json.mkObj <|
    [ ("role", toJson (txRoleName i.role))
    , ("datum", toJson (datumFormName i.datum))
    , ("stateToken", toJson i.stateTokens)
    , ("approvalQuantity", toJson i.approvals)
    , ("lovelace", toJson i.lovelace)
    , ("assets", assetsJson c i.assets)
    , ("datumValue", datumJson i.datumValue) ] ++
    (i.ref.toList.map fun ref => ("ref", toJson ref)) ++
    (i.stateToken.toList.map fun token => ("stateTokenId", toJson token))

def txOutputJson (c : Config) (o : TxOutput) : Json :=
  Json.mkObj <|
    [ ("role", toJson (txRoleName o.role))
    , ("datum", toJson (datumFormName o.datum))
    , ("address", match o.address with | none => Json.null | some a => toJson a)
    , ("stateToken", toJson o.stateTokens)
    , ("inlineConfig", match o.config with | none => Json.null | some cfg => toJson cfg)
    , ("commitment", match o.commitment with | none => Json.null | some x => toJson x)
    , ("assets", assetsJson c o.assets)
    , ("custodyDatum", toJson o.custodyDatum)
    , ("lovelace", toJson o.lovelace)
    , ("reference", match o.reference with | none => Json.null | some x => toJson x)
    , ("datumValue", datumJson o.datumValue) ] ++
    (if o.stateToken == o.config.map Config.stateToken then [] else
      [("stateTokenId", toJson o.stateToken)])

/-- The built transaction, serialized. Every field comes from the `Tx` the model
constructed; nothing here is assembled beside it. -/
def txFields (c : Config) (tx : Tx) : List (String × Json) :=
    [ ("inputs", Json.arr ((tx.inputs.map (txInputJson c)).toArray))
    , ("outputs", Json.arr ((tx.outputs.map (txOutputJson c)).toArray))
    , ("mint", assetsJson c tx.mint)
    , ("signers", toJson tx.signers)
    , ("refunds", Json.arr ((tx.refunds.map fun p =>
        Json.mkObj [("address", toJson p.1), ("value", toJson p.2)]).toArray)) ] ++
    (if tx.referenceInputs.isEmpty then [] else
      [("referenceInputs", Json.arr ((tx.referenceInputs.map (txInputJson c)).toArray))]) ++
    (tx.validity.toList.map fun interval => ("validity", toJson interval)) ++
    (if tx.fee == 0 then [] else [("fee", toJson tx.fee)]) ++
    (if tx.donation == 0 then [] else [("donation", toJson tx.donation)])

def txJson (c : Config) (tx : Tx) : Json := Json.mkObj (txFields c tx)

/-- Missing extension fields read as their old defaults; a present malformed
field is an error rather than a default. -/
def defaultField [FromJson α] (j : Json) (name : String) (fallback : α) : Except String α :=
  match j.getObjVal? name with
  | .error _ => pure fallback
  | .ok value => fromJson? value

def txRoleOfJson (j : Json) : Except String TxRole := do
  let name : String ← fromJson? j
  match name with
  | "state" => pure .state | "request" => pure .request
  | "destination" => pure .destination | "cage" => pure .cage
  | "witness" => pure .witness | "owner" => pure .owner
  | _ => throw "unknown transaction role"

/-- Decode the registry-scoped assets and check the policy and asset name
against that registry, rather than silently accepting contradictory identities. -/
def assetsOfJson (c : Config) (j : Json) : Except String (List (Asset × Int)) := do
  let entries ← j.getArr?
  entries.toList.mapM fun entry => do
    let kind ← entry.getObjVal? "kind" >>= fromJson?
    let key ← entry.getObjVal? "key" >>= fromJson?
    let policy : Nat ← entry.getObjVal? "policy" >>= fromJson?
    let name : Nat ← entry.getObjVal? "assetName" >>= fromJson?
    let quantity ← entry.getObjVal? "quantity" >>= fromJson?
    unless policy == kindPolicy c kind && name == tokenAssetName kind key do
      throw "asset identity disagrees with registry"
    pure ((kind, key), quantity)

def txInputOfJson (c : Config) (j : Json) : Except String TxInput := do
  let role ← j.getObjVal? "role" >>= txRoleOfJson
  let datum ← j.getObjVal? "datum" >>= fromJson?
  let stateTokens ← j.getObjVal? "stateToken" >>= fromJson?
  let approvals ← j.getObjVal? "approvalQuantity" >>= fromJson?
  let lovelace ← j.getObjVal? "lovelace" >>= fromJson?
  let assets ← j.getObjVal? "assets" >>= assetsOfJson c
  let datumValue ← defaultField j "datumValue" none
  let ref ← defaultField j "ref" none
  let stateToken ← defaultField j "stateTokenId" none
  pure { role, datum, stateTokens, approvals, lovelace, assets, datumValue, ref, stateToken }

def txOutputOfJson (c : Config) (j : Json) : Except String TxOutput := do
  let role ← j.getObjVal? "role" >>= txRoleOfJson
  let datum ← j.getObjVal? "datum" >>= fromJson?
  let address ← j.getObjVal? "address" >>= fromJson?
  let stateTokens ← j.getObjVal? "stateToken" >>= fromJson?
  let config : Option Config ← j.getObjVal? "inlineConfig" >>= fromJson?
  let commitment ← j.getObjVal? "commitment" >>= fromJson?
  let assets ← j.getObjVal? "assets" >>= assetsOfJson c
  let custodyDatum ← defaultField j "custodyDatum" none
  let lovelace ← defaultField j "lovelace" 0
  let reference ← defaultField j "reference" none
  let datumValue ← defaultField j "datumValue" none
  let stateToken ← defaultField j "stateTokenId" (config.map Config.stateToken)
  pure { role, datum, address, stateTokens, config, commitment, assets
       , custodyDatum, lovelace, reference, datumValue, stateToken }

def txOfJson (c : Config) (j : Json) : Except String Tx := do
  let inputs ← (← (← j.getObjVal? "inputs").getArr?).toList.mapM (txInputOfJson c)
  let outputs ← (← (← j.getObjVal? "outputs").getArr?).toList.mapM (txOutputOfJson c)
  let mint ← j.getObjVal? "mint" >>= assetsOfJson c
  let signers ← j.getObjVal? "signers" >>= fromJson?
  let refunds ← (← (← j.getObjVal? "refunds").getArr?).toList.mapM fun entry => do
    let address ← entry.getObjVal? "address" >>= fromJson?
    let value ← entry.getObjVal? "value" >>= fromJson?
    pure (address, value)
  let references ← defaultField j "referenceInputs" ([] : List Json)
  let referenceInputs ← references.mapM (txInputOfJson c)
  let validity ← defaultField j "validity" none
  let fee ← defaultField j "fee" 0
  let donation ← defaultField j "donation" 0
  pure { inputs, outputs, mint, signers, refunds, referenceInputs, validity, fee, donation }

end Singular.Driver
