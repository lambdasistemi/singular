{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ProviderSpec
Description : #323 — the read interface acquires one chain view per operation
License     : Apache-2.0

The read interface has one entry: acquire a view, read through it, and
let it go. The contract every adapter meets is the shared suite in
"Singular.Registry.ContractSuite" (#326); these rows keep what is
specific to one adapter.

The in-memory adapter advances its point by one slot per mutation.

The node adapter is held at its own boundary: the upstream node client
is replaced by one whose acquired session serves a chain value and
counts its acquisitions, and whose one-shot queries fail the row the
moment anything calls them. A view must be one acquisition, every read
through it must be served by that acquisition, and a connection lost
while acquiring must surface as its own failure.

The session's connection guard (#326) is held on the same fake: a
one-shot query, a second acquisition or a submission issued from inside
a view fails by name, the same call outside the view answers, and a read
waiting on a connection that has ended fails rather than waits.
-}
module Singular.Registry.ProviderSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (async)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (ErrorCall (..), throwIO, try)
import Control.Monad (forever)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import Singular.Registry.SyntheticTime (syntheticTime)
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (emptyPParams, ppTxFeeFixedL)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.N2C.Types (ConnectionLost (..))
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))

import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams)
import Singular.Registry.NetworkTime (NetworkTimeFailure (..))
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , loseConnection
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Node.Session
    ( NodeCallInView (..)
    , firstViewWithin
    , guardRawConnection
    )
import Singular.Registry.Node.View (nodeProvider)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , SlotNo (..)
    , View (..)
    , ViewFailure (..)
    )
import Singular.Registry.RawNodeFixture
    ( rawFixture
    , syntheticMaterial
    )
import Singular.Registry.Services qualified as Services
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    )

spec :: Spec
spec = describe "the read interface acquires one chain view (#323)" $ do
    memorySpec
    nodeSpec
    guardSpec
    originSpec

-- ---------------------------------------------------------
-- In-memory adapter
-- ---------------------------------------------------------

memorySpec :: Spec
memorySpec = describe "in-memory adapter" $ do
    it "each mutation advances the chain point" $ do
        chain <- newMemoryChain genesis
        mutate chain id
        p1 <- withView (memoryProvider chain) (pure . viewPoint)
        mutate chain changed
        p2 <- withView (memoryProvider chain) (pure . viewPoint)
        cpSlot p2 `shouldBe` succ (cpSlot p1)
        cpBlockHash p2 `shouldNotBe` cpBlockHash p1
    it
        "common services read the memory view's finite context with both rounding directions"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            withView (memoryProvider chain) $ \view -> do
                Services.floorSlot view 5_010 `shouldReturn` SlotNo 5
                Services.ceilingSlot view 5_010 `shouldReturn` SlotNo 6
                Services.slotStart view (SlotNo 6) `shouldReturn` 6_000
                try @NetworkTimeFailure (Services.floorSlot view 4_320_000_000_000)
                    `shouldReturn` Left (TimePastHorizon 4_320_000_000_000)
    it
        "common services refuse a released memory view before reading its context"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            released <- withView (memoryProvider chain) pure
            try @ViewFailure (Services.floorSlot released 5_000)
                `shouldReturn` Left ViewOutOfScope
            try @ViewFailure (viewResolvedOutputs released Set.empty)
                `shouldReturn` Left ViewOutOfScope
    it
        "common time keeps connection loss and network mismatch distinct from horizon refusal"
        $ do
            chain <- newMemoryChain genesis
            mutate chain id
            withView (memoryProvider chain) $ \view -> do
                loseConnection chain
                try @ViewFailure (Services.floorSlot view 5_000)
                    `shouldReturn` Left ViewConnectionLost
            wrongNetwork <- newMemoryChain genesis{csNetwork = 1}
            mutate wrongNetwork id
            withView (memoryProvider wrongNetwork) $ \view ->
                try @NetworkTimeFailure (Services.floorSlot view 5_000)
                    `shouldReturn` Left (WrongTimeNetwork 1 42)
