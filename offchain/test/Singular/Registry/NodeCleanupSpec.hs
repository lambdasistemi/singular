{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.NodeCleanupSpec
Description : What a runner leaves behind when its body fails
License     : Apache-2.0

A session installs two pieces of process state for the runner body:
the open session, and the chain follower with its funding-read guard.
Each bracket must remove its state when the body ends — on normal
return and on exception alike — or a later action would read a session
whose connection is gone, wait on a follower nobody refreshes, or skip
the node's address reads on a guard that never cleared.

Every claim is observed from the outside, through the surfaces a
runner uses: the session through the public tip and confirmation
readers, the follower through 'awaitIndexed', the guard through
'adaptProvider' and the address-read counter. Each positive half
proves the state really was installed, so the refusal that follows is
the bracket's cleanup and not a test that never set anything up.
-}
module Singular.Registry.NodeCleanupSpec (spec) where

import Control.Exception (ErrorCall, throwIO, try)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe, isJust)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Test.Hspec (
    Selector,
    Spec,
    describe,
    it,
    shouldBe,
    shouldReturn,
    shouldThrow,
 )

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.BaseTypes (Network (..), SlotNo (..))
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle,
    withInMemoryIndexer,
 )
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node (
    NodeMode (..),
    NodeSession (..),
    adaptProvider,
    awaitIndexed,
    currentTipSlot,
    nodeAddressReads,
 )
import Singular.Registry.Node.Indexer (Following (..), currentFollower, markFundingIndexed, withFollowing)
import Singular.Registry.Node.Session (withOpenSession)
import Singular.Registry.Provider qualified as Cage

spec :: Spec
spec = describe "what a runner leaves behind when its body ends" $ do
    describe "the open session" $ do
        it "answers the session's tip while the body runs" $
            withOpenSession stubSession currentTipSlot
                `shouldReturn` SlotNo 7

        it "is removed when the body fails" $ do
            leaveBehind . withOpenSession stubSession . throwIO $
                userError "the runner body failed"
            currentTipSlot `shouldThrow` outsideSession

        it "is removed when the body returns" $ do
            _ <- withOpenSession stubSession (pure ())
            currentTipSlot `shouldThrow` outsideSession

    describe "the follower a session installs" $ do
        it "is installed for the body" $
            withInMemoryIndexer $ \idx ->
                withFollowing (stubFollowing idx) $
                    isJust <$> currentFollower
                        `shouldReturn` True

        it "is removed when the body fails" $
            withInMemoryIndexer $ \idx -> do
                leaveBehind . withFollowing (stubFollowing idx) . throwIO $
                    userError "the runner body failed"
                isJust <$> currentFollower `shouldReturn` False
                awaitIndexed basicTx `shouldThrow` outsideFollowChain

        it "is removed when the body returns" $
            withInMemoryIndexer $ \idx -> do
                _ <- withFollowing (stubFollowing idx) (pure ())
                isJust <$> currentFollower `shouldReturn` False
                awaitIndexed basicTx `shouldThrow` outsideFollowChain

    describe "the funding-read guard" $ do
        it "refuses node address reads once the funding read is done" $
            withInMemoryIndexer $ \idx ->
                withFollowing (stubFollowing idx) $ do
                    markFundingIndexed
                    Cage.queryUTxOs (adaptProvider unusedNode) zeroHashAddr
                        `shouldThrow` guardRefuses

        it "lets node address reads through again once the body has failed" $
            withInMemoryIndexer $ \idx -> do
                leaveBehind . withFollowing (stubFollowing idx) $ do
                    markFundingIndexed
                    throwIO (userError "the runner body failed")
                before <- nodeAddressReads
                Cage.queryUTxOs (adaptProvider unusedNode) zeroHashAddr
                    `shouldReturn` []
                after <- nodeAddressReads
                (after - before) `shouldBe` 1

