{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Four raw facts used by private recording and confirmation probes only.
module Singular.Registry.Private.RawFacts
    ( RawFacts (..)
    , withRawFacts
    ) where

import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
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
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
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
    )

data RawFacts = RawFacts
    { factSnapshot :: IO LedgerSnapshot
    , factParameters :: IO (PParams ConwayEra)
    , factSystemStart :: IO SystemStart
    , factEraHistory :: IO ByteString
    }

withRawFacts :: LSQChannel -> (RawFacts -> IO a) -> IO a
withRawFacts channel action = withAcquiredLSQ channel $ \handle -> do
    let query :: Query Block result -> IO result
        query = queryAcquiredLSQ handle
        conway operation =
            either
                (const (fail (operation <> ": private source is not in Conway")))
                pure
    action
        RawFacts
            { factSnapshot = do
                era <- query (BlockQuery (QueryHardFork GetCurrentEra))
                point <- query GetChainPoint
                epoch <-
                    conway "epoch"
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
            , factParameters =
                conway "parameters"
                    =<< query (BlockQuery (QueryIfCurrentConway GetCurrentPParams))
            , factSystemStart = query GetSystemStart
            , factEraHistory =
                LBS.toStrict . serialise
                    <$> query (BlockQuery (QueryHardFork GetInterpreter))
            }
