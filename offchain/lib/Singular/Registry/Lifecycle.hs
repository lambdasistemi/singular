{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Lifecycle
Description : Reserved funding views and execution limits
License     : Apache-2.0

A pure execution bound, and a session adapter withholding reserved
funding outputs. These helpers construct and submit no registry transaction.
-}
module Singular.Registry.Lifecycle
    ( fundingView
    , checkExecutionLimit
    ) where

import Cardano.Ledger.Api.Tx.Out
    ( referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (TxIn)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )

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
