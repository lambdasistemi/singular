{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Lifecycle
Description : Shared fee bounds, reserved funding views and execution limits
License     : Apache-2.0

Pure fee and execution bounds, and a session adapter withholding reserved
funding outputs. These helpers construct and submit no registry transaction.
-}
module Singular.Registry.Lifecycle
    ( protocolFeeReserve
    , fundingView
    , checkExecutionLimit
    ) where

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams
    ( ppMaxTxExUnitsL
    , ppMaxTxSizeL
    , ppTxFeePerByteL
    )
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (estimateMinFeeTx, mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (CoinPerByte (..))
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Tx.Balance (refScriptsSize)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import PlutusLedgerApi.V3 qualified as PLC
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams, TxIn)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )

{- | A funding allowance, not the fee charged: one maximum-size transaction,
the live aggregate execution limit, and the actual reference scripts.
Each submitted transaction is subsequently evaluated and balanced exactly.
-}
protocolFeeReserve
    :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> Coin
protocolFeeReserve pp refs =
    let dummy =
            mkBasicTx mkBasicTxBody
                & witsTxL . rdmrsTxWitsL
                    .~ Redeemers
                        ( Map.singleton
                            (ConwayMinting (AsIx 0))
                            (Data (PLC.Constr 0 []), pp ^. ppMaxTxExUnitsL)
                        )
        Coin measured =
            estimateMinFeeTx
                pp
                dummy
                2
                0
                (refScriptsSize (Set.fromList (map fst refs)) refs)
        CoinPerByte compactPerByte = pp ^. ppTxFeePerByteL
        Coin perByte = fromCompact compactPerByte
    in  Coin (measured + perByte * fromIntegral (pp ^. ppMaxTxSizeL))

-- | Keep request funding away from references and inputs reserved for later steps.
fundingView :: [TxIn] -> Session NoWitness IO -> Session NoWitness IO
fundingView reserved v =
    v
        { outputs = \query -> do
            result <- outputs v query
            pure $ case query of
                AtAddress _ -> fmap (\fact -> fact{value = filter available (value fact)}) result
                _ -> result
        }
  where
    available (i, out) =
        i `notElem` reserved
            && out ^. referenceScriptTxOutL == SNothing
            && ( let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
                 in  Map.null assets
               )

checkExecutionLimit :: ExUnits -> [ExUnits] -> Either String ExUnits
checkExecutionLimit (ExUnits maxMem maxSteps) costs =
    let total@(ExUnits mem steps) = foldl add (ExUnits 0 0) costs
        add (ExUnits a b) (ExUnits c d) = ExUnits (a + c) (b + d)
    in  if mem <= maxMem && steps <= maxSteps
            then Right total
            else
                Left
                    ( "lifecycle execution limit: requires memory="
                        <> show mem
                        <> ", steps="
                        <> show steps
                        <> "; live transaction limit memory="
                        <> show maxMem
                        <> ", steps="
                        <> show maxSteps
                    )
