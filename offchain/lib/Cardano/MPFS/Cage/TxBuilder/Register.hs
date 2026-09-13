{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Register
Description : Consumer stake-credential registration transaction
License     : Apache-2.0

Registers the bound consumer's script stake credential so later
@Modify@ batches can withdraw it (NOTE-020 item 2). A withdrawal from
an unregistered credential fails on ledger for the wrong reason — this
transaction establishes the registration/withdrawal route up front, once
per cage, funded by the operator.

No registry owner, no stake bypass: registration only makes the pinned
consumer's credential withdrawable; it authorizes nothing by itself.
-}
module Cardano.MPFS.Cage.TxBuilder.Register (
    registerConsumerImpl,
    registerScriptImpl,
) where

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Void (Void)

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))

import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (ConwayEra)
import Cardano.MPFS.Cage.Provider (Provider (..))
import Cardano.MPFS.Cage.TxBuilder.Internal (
    pinScriptHash,
 )
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Ledger.Address (Addr)

-- | Empty query GADT (no context needed).
data NoCtx a

-- | Wrap the Provider's evaluateTx for the DSL (no scripts execute
-- here, but the DSL still calls back through this interface).
mkEvalTx ::
    Provider IO ->
    ConwayTx ->
    IO
        ( Map.Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
            (Either String ExUnits)
        )
mkEvalTx prov tx = do
    r <- evaluateTx prov tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r

{- | Build the consumer-registration transaction: funds from the
operator's wallet, one stake-registration certificate for the pinned
consumer script hash, change back to the operator. Call once per cage
after boot, before the first @Modify@.
-}
registerConsumerImpl ::
    CageConfig ->
    Provider IO ->
    Addr ->
    IO ConwayTx
registerConsumerImpl cfg prov fundAddr =
    registerScriptImpl
        prov
        fundAddr
        (pinScriptHash (SBS.fromShort (cfgConsumerPin cfg)))

{- | Register any script stake credential (the consumer pin above is
the common case; exhibit controls register further credentials the
same way). Registration only makes a credential withdrawable; it
authorizes nothing by itself.
-}
registerScriptImpl ::
    Provider IO ->
    Addr ->
    ScriptHash ->
    IO ConwayTx
registerScriptImpl prov fundAddr credHash = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOs prov fundAddr
    fundUtxo <- case utxos of
        [] ->
            error
                "registerScript: funder wallet has no UTxOs"
        (u : _) -> pure u
    let evalTx = mkEvalTx prov
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
