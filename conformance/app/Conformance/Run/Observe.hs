{- |
Module      : Conformance.Run.Observe
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Observe (outAssets, txScriptWitnesses, txInTxIdHex, txInIndex, stateMarkerOf, requestMarkerOf, requestDatumOf, storyField, extractState, outCoin, submittedAtDatum, redeemerPlutusDatas, spendingConstrs, mintConstrs, requestActionConstrs, proofStepConstrs, forkNeighborsWellFormed, adaOnlyOut, refScriptSize, carriesRefScript, mergeAssets, rawAssets) where


import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (Value (..))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Plutus.Data (Data (..))

import Cardano.Ledger.Api.Tx (
    bodyTxL,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out (
    referenceScriptTxOutL,
    coinTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (..),
    TxIx (..),
 )
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (
    eraProtVerLow,
    extractHash,
    hashScript,
 )
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PolicyID (..),
    TokenId (..),
    TxOut,
 )
import Singular.Registry.TxBuilder.Internal (
    extractCageDatum,
    mkRequestScript,
    scriptHashBytes,
 )
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRequest (..),
    OnChainTokenState (..),
 )
import PlutusCore.Data qualified as PLC

import Conformance.Mirror (
    failWith,
    hex,
 )

{- | One output's assets as the authenticator sees them:
policy-id bytes @->@ asset-name bytes @->@ quantity.
-}
outAssets :: TxOut ConwayEra -> Map.Map ByteString (Map.Map ByteString Integer)
outAssets o = case o ^. valueTxOutL of
    MaryValue _ (MultiAsset ma) ->
        Map.fromList
            [
                ( scriptHashBytes (policyID pid)
                , Map.fromList
                    [ (SBS.fromShort (assetNameBytes an), q)
                    | (an, q) <- Map.toList qs
                    ]
                )
            | (pid, qs) <- Map.toList ma
            ]


{- | The no-script-execution detector: the parts of a transaction
that can only exist because a script executed. CA05's forged payment
must be empty under it, and the boot tx — which carried the state
script — must not be, proving the detector can fire.
-}
txScriptWitnesses :: ConwayTx -> [String]
txScriptWitnesses tx =
    [ "script witness"
    | not (Map.null (tx ^. witsTxL . scriptTxWitsL))
    ]
        <> ["redeemers" | redeemersEmpty tx]
        <> ["mint" | mintEmpty tx]
  where
    redeemersEmpty t = case t ^. witsTxL . rdmrsTxWitsL of
        Redeemers m -> not (Map.null m)
    mintEmpty t = case t ^. bodyTxL . mintTxBodyL of
        MultiAsset ma -> not (Map.null ma)


txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hex (hashToBytes (extractHash h))


txInIndex :: TxIn -> Integer
txInIndex (TxIn _ (TxIx i)) = toInteger i


-- | The state script's refusal marker (applied hash hex).
stateMarkerOf :: CageConfig -> String
stateMarkerOf cfg = hex (scriptHashBytes (cfgScriptHash cfg))


-- | The request script's refusal marker for one cage (applied hash hex).
requestMarkerOf :: CageConfig -> TokenId -> String
requestMarkerOf cfg tid =
    hex (scriptHashBytes (hashScript (mkRequestScript cfg tid)))


{- | Request datum's (key, edge) and submitted-at, read from a
live request UTxO.
-}
requestDatumOf :: TxOut ConwayEra -> ((ByteString, Edge), Integer)
requestDatumOf out = case extractCageDatum out of
    Just (RequestDatum rq) ->
        ((requestKey rq, requestEdge rq), requestSubmittedAt rq)
    _ -> error "requestDatumOf: not a request UTxO"


storyField :: T.Text -> Value -> IO Value
storyField name value = case value of
    Object fields -> maybe (failWith ("model response omits " <> T.unpack name)) pure
        (KM.lookup (Key.fromText name) fields)
    _ -> failWith "model response is not an object"


extractState :: TxOut ConwayEra -> IO OnChainTokenState
extractState out = case extractCageDatum out of
    Just (StateDatum s) -> pure s
    _ -> failWith "hand-build: state output has no StateDatum"


