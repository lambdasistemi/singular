{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ProviderSpec
Description : #323 — the read interface acquires one chain view per operation
License     : Apache-2.0

The read interface has one entry: acquire a view, read through it, and
let it go. These rows hold both adapters to that contract.

The in-memory adapter is the deterministic chain the interleaving rows
need: a change made after a view is acquired never reaches that view,
and a fresh acquisition does see it. Each row compares against the
chain value the row itself built, never against a literal the adapter
produced.

The node adapter is held at its own boundary: the upstream node client
is replaced by one whose acquired session serves a chain value and
counts its acquisitions, and whose one-shot queries fail the row the
moment anything calls them. A view must be one acquisition, every read
through it must be served by that acquisition, the chain origin must be
refused, and a lost connection must surface as its own failure.
-}
module Singular.Registry.ProviderSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (ErrorCall (..), throwIO, try)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (emptyPParams, ppTxFeeFixedL)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.N2C.Types (ConnectionLost (..))
import Cardano.Node.Client.Provider qualified as N2C
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))

import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams)
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , loseConnection
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Node.Session (firstViewWithin)
import Singular.Registry.Node.View (nodeProvider)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , SlotNo (..)
    , View (..)
    , ViewFailure (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    )

spec :: Spec
spec = describe "the read interface acquires one chain view (#323)" $ do
    memorySpec
    nodeSpec
    originSpec

-- ---------------------------------------------------------
-- In-memory adapter
-- ---------------------------------------------------------

memorySpec :: Spec
memorySpec = describe "in-memory adapter" $ do
    it
        "a view names the network, era, slot and block hash it was acquired at"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            point <- withView (memoryProvider chain) (pure . viewPoint)
            cpNetwork point `shouldBe` csNetwork genesis
            cpEra point `shouldBe` csEra genesis
            cpSlot point `shouldBe` SlotNo 1
            BS.length (cpBlockHash point) `shouldBe` 32
    it
        "acquiring at the chain origin fails as AcquiredAtOrigin, never as an empty view"
        $ do
            chain <- newMemoryChain genesis
            r <- try (withView (memoryProvider chain) (`viewUTxOsAt` payer))
            r `shouldBe` Left AcquiredAtOrigin
    it
        "a change after acquisition never reaches the view; a fresh view sees it"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            let prov = memoryProvider chain
            (inside, fresh) <- withView prov $ \v -> do
                mutate chain changed
                inside <- observe v
                fresh <- withView prov observe
                pure (inside, fresh)
            inside `shouldBe` observeState genesis
            fresh `shouldBe` observeState (changed genesis)
            fst3 fresh `shouldNotBe` fst3 inside
    it "each mutation advances the chain point" $ do
        chain <- newMemoryChain genesis
        mutate chain id
        p1 <- withView (memoryProvider chain) (pure . viewPoint)
        mutate chain changed
        p2 <- withView (memoryProvider chain) (pure . viewPoint)
        cpSlot p2 `shouldBe` succ (cpSlot p1)
        cpBlockHash p2 `shouldNotBe` cpBlockHash p1
    it
        "a view used after its scope fails as ViewOutOfScope, never as empty"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            escaped <- withView (memoryProvider chain) pure
            r <- try (viewUTxOsAt escaped payer)
            r `shouldBe` Left ViewOutOfScope
            s <- try (viewScriptRegistered escaped credential)
            s `shouldBe` Left ViewOutOfScope
    it
        "a lost connection fails the acquisition and every read as ViewConnectionLost"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            let prov = memoryProvider chain
            inside <- withView prov $ \v -> do
                loseConnection chain
                try (viewUTxOsAt v payer)
            inside `shouldBe` Left ViewConnectionLost
            r <- try (withView prov (`viewUTxOsAt` payer))
            r `shouldBe` Left ViewConnectionLost
  where
    fst3 (a, _, _) = a
    observeState c =
        ( csPParams c
        , Map.toList (csUTxO c)
        , credential `Set.member` csRegistered c
        )

-- | What a row reads through a view: parameters, the wallet, registration.
observe
    :: View IO -> IO (PParams ConwayEra, [(TxIn, TxOut ConwayEra)], Bool)
