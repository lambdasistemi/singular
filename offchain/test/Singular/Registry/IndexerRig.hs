{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Singular.Registry.IndexerRig
Description : An in-memory chain and an index written as its follower would
License     : Apache-2.0

The indexer adapter held to its contract without a node: a deterministic
in-memory chain stands in for the node, and a real in-memory index learns
a block only when a row applies it through the gated handle a follower
receives. A row can therefore hold the index behind the node, on another
block at the node's slot, restoring or disconnected, and require the
adapter to refuse by name.
-}
module Singular.Registry.IndexerRig
    ( -- * Rig
      Rig (..)
    , withRigAt
    , adapter
    , readinessOf
    , setReadiness
    , shortBound
    , longBound
    , fullCoverage

      -- * Blocks
    , Block (..)
    , produce
    , indexed
    , opsOf
    , indexerTxIn
    , toIndexerSlot
    , pointOf
    ) where

import Control.Concurrent.STM
    ( TVar
    , atomically
    , newTVarIO
    , readTVar
    , writeTVar
    )
import Data.Map.Strict qualified as Map
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word32)
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.N2C.Reconnect (UpstreamStatus (..))
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    , Readiness (..)
    )
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle (..)
    , withInMemoryIndexer
    )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer

import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Node.IndexGate
    ( Coverage (..)
    , IndexGate
    , IndexedPoint (..)
    , gatedHandle
    , newIndexGate
    )
import Singular.Registry.Node.IndexerView
    ( IndexerReadiness (..)
    , indexerProvider
    )
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , MemoryChain
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , SlotNo (..)
    , View (..)
    )

-- | A node (an in-memory chain) and an index the rows write as a follower would.
data Rig = Rig
    { rigChain :: MemoryChain
    , rigGate :: IndexGate
    , rigFollower :: IndexerHandle
    -- ^ The handle a follower writes through
    , rigReadiness :: TVar Readiness
    }

{- | A rig over a chain starting at this value, its index following
network @magic@ with this coverage, its follower connected and caught up.
-}
withRigAt :: Word32 -> ChainState -> Coverage -> (Rig -> IO a) -> IO a
withRigAt magic start coverage k = withInMemoryIndexer $ \idx -> do
    rigChain <- newMemoryChain start
    rigGate <- newIndexGate magic coverage idx
    now <- getCurrentTime
    rigReadiness <-
        newTVarIO
            Readiness
                { rProcessedSlot = Just (Indexer.SlotNo 0)
                , rTipSlot = Just (Indexer.SlotNo 0)
                , rUpstream = UpstreamConnected
                , rUpdatedAt = now
                }
    k Rig{rigFollower = gatedHandle rigGate, ..}

adapter :: Rig -> Int -> Provider IO
adapter rig bound =
    indexerProvider
        (rigGate rig)
        (readinessOf rig)
        bound
        (memoryProvider (rigChain rig))

readinessOf :: Rig -> IndexerReadiness
readinessOf rig =
    IndexerReadiness
        { irReadiness = readTVar (rigReadiness rig)
        , irThresholdSlots = 60
        }

-- | Agreement bound for rows that expect a refusal: a quarter second.
shortBound :: Int
shortBound = 250_000

-- | Agreement bound for rows that expect an answer: five seconds.
longBound :: Int
longBound = 5_000_000

fullCoverage :: Coverage
fullCoverage = Coverage{coverageStart = Nothing, coverageInterest = IndexAll}

-- | Change the follower's readiness.
setReadiness :: Rig -> (Readiness -> Readiness) -> IO ()
setReadiness rig f = atomically $ do
    r <- readTVar (rigReadiness rig)
    writeTVar (rigReadiness rig) (f r)

-- ---------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------

-- | Outputs a block spends and outputs it creates.
data Block = Block
    { spends :: [TxIn]
    , creates :: [(TxIn, TxOut ConwayEra)]
    }

{- | Add a block to the node and return its point with the action that
applies the same block to the index through the follower's handle.
-}
produce :: Rig -> Block -> IO (ChainPoint, IO ())
produce rig blk = do
    mutate (rigChain rig) $ \s ->
        s
            { csUTxO =
                Map.union
                    (Map.fromList (creates blk))
                    (foldr Map.delete (csUTxO s) (spends blk))
            }
    p <- withView (memoryProvider (rigChain rig)) (pure . viewPoint)
    pure
        ( p
        , applyAtSlot
            (rigFollower rig)
            (toIndexerSlot (cpSlot p))
            (Indexer.BlockHash (cpBlockHash p))
            (opsOf blk)
        )

indexed :: Rig -> (ChainPoint, IO ()) -> IO ChainPoint
indexed _ (p, applyBlock) = applyBlock >> pure p

opsOf :: Block -> [UtxoOp]
opsOf blk =
    map (UtxoSpend . indexerTxIn) (spends blk)
        <> [ UtxoCreate
                (indexerTxIn i)
                (Indexer.Address (serialiseAddr (o ^. addrTxOutL)))
                (Indexer.TxOut (serialize' (eraProtVerLow @ConwayEra) o))
           | (i, o) <- creates blk
           ]

indexerTxIn :: TxIn -> Indexer.TxIn
indexerTxIn (TxIn (TxId h) (TxIx ix)) =
    Indexer.TxIn (hashToBytes (extractHash h)) (fromIntegral ix)

toIndexerSlot :: SlotNo -> Indexer.SlotNo
toIndexerSlot (SlotNo s) = Indexer.SlotNo s

pointOf :: ChainPoint -> IndexedPoint
pointOf p = IndexedPoint (cpSlot p) (cpBlockHash p)