-- | Lovelace in an output, era-pinned for the polymorphic lenses.
outCoin :: TxOut ConwayEra -> Integer
outCoin o = let Coin c = o ^. coinTxOutL in c


{- | A request output's submitted-at (ms), from its live datum.
-}
submittedAtDatum :: TxOut ConwayEra -> IO Integer
submittedAtDatum out = case extractCageDatum out of
    Just (RequestDatum rq) -> pure (requestSubmittedAt rq)
    _ -> failWith "deadline: request output has no RequestDatum"


-- ---------------------------------------------------------
-- CS03-CS07: redeemer inspection + remaining rows
-- ---------------------------------------------------------

redeemerPlutusDatas :: ConwayTx -> [PLC.Data]
redeemerPlutusDatas tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [plc | (Data plc, _) <- Map.elems m]


spendingConstrs :: ConwayTx -> [Integer]
spendingConstrs tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [ix | (ConwaySpending _, (Data (PLC.Constr ix _), _)) <- Map.toList m]


mintConstrs :: ConwayTx -> [Integer]
mintConstrs tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [ix | (ConwayMinting _, (Data (PLC.Constr ix _), _)) <- Map.toList m]


requestActionConstrs :: ConwayTx -> [Integer]
requestActionConstrs tx = concatMap fromDatum (redeemerPlutusDatas tx)
  where
    fromDatum (PLC.Constr 2 [PLC.List actions]) = concatMap fromAction actions
    fromDatum _ = []
    fromAction (PLC.Constr ix _) = [ix]
    fromAction _ = []


-- | `ProofStep` indices inside `Update` actions (0 `Branch`, 1 `Fork`,
-- 2 `Leaf`), read from the transaction supplied to the node.
proofStepConstrs :: ConwayTx -> [Integer]
proofStepConstrs tx = concatMap fromDatum (redeemerPlutusDatas tx)
  where
    fromDatum (PLC.Constr 2 [PLC.List actions]) = concatMap fromAction actions
    fromDatum _ = []
    fromAction (PLC.Constr 0 [PLC.List steps]) = concatMap fromStep steps
    fromAction _ = []
    fromStep (PLC.Constr ix _) = [ix]
    fromStep _ = []


-- | Every `Fork` step in the tx carries a well-formed 3-field
-- `Neighbor`. Companion to `proofStepConstrs`.
forkNeighborsWellFormed :: ConwayTx -> Bool
forkNeighborsWellFormed tx = all fromDatum (redeemerPlutusDatas tx)
  where
    fromDatum (PLC.Constr 2 [PLC.List actions]) = all fromAction actions
    fromDatum _ = True
    fromAction (PLC.Constr 0 [PLC.List steps]) = all fromStep steps
    fromAction _ = True
    fromStep (PLC.Constr 1 [_, PLC.Constr 0 [_, _, _]]) = True
    fromStep (PLC.Constr 1 _) = False
    fromStep _ = True


{- | Can this output fund a transaction? It must hold ada and nothing
else, because it doubles as collateral, and it must not be one of the
published reference outputs, because a transaction may not both spend an
output and reference it.
-}
adaOnlyOut :: TxOut ConwayEra -> Bool
adaOnlyOut out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && (case out ^. referenceScriptTxOutL of SNothing -> True; SJust _ -> False)


-- | The serialised size of the reference script an output carries.
refScriptSize :: TxOut ConwayEra -> Int
refScriptSize out = case out ^. referenceScriptTxOutL of
    SNothing -> 0
    SJust s -> fromIntegral (BSL.length (serialize (eraProtVerLow @ConwayEra) s))


carriesRefScript :: TxOut ConwayEra -> Bool
carriesRefScript out = case out ^. referenceScriptTxOutL of
    SNothing -> False
    SJust _ -> True


mergeAssets ::
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    Map.Map PolicyID (Map.Map AssetName Integer)
mergeAssets = Map.unionWith (Map.unionWith (+))


-- | The multi-asset an output carries, in the ledger's own shape.
rawAssets :: TxOut ConwayEra -> Map.Map PolicyID (Map.Map AssetName Integer)
rawAssets out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) -> m
