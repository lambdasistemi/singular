{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Register
Description : Consumer stake-credential registration transaction
License     : Apache-2.0

Registers a script stake credential so a later withdrawal from it does
not fail on ledger for the wrong reason.

#157 removed-consumer-encoding: the consumer-registration builder is DELETED with the pinned
consumer it registered. There is no consumer script to register and no
mandatory withdrawal left to make possible, and a function that
registers nothing would be a trap for the next reader. What remains is
the generic credential registration the exhibit controls use directly;
it authorizes nothing by itself.
-}
module Singular.Registry.TxBuilder.Register
    ( registerScriptImpl
    ) where

import Cardano.Ledger.Api.Tx.Out (coinTxOutL, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Void (Void)
import Lens.Micro ((^.))

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Conway.Scripts
    ( ConwayPlutusPurpose (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))

import Cardano.Ledger.Address (Addr)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Provider (View (..))

-- | Empty query generalized algebraic data type (no context needed).
data NoCtx a

{- | Wrap the view's script evaluation for the story language (no scripts execute
here, but the story language still calls back through this interface).
-}
mkEvalTx
    :: View IO
    -> ConwayTx
    -> IO
        ( Map.Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
            (Either String ExUnits)
        )
mkEvalTx view tx = do
    r <- viewEvaluateTx view tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r

{- | Register any script stake credential (the consumer pin above is
the common case; exhibit controls register further credentials the
same way). Registration only makes a credential withdrawable; it
authorizes nothing by itself.
-}
registerScriptImpl
    :: View IO
    -> Addr
    -> ScriptHash
    -> IO ConwayTx
registerScriptImpl view fundAddr credHash = do
    let pp = viewProtocolParams view
    utxos <- viewUTxOsAt view fundAddr
    let funding =
            sortOn
                (Down . (^. coinTxOutL) . snd)
                [u | u@(_, out) <- utxos, out ^. referenceScriptTxOutL == SNothing]
    fundUtxo <- case funding of
        [] ->
            error
                "registerScript: funder wallet has no UTxOs"
        (u : _) -> pure u
    let evalTx = mkEvalTx view
        prog :: Tx.TxBuild NoCtx Void ()
        prog = do
            _ <- Tx.registerStakeScript credHash
            pure ()
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            [fundUtxo]
            []
            fundAddr
            prog
    case result of
        Right tx -> pure tx
        Left err ->
            error
                ( "registerScript: build failed: "
                    <> show err
                )
