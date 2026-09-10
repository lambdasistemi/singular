{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Request
Description : Request insert/delete/update transactions
License     : Apache-2.0

Builds request transactions for inserting, deleting,
or updating a key in a token's trie. No script
execution occurs -- the transaction simply pays to
the per-cage request address with an inline
'RequestDatum'.
The locked ADA includes the token's @tip@ plus a
fee buffer for the oracle's update transaction.
-}
module Cardano.MPFS.Cage.TxBuilder.Request (
    requestInsertImpl,
    requestDeleteImpl,
    requestUpdateImpl,
    requestLockedAda,
) where

import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (
    mkBasicTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (Inject (..))

import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    Coin (..),
    ConwayEra,
    PParams,
    TokenId,
 )
import Cardano.MPFS.Cage.Provider (Provider (..))
import Cardano.MPFS.Cage.TxBuilder.Internal
import Cardano.MPFS.Cage.Types (
    OnChainOperation (..),
 )
import Cardano.Tx.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.Tx.Ledger (ConwayTx)

-- | Build a request-insert transaction.
requestInsertImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token tip (lovelace)
    Coin ->
    TokenId ->
    -- | Key to insert
    ByteString ->
    -- | Value to insert
    ByteString ->
    Addr ->
    IO ConwayTx
requestInsertImpl cfg prov tip tid key value =
    requestImpl
        cfg
        prov
        tip
        tid
        key
        (OpInsert value)

-- | Build a request-delete transaction.
requestDeleteImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token tip (lovelace)
    Coin ->
    TokenId ->
    -- | Key to delete
    ByteString ->
    -- | Old value (for on-chain proof)
    ByteString ->
    Addr ->
    IO ConwayTx
requestDeleteImpl cfg prov tip tid key val =
    requestImpl
        cfg
        prov
        tip
        tid
        key
        (OpDelete val)

-- | Build a request-update transaction.
requestUpdateImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token tip (lovelace)
    Coin ->
    TokenId ->
    -- | Key to update
    ByteString ->
    -- | Old value (must match current)
    ByteString ->
    -- | New value
    ByteString ->
    Addr ->
    IO ConwayTx
requestUpdateImpl
    cfg
    prov
    tip
    tid
    key
    oldVal
    newVal =
        requestImpl
            cfg
            prov
            tip
            tid
            key
            (OpUpdate oldVal newVal)

-- | Generic request transaction builder.
requestImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token tip
    Coin ->
    TokenId ->
    ByteString ->
    OnChainOperation ->
    Addr ->
    IO ConwayTx
requestImpl cfg prov (Coin mf) tid key op addr = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        utxos of
        [] -> error "requestImpl: no UTxOs"
        (u : _) -> pure u
    now <- currentPosixMs
    let datum =
            mkRequestDatum tid addr key op mf now
        scriptAddr =
            requestAddrFromCfg cfg tid (network cfg)
        draftOut =
            mkBasicTxOut
                scriptAddr
                (inject (Coin 0))
                & datumTxOutL
                    .~ mkInlineDatum datum
        refundDraft =
            mkBasicTxOut addr (inject (Coin 0))
        minAda =
            requestLockedAda
                pp
                draftOut
                refundDraft
                mf
        txOut =
            mkBasicTxOut
                scriptAddr
                (inject minAda)
                & datumTxOutL
                    .~ mkInlineDatum datum
        body =
            mkBasicTxBody
                & outputsTxBodyL
                    .~ StrictSeq.singleton txOut
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err ->
            error $
                "requestImpl: " <> show err
        Right br -> pure (balancedTx br)

-- | Compute the ADA to lock in a request output.
requestLockedAda ::
    PParams ConwayEra ->
    TxOut ConwayEra ->
    TxOut ConwayEra ->
    Integer ->
    Coin
requestLockedAda pp reqDraft refDraft tip =
    let Coin refMin =
            getMinCoinTxOut pp refDraft
        feeBuffer = 1_000_000
        locked = tip + feeBuffer + refMin
        adjusted =
            getMinCoinTxOut
                pp
                ( reqDraft
                    & valueTxOutL
                        .~ inject (Coin locked)
                )
     in max adjusted (Coin locked)
