{- |
Module      : Singular.Registry.StubFollowing
Description : A follower installed around a real in-memory index, following no chain
License     : Apache-2.0

Rows that exercise what a runner does inside a followed chain install a
follower whose index is a real in-memory one the row writes itself.
Its gate covers the chain from its origin and its readiness reports a
connected, caught-up follower.
-}
module Singular.Registry.StubFollowing
    ( withStubFollowing
    ) where

import Data.Time.Clock.POSIX (posixSecondsToUTCTime)

import Cardano.Node.Client.N2C.Reconnect (UpstreamStatus (..))
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    , Readiness (..)
    )
import Cardano.Node.Client.UTxOIndexer.Indexer (IndexerHandle)
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer

import Singular.Registry.Node.IndexGate (Coverage (..), newIndexGate)
import Singular.Registry.Node.Indexer (Following (..), withFollowing)
import Singular.Registry.Node.IndexerView (IndexerReadiness (..))

-- | Install a follower around an in-memory index for an action.
withStubFollowing :: IndexerHandle -> IO a -> IO a
withStubFollowing idx action = do
    gate <-
        newIndexGate
            42
            Coverage{coverageStart = Nothing, coverageInterest = IndexAll}
            idx
    withFollowing
        Following
            { followingIndexer = idx
            , followingGate = gate
            , followingReadiness =
                IndexerReadiness
                    { irReadiness =
                        pure
                            Readiness
                                { rProcessedSlot = Just (Indexer.SlotNo 0)
                                , rTipSlot = Just (Indexer.SlotNo 0)
                                , rUpstream = UpstreamConnected
                                , rUpdatedAt = posixSecondsToUTCTime 0
                                }
                    , irThresholdSlots = 60
                    }
            }
        action