genesis :: ChainState
genesis =
    ChainState
        { csNetwork = 42
        , csEra = "Conway"
        , csTip = Nothing
        , csPParams = params 155_381
        , csUTxO = Map.fromList [(outRef '3', ada 100_000_000)]
        , csRegistered = Set.empty
        , csNetworkTime = syntheticTime
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
            withView
                (nodeProvider (NetworkMagic 42) syntheticMaterial (rawFixture fake))
                $ \v -> do
                    utxos <- viewUTxOsAt v payer
                    registered <- viewScriptRegistered v credential
                    _ <- Services.floorSlot v 5_000
                    _ <- Services.ceilingSlot v 5_000
                    _ <- Services.evaluateTx v (mkBasicTx mkBasicTxBody)
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
    it "a connection lost during the acquisition is ViewConnectionLost" $ do
        (fake, _) <-
            fakeNode (Just (7, BS.replicate 32 0xab)) (Just ConnectionLost)
        r <-
            try
                ( withView
                    (nodeProvider (NetworkMagic 42) syntheticMaterial (rawFixture fake))
                    (pure . viewPoint)
                )
        r `shouldBe` Left ViewConnectionLost

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
                    , N2C.backendQueryUTxOByTxIn = \_ -> pure Map.empty
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

-- ---------------------------------------------------------
-- No node call inside a view (#326 I3)
-- ---------------------------------------------------------

{- | The session's connection guard over an upstream whose one-shot
queries and submitter answer: an unguarded call made inside a view
returns, so only the guard can make these rows refuse. Each refusal is
paired with the same call outside the view, which must answer.
-}
guardSpec :: Spec
guardSpec = describe "no node call inside a view by another route (#326)" $ do
    it
        "a one-shot query issued inside a view fails as NodeCallInView; \
        \outside the view it answers"
        $ do
            (n2c, _, _, raw) <- guarded
            let prov = nodeProvider (NetworkMagic 42) syntheticMaterial raw
            inside <- withView prov $ \_ -> try (N2C.queryLedgerSnapshot n2c)
            either
                (\e -> e `shouldBe` NodeCallInView "queryLedgerSnapshot")
                (const (expectationFailure "the one-shot answered inside the view"))
                inside
            outside <- N2C.ledgerTipSlot <$> N2C.queryLedgerSnapshot n2c
            outside `shouldBe` SlotNo 7
    it
        "a second acquisition inside a view fails as NodeCallInView; after \
        \the view it is acquired"
        $ do
            (_, _, _, raw) <- guarded
            let prov = nodeProvider (NetworkMagic 42) syntheticMaterial raw
            inside <- withView prov $ \_ -> try (withView prov (pure . viewPoint))
            either
                (\e -> e `shouldBe` NodeCallInView "withAcquired")
                (const (expectationFailure "a nested view was acquired"))
                inside
            released <- withView prov (pure . cpSlot . viewPoint)
            released `shouldBe` SlotNo 7
    it
        "a submission inside a view fails as NodeCallInView and never \
        \reaches the node; outside the view it does"
        $ do
            (_, submitter, sent, raw) <- guarded
            let prov = nodeProvider (NetworkMagic 42) syntheticMaterial raw
                tx = mkBasicTx mkBasicTxBody
            inside <- withView prov $ \_ -> try (submitTx submitter tx)
            either
                (\e -> e `shouldBe` NodeCallInView "submitTx")
                (const (expectationFailure "the submission went out inside the view"))
                inside
            readIORef sent `shouldReturn` 0
            _ <- submitTx submitter tx
            readIORef sent `shouldReturn` 1
    it
        "a query another thread issues while a view is held is not refused"
        $ do
            (n2c, _, _, raw) <- guarded
            let prov = nodeProvider (NetworkMagic 42) syntheticMaterial raw
            answered <- newEmptyMVar
            withView prov $ \_ -> do
                _ <- forkIO (try (N2C.queryLedgerSnapshot n2c) >>= putMVar answered)
                threadDelay 50_000
            r <- timeout 2_000_000 (takeMVar answered)
            fmap (fmap N2C.ledgerTipSlot) r
                `shouldBe` Just (Right (SlotNo 7) :: Either NodeCallInView SlotNo)
    it
        "a read inside a view whose connection has ended fails as \
        \ViewConnectionLost instead of waiting for an answer"
        $ do
            (fake, _) <- fakeNode (Just (7, BS.replicate 32 0xab)) Nothing
            stop <- newEmptyMVar
            client <- async (takeMVar stop)
            (_, _, raw) <-
                guardRawConnection
                    client
                    (silent fake)
                    (Submitter (const (fail "unused")))
                    (rawFixture (silent fake))
            let readAfterEnd v = putMVar stop () >> viewUTxOsAt v payer
            r <-
                timeout 5_000_000 . try $
                    withView
                        (nodeProvider (NetworkMagic 42) syntheticMaterial raw)
                        readAfterEnd
            r `shouldBe` Just (Left ViewConnectionLost)
  where
    guarded = do
        (fake, _) <- fakeNode (Just (7, BS.replicate 32 0xab)) Nothing
        sent <- newIORef (0 :: Int)
        let answering =
                fake
                    { N2C.queryLedgerSnapshot =
                        N2C.withAcquired fake N2C.queryLedgerSnapshotH
                    }
            submitter = Submitter $ \tx -> do
                modifyIORef' sent (+ 1)
                pure (Submitted (txIdTx tx))
        client <- async (forever (threadDelay 1_000_000))
        (n2c, s, raw) <-
            guardRawConnection client answering submitter (rawFixture answering)
        pure (n2c, s, sent, raw)

{- | The fake node with an acquired state whose reads never answer, as a
node's do once the connection to it has ended.
-}
silent :: N2C.Provider IO -> N2C.Provider IO
silent fake =
    fake
        { N2C.withAcquired = \k -> N2C.withAcquired fake $ \h ->
            k
                ( N2C.mkQueryHandle
                    N2C.QueryHandleBackend
                        { N2C.backendQueryUTxOs = \_ -> forever (threadDelay 1_000_000)
                        , N2C.backendQueryUTxOsAt = N2C.queryUTxOsAtH h
                        , N2C.backendQueryUTxOByTxIn = N2C.queryUTxOByTxInH h
                        , N2C.backendQueryProtocolParams = N2C.queryProtocolParamsH h
                        , N2C.backendQueryLedgerSnapshot = N2C.queryLedgerSnapshotH h
                        , N2C.backendQueryStakeRewards = N2C.queryStakeRewardsH h
                        , N2C.backendQueryRewardAccounts = N2C.queryRewardAccountsH h
                        , N2C.backendQueryVoteDelegatees = N2C.queryVoteDelegateesH h
                        , N2C.backendQueryTreasury = N2C.queryTreasuryH h
                        , N2C.backendQueryGovernanceState = N2C.queryGovernanceStateH h
                        , N2C.backendEvaluateTx = N2C.evaluateTxH h
                        , N2C.backendPosixMsToSlot = N2C.posixMsToSlotH h
                        , N2C.backendPosixMsCeilSlot = N2C.posixMsCeilSlotH h
                        }
                )
        }