observe v = do
    utxos <- viewUTxOsAt v payer
    registered <- viewScriptRegistered v credential
    pure (viewProtocolParams v, utxos, registered)

genesis :: ChainState
genesis =
    ChainState
        { csNetwork = 42
        , csEra = "Conway"
        , csTip = Nothing
        , csPParams = params 155_381
        , csUTxO = Map.fromList [(outRef '3', ada 100_000_000)]
        , csRegistered = Set.empty
        , csSystemStartMs = 0
        , csSlotLengthMs = 1_000
        }

changed :: ChainState -> ChainState
changed c =
    c
        { csPParams = params 311_000
        , csUTxO = Map.insert (outRef '4') (ada 500_000_000) (csUTxO c)
        , csRegistered = Set.insert credential (csRegistered c)
        }

params :: Integer -> PParams ConwayEra
params fixed = emptyPParams & ppTxFeeFixedL .~ Coin fixed

-- ---------------------------------------------------------
-- Node adapter
-- ---------------------------------------------------------

nodeSpec :: Spec
nodeSpec = describe "node adapter over withAcquired" $ do
    it "one view is one acquisition, and every read is served inside it" $ do
        (fake, acquisitions) <-
            fakeNode (Just (7, BS.replicate 32 0xab)) Nothing
        (point, utxos, registered) <-
            withView (nodeProvider (NetworkMagic 42) fake) $ \v -> do
                utxos <- viewUTxOsAt v payer
                registered <- viewScriptRegistered v credential
                _ <- viewPosixMsToSlot v 5_000
                _ <- viewPosixMsCeilSlot v 5_000
                _ <- viewEvaluateTx v (mkBasicTx mkBasicTxBody)
                pure (viewPoint v, utxos, registered)
        readIORef acquisitions `shouldReturn` 1
        point
            `shouldBe` ChainPoint
                { cpNetwork = 42
                , cpEra = "Conway"
                , cpSlot = SlotNo 7
                , cpBlockHash = BS.replicate 32 0xab
                }
        utxos `shouldBe` [(outRef '3', ada 100_000_000)]
        registered `shouldBe` True
    it "the chain origin is refused as AcquiredAtOrigin" $ do
        (fake, _) <- fakeNode Nothing Nothing
        r <-
            try
                (withView (nodeProvider (NetworkMagic 42) fake) (pure . viewPoint))
        r `shouldBe` Left AcquiredAtOrigin
    it "a connection lost during the acquisition is ViewConnectionLost" $ do
        (fake, _) <-
            fakeNode (Just (7, BS.replicate 32 0xab)) (Just ConnectionLost)
        r <-
            try
                (withView (nodeProvider (NetworkMagic 42) fake) (pure . viewPoint))
        r `shouldBe` Left ViewConnectionLost
    it "a node view used after its scope is ViewOutOfScope" $ do
        (fake, _) <- fakeNode (Just (7, BS.replicate 32 0xab)) Nothing
        escaped <- withView (nodeProvider (NetworkMagic 42) fake) pure
        r <- try (viewUTxOsAt escaped payer)
        r `shouldBe` Left ViewOutOfScope

{- | An upstream provider whose acquired session serves a fixed chain
and counts acquisitions. Its one-shot fields fail: nothing may read
around the acquisition. With a failure, the acquisition itself raises
it.
-}
fakeNode
    :: Maybe (Word, BS.ByteString)
    -> Maybe ConnectionLost
    -> IO (N2C.Provider IO, IORef Int)
