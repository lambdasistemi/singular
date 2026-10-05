{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternSynonyms #-}

{- | Raw facts from one acquired state. This bridge retains the pinned
client's Conway queries and exposes its raw time queries; it computes no
execution units or time conversions.
-}
module Singular.Registry.Node.RawView
    ( RawProvider (..)
    , RawView (..)
    , rawNodeProvider
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.N2C.LocalStateQuery
    ( queryAcquiredLSQ
    , withAcquiredLSQ
    )
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Cardano.Node.Client.Provider (LedgerSnapshot (..))
import Cardano.Node.Client.Types (Block)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (SystemStart)
import Codec.Serialise (serialise)
import Ouroboros.Consensus.Block.Abstract (fromWithOrigin, pointSlot)
import Ouroboros.Consensus.Cardano.Block
    ( pattern QueryIfCurrentConway
    )
import Ouroboros.Consensus.HardFork.Combinator.Abstract.SingleEraBlock
    ( eraIndexToInt
    )
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query
    ( QueryHardFork (GetCurrentEra, GetInterpreter)
    , pattern QueryHardFork
    )
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetChainPoint, GetSystemStart)
    )
import Ouroboros.Consensus.Shelley.Ledger.Query
    ( pattern GetCurrentPParams
    , pattern GetEpochNo
    , pattern GetFilteredDelegationsAndRewardAccounts
    , pattern GetUTxOByAddress
    , pattern GetUTxOByTxIn
    )

newtype RawProvider m = RawProvider
    {withRawView :: forall a. (RawView m -> m a) -> m a}

data RawView m = RawView
    { rawSnapshot :: m LedgerSnapshot
    , rawParameters :: m (PParams ConwayEra)
    , rawUTxOsAt :: Addr -> m [(TxIn, TxOut ConwayEra)]
    , rawUTxOsByRefs :: Set TxIn -> m [(TxIn, TxOut ConwayEra)]
    , rawRewards
        :: Set (Credential Staking) -> m (Map (Credential Staking) Coin)
    , rawSystemStart :: m SystemStart
    , rawEraHistory :: m ByteString
    }

rawNodeProvider :: LSQChannel -> RawProvider IO
rawNodeProvider channel = RawProvider $ \action ->
    withAcquiredLSQ channel $ \handle -> do
        let query :: Query Block result -> IO result
            query = queryAcquiredLSQ handle
            current operation =
                either
                    (const (error (operation <> ": era mismatch - node not in Conway")))
                    pure
            utxo operation select = do
                UTxO outputs <-
                    current operation =<< query (BlockQuery (QueryIfCurrentConway select))
                pure (Map.toAscList outputs)
        action
            RawView
                { rawSnapshot = do
                    era <- query (BlockQuery (QueryHardFork GetCurrentEra))
                    point <- query GetChainPoint
                    epoch <-
                        current "queryLedgerSnapshot"
                            =<< query (BlockQuery (QueryIfCurrentConway GetEpochNo))
                    pure
                        LedgerSnapshot
                            { ledgerCurrentEra = case eraIndexToInt era of
                                0 -> "Byron"
                                1 -> "Shelley"
                                2 -> "Allegra"
                                3 -> "Mary"
                                4 -> "Alonzo"
                                5 -> "Babbage"
                                6 -> "Conway"
                                7 -> "Dijkstra"
                                n -> "Unknown era index " <> Text.pack (show n)
                            , ledgerChainPoint = point
                            , ledgerTipSlot = fromWithOrigin (SlotNo 0) (pointSlot point)
                            , ledgerEpoch = epoch
                            }
                , rawParameters =
                    current "queryProtocolParams"
                        =<< query (BlockQuery (QueryIfCurrentConway GetCurrentPParams))
                , rawUTxOsAt = \address ->
                    filter ((== address) . (^. addrTxOutL) . snd)
                        <$> utxo "queryUTxOsAtH" (GetUTxOByAddress (Set.singleton address))
                , rawUTxOsByRefs = utxo "queryUTxOByTxInH" . GetUTxOByTxIn
                , rawRewards = \credentials ->
                    snd
                        <$> ( current "queryStakeRewards"
                                =<< query
                                    ( BlockQuery
                                        ( QueryIfCurrentConway
                                            (GetFilteredDelegationsAndRewardAccounts credentials)
                                        )
                                    )
                            )
                , rawSystemStart = query GetSystemStart
                , rawEraHistory =
                    LBS.toStrict . serialise
                        <$> query (BlockQuery (QueryHardFork GetInterpreter))
                }
