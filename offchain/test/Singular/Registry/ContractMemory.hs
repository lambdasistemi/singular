{-# LANGUAGE NumericUnderscores #-}

{- | Synthetic raw-source contract fixture. Its independent expected outputs
are kept by the producer, never read back from the provider under test.
The removed node/indexer adapters are not reconstructed or renamed here.
-}
module Singular.Registry.ContractMemory (memoryHarness) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Singular.Registry.ContractSuite
    ( AdapterHarness (..)
    , Chain (..)
    , EvidenceClass (..)
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , newRawChain
    , rawChainProvider
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    )

memoryHarness :: AdapterHarness
memoryHarness =
    AdapterHarness
        { ahAdapter = "raw facts fixture"
        , ahEvidence = TestAdapter
        , ahNotSupported = Map.empty
        , ahChain = \action -> do
            chain <- newRawChain genesis
            advanceChain chain id
            next <- newIORef (0 :: Int)
            expected <- newIORef Map.empty
            let change = do
                    index <- atomicModifyIORef' next (\n -> (n + 1, n))
                    let pair = (outRef index, ada watched)
                    advanceChain chain $ \facts ->
                        facts{csUTxO = uncurry Map.insert pair (csUTxO facts)}
                    atomicModifyIORef' expected $ \previous ->
                        (uncurry Map.insert pair previous, ())
                (network, provider) = rawChainProvider chain
            action
                Chain
                    { chProvider = provider
                    , chNetwork = network
                    , chWatched = watched
                    , chUnregistered = unregistered
                    , chChange = change
                    , chIndependentOutputs = Map.toAscList <$> readIORef expected
                    }
        }

genesis :: ChainFacts
genesis =
    ChainFacts
        { csNetwork = 42
        , csTip = Nothing
        , csPParams = emptyPParams
        , csUTxO = Map.empty
        , csRegistered = Set.empty
        , csNetworkTime = syntheticTime
        }

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
