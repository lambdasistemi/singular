{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Registry.TxBuilder.Request
Description : Request transactions, one per C2 edge
License     : Apache-2.0

Builds the request transaction for one C2 edge (#183). No script
execution occurs -- the transaction simply pays to the per-cage
request address with an inline 'RequestDatum' naming the edge.

The locked ADA includes the token's @tip@ plus a fee buffer for the
oracle's update transaction, and the datum's deposit is exactly that
lovelace less the tip, which is what the fold checks.
-}
module Singular.Registry.TxBuilder.Request (
    requestEdgeImpl,
    requestLockedAda,
    settleRequestOutput,
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

import Cardano.Tx.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
    Coin (..),
    ConwayEra,
    PParams,
    TokenId,
 )
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Internal
import Singular.Registry.Types (
    Edge,
 )

{- | Build the request transaction for one C2 edge (#183).

The edge is the whole shape of the request: it names the trie move and
its leaf bytes, so no value travels here. The datum's deposit is the
output's lovelace less the tip, settled with the sizing below because
the deposit is itself a datum field.
-}
requestEdgeImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token tip (lovelace)
    Coin ->
    TokenId ->
    -- | Key the edge moves
    ByteString ->
    -- | The C2 row index (0-6)
    Edge ->
    Addr ->
    IO ConwayTx
requestEdgeImpl cfg prov (Coin mf) tid key edge addr = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        utxos of
        [] -> error "requestEdgeImpl: no UTxOs"
        (u : _) -> pure u
    now <- currentPosixMs
    let scriptAddr =
            requestAddrFromCfg cfg tid (network cfg)
        refundDraft =
            mkBasicTxOut addr (inject (Coin 0))
        build locked deposit =
            mkBasicTxOut
                scriptAddr
                (inject (Coin locked))
                & datumTxOutL
                    .~ mkInlineDatum
                        ( mkRequestDatum
                            tid
                            addr
                            key
                            edge
                            deposit
                            now
                        )
        Coin start =
            requestLockedAda
                pp
                (build 0 0)
                refundDraft
                mf
        txOut = settleRequestOutput pp mf build start
        body =
            mkBasicTxBody
                & outputsTxBodyL
                    .~ StrictSeq.singleton txOut
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err ->
            error $
                "requestEdgeImpl: " <> show err
        Right br -> pure (balancedTx br)

{- | Settle a request output against the invariant the fold checks: the
datum's deposit is exactly the output's lovelace less the tip.

Writing the deposit into the datum can itself raise the output's
minimum ada, so the two are a fixpoint rather than one computation.
Each round rebuilds the output at the minimum the previous round
demanded; the minimum is monotone in the lovelace and the datum grows
by at most a few bytes, so it settles in one or two rounds. The bound
is there so that a ledger whose minimum never stabilises fails loudly
instead of looping.
-}
settleRequestOutput ::
    PParams ConwayEra ->
    -- | Token tip (lovelace)
    Integer ->
    -- | Output for a given (locked lovelace, deposit)
    (Integer -> Integer -> TxOut ConwayEra) ->
    -- | Starting locked lovelace
    Integer ->
    TxOut ConwayEra
settleRequestOutput pp tip build = go (8 :: Int)
  where
    go rounds locked =
        let out = build locked (locked - tip)
            Coin need = getMinCoinTxOut pp out
         in if need <= locked
                then out
                else
                    if rounds <= 0
                        then
                            error
                                "settleRequestOutput: the minimum ada\
                                \ for a request output did not settle"
                        else go (rounds - 1) need

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