fakeNode tip failure = do
    acquisitions <- newIORef 0
    let handle =
            N2C.mkQueryHandle
                N2C.QueryHandleBackend
                    { N2C.backendQueryUTxOs = \_ -> pure [(outRef '3', ada 100_000_000)]
                    , N2C.backendQueryUTxOsAt = \_ -> oneShot "queryUTxOsAt"
                    , N2C.backendQueryUTxOByTxIn = \_ -> oneShot "queryUTxOByTxIn"
                    , N2C.backendQueryProtocolParams = pure (params 155_381)
                    , N2C.backendQueryLedgerSnapshot =
                        pure
                            N2C.LedgerSnapshot
                                { N2C.ledgerCurrentEra = "Conway"
                                , N2C.ledgerChainPoint = point
                                , N2C.ledgerTipSlot = maybe 0 (SlotNo . fromIntegral . fst) tip
                                , N2C.ledgerEpoch = N2C.EpochNo 0
                                }
                    , N2C.backendQueryStakeRewards =
                        pure . Map.fromSet (const (Coin 0))
                    , N2C.backendQueryRewardAccounts = \_ -> oneShot "queryRewardAccounts"
                    , N2C.backendQueryVoteDelegatees = \_ -> oneShot "queryVoteDelegatees"
                    , N2C.backendQueryTreasury = oneShot "queryTreasury"
                    , N2C.backendQueryGovernanceState = oneShot "queryGovernanceState"
                    , N2C.backendEvaluateTx = \_ -> pure Map.empty
                    , N2C.backendPosixMsToSlot = \ms -> pure (SlotNo (fromIntegral (ms `div` 1_000)))
                    , N2C.backendPosixMsCeilSlot = \ms -> pure (SlotNo (fromIntegral ((ms + 999) `div` 1_000)))
                    }
        point = case tip of
            Nothing -> Chain.GenesisPoint
            Just (s, h) ->
                Chain.BlockPoint
                    (SlotNo (fromIntegral s))
                    (OneEraHash (SBS.toShort h))
        fake =
            N2C.Provider
                { N2C.withAcquired = \k -> do
                    modifyIORef' acquisitions (+ 1)
                    maybe (k handle) throwIO failure
                , N2C.queryUTxOs = \_ -> oneShot "queryUTxOs"
                , N2C.queryUTxOByTxIn = \_ -> oneShot "queryUTxOByTxIn"
                , N2C.queryProtocolParams = oneShot "queryProtocolParams"
                , N2C.queryLedgerSnapshot = oneShot "queryLedgerSnapshot"
                , N2C.queryStakeRewards = \_ -> oneShot "queryStakeRewards"
                , N2C.queryRewardAccounts = \_ -> oneShot "queryRewardAccounts"
                , N2C.queryVoteDelegatees = \_ -> oneShot "queryVoteDelegatees"
                , N2C.queryTreasury = oneShot "queryTreasury"
                , N2C.queryGovernanceState = oneShot "queryGovernanceState"
                , N2C.evaluateTx = \_ -> oneShot "evaluateTx"
                , N2C.posixMsToSlot = \_ -> oneShot "posixMsToSlot"
                , N2C.posixMsCeilSlot = \_ -> oneShot "posixMsCeilSlot"
                , N2C.queryUpperBoundSlot = \_ -> oneShot "queryUpperBoundSlot"
                }
    pure (fake, acquisitions)
  where
    oneShot :: String -> IO a
    oneShot what =
        fail
            ("a one-shot " <> what <> " was issued outside the acquired view")

-- ---------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------

credential :: ScriptHash
credential = computeScriptHash (SBS.toShort (BS.replicate 16 0x01))

outRef :: Char -> TxIn
outRef c =
    either
        (error . ("ProviderSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#0")))

ada :: Integer -> TxOut ConwayEra
ada n = mkBasicTxOut payer (MaryValue (Coin n) mempty)

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

-- ---------------------------------------------------------
-- Opening a session at the origin
-- ---------------------------------------------------------

originSpec :: Spec
originSpec = describe "waiting for a fresh chain's first block" $ do
    it
        "refuses a chain that stays at its origin, by name, within its bound"
        $ do
            chain <- newMemoryChain genesis
            r <-
                timeout
                    5_000_000
                    (try (firstViewWithin 3 "node.socket" (memoryProvider chain)))
            case r of
                Nothing -> expectationFailure "the origin wait did not end within its bound"
                Just (Right point) -> expectationFailure ("a view at the origin: " <> show point)
                Just (Left (ErrorCall msg)) -> do
                    msg `shouldSatisfy` isInfixOf "still at its origin"
                    msg `shouldSatisfy` isInfixOf "node.socket"
    it
        "returns the first view once the first block lands (reached control)"
        $ do
            chain <- newMemoryChain genesis
            _ <- forkIO (threadDelay 150_000 >> mutate chain id)
            point <- firstViewWithin 20 "node.socket" (memoryProvider chain)
            cpSlot point `shouldBe` SlotNo 1
