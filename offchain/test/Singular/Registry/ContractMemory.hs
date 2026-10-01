{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ContractMemory
Description : #326 — the contract's in-memory harnesses
License     : Apache-2.0

Two adapters over the deterministic in-memory chain: the in-memory
adapter itself, and the indexer adapter with that chain standing in for
the node and a real in-memory index written as its follower would. The
second is where the index's refusals — lag, fork, restoring,
disconnected — are provoked: the rig holds the index behind the node,
on another block at the node's slot, restoring or disconnected, which a
live follower cannot be made to do from outside its session.
-}
module Singular.Registry.ContractMemory
    ( memoryHarness
    , indexerMemoryHarness
    ) where

import Control.Concurrent (forkIO)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.N2C.Reconnect
    ( DisconnectInfo (..)
    , UpstreamStatus (..)
    )
import Cardano.Node.Client.UTxOIndexer.Follower (Readiness (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (IndexerHandle (..))
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer

import Singular.Registry.ContractSuite
    ( AdapterHarness (..)
    , Case (..)
    , Chain (..)
    , EvidenceClass (..)
    , IndexRefusal (..)
    , unsupportedControl
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.IndexerRig
    ( Block (..)
    , Rig (..)
    , adapter
    , fullCoverage
    , indexed
    , longBound
    , opsOf
    , produce
    , setReadiness
    , toIndexerSlot
    , withRigAt
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , loseConnection
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Provider (ChainPoint (..))
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    )

-- | The in-memory adapter.
memoryHarness :: AdapterHarness
memoryHarness =
    AdapterHarness
        { ahAdapter = "in-memory"
        , ahEvidence = TestAdapter
        , ahNotSupported =
            Map.fromList
                [ (c, "it reads a chain value, not an index")
                | c <- [IndexLag, IndexFork, IndexRestoring, IndexDisconnected]
                ]
        , ahChain = \k -> do
            chain <- newMemoryChain genesis
            mutate chain id
            next <- counter
            k
                Chain
                    { chProvider = memoryProvider chain
                    , chNetwork = csNetwork genesis
                    , chWatched = watched
                    , chUnregistered = unregistered
                    , chChange = do
                        n <- next
                        mutate chain $ \s ->
                            s{csUTxO = Map.insert (outRef n) (ada watched) (csUTxO s)}
                    , chLoseConnection = loseConnection chain
                    , chAtOrigin = \use -> newMemoryChain genesis >>= use . memoryProvider
                    , chProvoke = unsupportedControl . show
                    }
        }

{- | The indexer adapter over the in-memory chain standing in for the node,
its index written block by block as a follower would.
-}
indexerMemoryHarness :: AdapterHarness
indexerMemoryHarness =
    AdapterHarness
        { ahAdapter = "indexer (in-memory node)"
        , ahEvidence = TestAdapter
        , ahNotSupported = Map.empty
        , ahChain = \k -> withRigAt (csNetwork genesis) genesis fullCoverage $ \rig -> do
            next <- counter
            -- The node takes the block at once; the index applies it on its
            -- own thread, as a follower does, so a change made while a view
            -- holds the index waits for that view to end.
            let change = do
                    n <- next
                    (_, apply) <-
                        produce rig Block{spends = [], creates = [(outRef n, ada watched)]}
                    _ <- forkIO apply
                    pure ()
            -- The first block is indexed before any case runs.
            n0 <- next
            _ <-
                produce rig Block{spends = [], creates = [(outRef n0, ada watched)]}
                    >>= indexed rig
            k
                Chain
                    { chProvider = adapter rig longBound
                    , chNetwork = csNetwork genesis
                    , chWatched = watched
                    , chUnregistered = unregistered
                    , chChange = change
                    , chLoseConnection = loseConnection (rigChain rig)
                    , chAtOrigin = \use ->
                        withRigAt (csNetwork genesis) genesis fullCoverage $ \fresh ->
                            use (adapter fresh longBound)
                    , chProvoke = provoke rig next
                    }
        }
  where
    provoke rig next = \case
        Lag -> do
            -- The node moves on; the index is not told.
            n <- next
            _ <-
                produce rig Block{spends = [], creates = [(outRef n, ada watched)]}
            pure ()
        Fork -> do
            n <- next
            (p, _) <-
                produce rig Block{spends = [], creates = [(outRef n, ada watched)]}
            applyAtSlot
                (rigFollower rig)
                (toIndexerSlot (cpSlot p))
                (Indexer.BlockHash (BS.map (+ 1) (cpBlockHash p)))
                (opsOf Block{spends = [], creates = []})
        Restoring -> setReadiness rig $ \r ->
            r
                { rProcessedSlot = Just (Indexer.SlotNo 1)
                , rTipSlot = Just (Indexer.SlotNo 500)
                }
        Disconnected -> setReadiness rig $ \r ->
            r
                { rUpstream =
                    UpstreamDisconnected (DisconnectInfo "socket closed" 1 1_000)
                }

-- ---------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------

genesis :: ChainState
genesis =
    ChainState
        { csNetwork = 42
        , csEra = "Conway"
        , csTip = Nothing
        , csPParams = emptyPParams
        , csUTxO = Map.empty
        , csRegistered = Set.empty
        , csSystemStartMs = 0
        , csSlotLengthMs = 1_000
        }

-- | A source of distinct output indices, one per chain change.
counter :: IO (IO Int)
counter = do
    ref <- newIORef 0
    pure (atomicModifyIORef' ref (\n -> (n + 1, n)))

outRef :: Int -> TxIn
outRef n =
    either
        (error . ("ContractMemory fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'c' <> "#" <> show n)))

ada :: Addr -> TxOut ConwayEra
ada addr = mkBasicTxOut addr (MaryValue (Coin 2_000_000) mempty)

watched :: Addr
watched = addrFromKeyHashBytes Testnet (BS.replicate 28 0x7c)

unregistered :: ScriptHash
unregistered = computeScriptHash (SBS.toShort (BS.replicate 16 0x02))