{- | Run a body whose only purpose is to fail, and swallow its failure:
what matters is the state the bracket left behind.
-}
leaveBehind :: IO () -> IO ()
leaveBehind body = do
    _ <- (try body :: IO (Either IOError ()))
    pure ()

-- | The refusal every session reader names outside a session.
outsideSession :: Selector ErrorCall
outsideSession e = "called outside a node session" `isInfixOf` show e

-- | The refusal 'awaitIndexed' names outside a followed chain.
outsideFollowChain :: Selector ErrorCall
outsideFollowChain e =
    "awaitIndexed was called outside followChain" `isInfixOf` show e

-- | The refusal 'adaptProvider' names once the funding read is done.
guardRefuses :: Selector ErrorCall
guardRefuses e =
    "sent to the node of a followed devnet" `isInfixOf` show e

-- | A session whose tip is a constant; nothing else of it is read.
stubSession :: NodeSession
stubSession =
    NodeSession
        { nsProvider = neverQueried
        , nsSubmitter = Submitter (\_ -> pure (Rejected "unused submitter"))
        , nsMagic = NetworkMagic 42
        , nsNetwork = Testnet
        , nsPParams = emptyPParams
        , nsScriptRegistered = pure . const False
        , nsTipSlot = pure (SlotNo 7)
        , nsMode = Devnet
        }

-- | A follower around a real in-memory indexer; no chain is followed.
stubFollowing :: IndexerHandle -> Following
stubFollowing idx = Following{followingIndexer = idx, followingFromOrigin = True}

{- | The node side of 'adaptProvider': only its address reads are ever
exercised here, and they answer nothing.
-}
unusedNode :: Provider IO
unusedNode =
    Provider
        { withAcquired = \k -> k (error "the cleanup spec never acquires a query handle")
        , queryUTxOs = \_ -> pure []
        , queryUTxOByTxIn = \_ -> error "the cleanup spec never queries by input"
        , queryProtocolParams = pure (error "the cleanup spec never reads parameters")
        , queryLedgerSnapshot = pure (error "the cleanup spec never reads a snapshot")
        , queryStakeRewards = \_ -> pure (error "the cleanup spec never reads rewards")
        , queryRewardAccounts = \_ -> pure (error "the cleanup spec never reads accounts")
        , queryVoteDelegatees = \_ -> pure (error "the cleanup spec never reads delegates")
        , queryTreasury = pure (error "the cleanup spec never reads the treasury")
        , queryGovernanceState = pure (error "the cleanup spec never reads governance")
        , evaluateTx = \_ -> pure (error "the cleanup spec never evaluates a transaction")
        , posixMsToSlot = \_ -> pure (error "the cleanup spec never converts time to slots")
        , posixMsCeilSlot = \_ -> pure (error "the cleanup spec never converts time to slots")
        , queryUpperBoundSlot = \_ -> pure (error "the cleanup spec never bounds validity")
        }

-- | The provider of the stub session, never queried.
neverQueried :: Cage.Provider IO
neverQueried =
    Cage.Provider
        { Cage.queryUTxOs = \_ -> error "the stub session is never queried"
        , Cage.queryProtocolParams = pure (error "the stub session is never queried")
        , Cage.evaluateTx = \_ -> pure (error "the stub session is never queried")
        , Cage.posixMsToSlot = \_ -> pure (error "the stub session is never queried")
        , Cage.posixMsCeilSlot = \_ -> pure (error "the stub session is never queried")
        }

-- | A transaction that creates nothing; only its identity is read.
basicTx :: ConwayTx
basicTx = mkBasicTx mkBasicTxBody

-- | An address of the all-zero verification key hash, never funded.
zeroHashAddr :: Addr
zeroHashAddr =
    Addr
        Testnet
        (KeyHashObj (KeyHash zeroKeyHash))
        StakeRefNull
  where
    zeroKeyHash =
        fromMaybe
            (error "hashFromBytes refused the 28 zero bytes")
            (hashFromBytes (BS.pack (replicate 28 0)))
