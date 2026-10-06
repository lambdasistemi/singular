{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.IndexerViewSpec
Description : #324 — an indexer view reads the index and the node at one chain point
License     : Apache-2.0

The indexer adapter serves the #323 read interface: a view's address
reads come from the in-process UTxO index, every other read from a node
view, and both are answered at the node view's chain point. These rows
hold it to that contract against a real in-memory index, written only
through the gated handle a follower receives, and a deterministic
in-memory chain standing in for the node.

Every chain point a row compares against is read from the in-memory
chain's own view, and every expected read is that chain's answer at the
same point; no row types a hash or an output list it then expects back.
The index learns a block only when a row applies it, so a row can hold
the index one block behind the node, on a different block at the node's
slot, or frozen under a held view, and require the adapter to refuse
the mixture by name rather than answer from whichever point the index
happens to be at.
-}
module Singular.Registry.IndexerViewSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
    ( newEmptyMVar
    , putMVar
    , readMVar
    , takeMVar
    , tryReadMVar
    )
import Control.Concurrent.STM
    ( atomically
    , readTVar
    , writeTVar
    )
import Control.Exception
    ( ErrorCall (..)
    , displayException
    , throwIO
    , try
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Singular.Registry.SyntheticTime (syntheticTime)
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.N2C.Reconnect
    ( DisconnectInfo (..)
    , UpstreamStatus (..)
    )
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    , Readiness (..)
    )
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle (..)
    , withInMemoryIndexer
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer

import Control.Tracer (nullTracer)
import Singular.PhaseLogFixture
    ( logObjects
    , numberField
    , phaseLines
    , queryNames
    , textField
    , withLogFile
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.IndexerRig
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams)
import Singular.Registry.Node (bech32Address)
import Singular.Registry.Node.IndexGate
    ( Coverage (..)
    , IndexedPoint (..)
    , gateServed
    , gatedHandle
    , indexedPoint
    , withHeldIndex
    )
import Singular.Registry.Node.Indexer
    ( Following (..)
    , awaitIndexedWithin
    , currentFollower
    )
import Singular.Registry.Node.IndexerView
    ( IndexerReadiness (..)
    , IndexerViewFailure (..)
    , awaitIndexerReady
    , indexerProvider
    , requireCovered
    )
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , memoryProvider
    )
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , SlotNo (..)
    , View (..)
    )
import Singular.Registry.ProviderTrace (tracedProvider)
import Singular.Registry.StubFollowing (withStubFollowing)
import Singular.Registry.TraceRender (readPhaseLog)
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)

spec :: Spec
spec = describe
    "an indexer view reads the index and the node at one chain point (#324)"
    $ do
        gateSpec
        agreementSpec
        heldSpec
        refusalSpec
        backendSpec
        phaseLogSpec

-- ---------------------------------------------------------
-- The phase log of the index's reads (#363)
-- ---------------------------------------------------------

phaseLogSpec :: Spec
phaseLogSpec = describe "the phase log of the index's reads (#363)" $ do
    it
        "an address read answered by the index is its admission and its read, \
        \one line each, around one view"
        $ withRig fullCoverage
        $ \rig -> withLogFile $ \path -> do
            _ <- produce rig firstBlock >>= indexed rig
            answer <-
                withView
                    ( tracedProvider
                        (readPhaseLog path)
                        (adapterTraced (readPhaseLog path) rig longBound)
                    )
                    (`viewUTxOsAt` payer)
            objects <- logObjects path
            sort (queryNames objects) `shouldBe` ["indexAdmit", "utxosAt"]
            [ numberField "answer_size" o
              | o <- phaseLines "query" objects
              , textField "query" o == Just "utxosAt"
              ]
                `shouldBe` [Just (fromIntegral (length answer))]
            length answer `shouldSatisfy` (> 1)
            length (phaseLines "view" objects) `shouldBe` 1
    it
        "the coverage check acquires one node view, logged with its point, \
        \and reads the node and the index once each, beside its admission"
        $ withRig fullCoverage
        $ \rig -> withLogFile $ \path -> do
            p <- produce rig firstBlock >>= indexed rig
            acquired <- newIORef (0 :: Int)
            let node =
                    Provider $ \act -> do
                        atomicModifyIORef' acquired (\n -> (n + 1, ()))
                        withView (memoryProvider (rigChain rig)) act
            requireCovered
                (readPhaseLog path)
                (rigGate rig)
                (readinessOf rig)
                longBound
                node
                payer
            objects <- logObjects path
            -- the node's own count of acquisitions is the expectation
            readIORef acquired >>= (`shouldBe` 1)
            map
                (\o -> (numberField "slot" o, textField "hash" o))
                (phaseLines "view" objects)
                `shouldBe` [
                               ( Just (fromIntegral (unSlotNo (cpSlot p)))
                               , Just (T.pack (BC.unpack (B16.encode (cpBlockHash p))))
                               )
                           ]
            sort (queryNames objects)
                `shouldBe` ["coverageIndexRead", "indexAdmit", "utxosAt"]

-- ---------------------------------------------------------
-- The gate the follower writes through
-- ---------------------------------------------------------

gateSpec :: Spec
gateSpec = describe "the gated index" $ do
    it
        "the index's applied point follows its applies and its rollbacks"
        $ withRig fullCoverage
        $ \rig -> do
            atomically (indexedPoint (rigGate rig)) >>= (`shouldBe` Nothing)
            p1 <- produce rig firstBlock >>= indexed rig
            p2 <- produce rig secondBlock >>= indexed rig
            atomically (indexedPoint (rigGate rig))
                >>= (`shouldBe` Just (pointOf p2))
            rollbackTo (rigFollower rig) (toIndexerSlot (cpSlot p1))
            atomically (indexedPoint (rigGate rig))
                >>= (`shouldBe` Just (pointOf p1))
    it
        "admission lets the index advance to the target and no further, \
        \and holds it there until release"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            (p2, applySecond) <- produce rig secondBlock
            (_, applyThird) <- produce rig thirdBlock
            third <- newEmptyMVar
            (verdict, during) <- withHeldIndex (rigGate rig) $ \admit -> do
                _ <- forkIO (threadDelay 100_000 >> applySecond)
                _ <- forkIO (threadDelay 150_000 >> applyThird >> putMVar third ())
                verdict <- admit (pointOf p2) (pure True) 2_000_000
                threadDelay 300_000
                during <- atomically (indexedPoint (rigGate rig))
                pure (verdict, during)
            verdict `shouldBe` Right ()
            during `shouldBe` Just (pointOf p2)
            timeout 2_000_000 (takeMVar third) >>= (`shouldBe` Just ())
    it
        "while admission at a target is pending, a block beyond the target \
        \does not land: the bound expires with the index still below it"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            (p2, _) <- produce rig secondBlock
            (_, applyThird) <- produce rig thirdBlock
            third <- newEmptyMVar
            verdict <- withHeldIndex (rigGate rig) $ \admit -> do
                _ <- forkIO (applyThird >> putMVar third ())
                admit (pointOf p2) (pure True) 500_000
            verdict `shouldBe` Left (Just (pointOf p1))
            timeout 2_000_000 (takeMVar third) >>= (`shouldBe` Just ())
    it
        "the target block, arriving while a block beyond it waits, is admitted; \
        \the block beyond lands only after release"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            (p2, applySecond) <- produce rig secondBlock
            (p3, applyThird) <- produce rig thirdBlock
            third <- newEmptyMVar
            (verdict, during, waiting) <- withHeldIndex (rigGate rig) $ \admit -> do
                _ <- forkIO (applyThird >> putMVar third ())
                _ <- forkIO (threadDelay 300_000 >> applySecond)
                verdict <- admit (pointOf p2) (pure True) 2_000_000
                during <- atomically (indexedPoint (rigGate rig))
                waiting <- tryReadMVar third
                pure (verdict, during, waiting)
            verdict `shouldBe` Right ()
            during `shouldBe` Just (pointOf p2)
            waiting `shouldBe` Nothing
            timeout 2_000_000 (takeMVar third) >>= (`shouldBe` Just ())
            atomically (indexedPoint (rigGate rig))
                >>= (`shouldBe` Just (pointOf p3))
    it
        "an apply and a rollback attempted while the index is held wait for its release"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            (_, applySecond) <- produce rig secondBlock
            done <- newEmptyMVar
            (during, settled) <- withHeldIndex (rigGate rig) $ \admit -> do
                _ <- admit (pointOf p1) (pure True) 2_000_000
                _ <-
                    forkIO
                        ( applySecond
                            >> rollbackTo (rigFollower rig) (toIndexerSlot (cpSlot p1))
                            >> putMVar done ()
                        )
                threadDelay 300_000
                during <- atomically (indexedPoint (rigGate rig))
                settled <- tryReadMVar done
                pure (during, settled)
            during `shouldBe` Just (pointOf p1)
            settled `shouldBe` Nothing
            timeout 2_000_000 (takeMVar done) >>= (`shouldBe` Just ())
    it
        "a confirmation wait inside a hold is refused at once, never left \
        \waiting on an index that cannot move"
        $ withInMemoryIndexer
        $ \idx -> withStubFollowing idx $ do
            gate <-
                currentFollower
                    >>= maybe (fail "no follower installed") (pure . followingGate)
            let blockOne = IndexedPoint (SlotNo 1) (BS.replicate 32 1)
            applyAtSlot
                (gatedHandle gate)
                (toIndexerSlot (ipSlot blockOne))
                (Indexer.BlockHash (ipBlockHash blockOne))
                []
            r <- timeout 2_000_000 $ withHeldIndex gate $ \admit -> do
                _ <- admit blockOne (pure True) 1_000_000
                try (awaitIndexedWithin nullTracer 5 (mkBasicTx mkBasicTxBody))
            case r of
                Nothing -> expectationFailure "the wait outlived its hold"
                Just (Right ()) -> expectationFailure "the wait returned inside the hold"
                Just (Left (ErrorCall msg)) ->
                    msg `shouldSatisfy` isInfixOf "inside an indexer view"
    it
        "a hold whose body fails is released: the next apply completes"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            r <-
                try $ withHeldIndex (rigGate rig) $ \admit -> do
                    _ <- admit (pointOf p1) (pure True) 2_000_000
                    throwIO (ErrorCall "the held body failed")
            r
                `shouldBe` (Left (ErrorCall "the held body failed") :: Either ErrorCall ())
            (_, applySecond) <- produce rig secondBlock
            timeout 2_000_000 applySecond >>= (`shouldBe` Just ())

-- ---------------------------------------------------------
-- Agreement
-- ---------------------------------------------------------

agreementSpec :: Spec
agreementSpec = describe "agreement" $ do
    it
        "a view's address reads equal the in-memory adapter's at the same point"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            (ix, mem) <- bothAt rig
            ixPoint ix `shouldBe` p1
            ixPoint mem `shouldBe` p1
            ix `shouldBe` mem
            length (readsAt ix payer) `shouldBe` 2
    it
        "a block the follower applies after the node view is acquired, before \
        \admission, does not reach the view: it answers at the node's point"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            p2 <- produce rig secondBlock >>= indexed rig
            mem2 <- observeAt (memoryProvider (rigChain rig))
            landed <- newEmptyMVar
            let racing = Provider $ \action ->
                    withView (memoryProvider (rigChain rig)) $ \v -> do
                        (_, applyThird) <- produce rig thirdBlock
                        _ <- forkIO (applyThird >> putMVar landed ())
                        _ <- timeout 300_000 (readMVar landed)
                        action v
            ix <-
                observeAt
                    ( indexerProvider
                        nullTracer
                        (rigGate rig)
                        (readinessOf rig)
                        longBound
                        racing
                    )
            ixPoint ix `shouldBe` p2
            ix `shouldBe` mem2
            timeout 2_000_000 (readMVar landed) >>= (`shouldBe` Just ())
    it
        "an index one block behind the node, holding other outputs, is refused as lag \
        \carrying both points, never answered from its own"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            (p2, _) <- produce rig secondBlock
            r <- try (withView (adapter rig shortBound) (`viewUTxOsAt` payer))
            case r of
                Left
                    IndexerLag
                        { lagNodePoint = node
                        , lagIndexedPoint = held
                        , lagBoundMicros = bound
                        } -> do
                        node `shouldBe` p2
                        held `shouldBe` Just (pointOf p1)
                        bound `shouldBe` shortBound
                Left other -> expectationFailure ("refused as " <> show other)
                Right answer ->
                    expectationFailure
                        ( "answered at the node's slot "
                            <> show (cpSlot p2)
                            <> ": "
                            <> show answer
                        )
    it
        "a follower restoring when the view is acquired and caught up within \
        \the bound is waited for: the view answers at the node's point"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            mem <- observeAt (memoryProvider (rigChain rig))
            setReadiness rig $ \r ->
                r
                    { rProcessedSlot = Just (Indexer.SlotNo 1)
                    , rTipSlot = Just (Indexer.SlotNo 500)
                    }
            _ <-
                forkIO $
                    threadDelay 300_000
                        >> setReadiness
                            rig
                            ( \r ->
                                r
                                    { rProcessedSlot = Just (Indexer.SlotNo 500)
                                    , rTipSlot = Just (Indexer.SlotNo 500)
                                    }
                            )
            ix <- observeAt (adapter rig longBound)
            ixPoint ix `shouldBe` p1
            ix `shouldBe` mem
    it
        "a follower disconnected when the view is acquired and reconnected \
        \within the bound is waited for: the view answers at the node's point"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            mem <- observeAt (memoryProvider (rigChain rig))
            setReadiness rig $ \r ->
                r
                    { rUpstream =
                        UpstreamDisconnected (DisconnectInfo "socket closed" 1 500)
                    }
            _ <-
                forkIO $
                    threadDelay 300_000
                        >> setReadiness rig (\r -> r{rUpstream = UpstreamConnected})
            ix <- observeAt (adapter rig longBound)
            ixPoint ix `shouldBe` p1
            ix `shouldBe` mem
    it
        "a block the index applies while the view is acquired is waited for, \
        \and the view answers at the node's point"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            (p2, applyBlock) <- produce rig secondBlock
            _ <- forkIO (threadDelay 150_000 >> applyBlock)
            ix <- observeAt (adapter rig longBound)
            mem <- observeAt (memoryProvider (rigChain rig))
            ixPoint ix `shouldBe` p2
            ix `shouldBe` mem

-- ---------------------------------------------------------
-- A held view
-- ---------------------------------------------------------

heldSpec :: Spec
heldSpec = describe "a held view" $ do
    it
        "an apply attempted while a view is held is not observed inside it, \
        \and the next view observes it"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            mem1 <- observeAt (memoryProvider (rigChain rig))
            done <- newEmptyMVar
            (inside, settled, p2) <- withView (adapter rig longBound) $ \v -> do
                (p2, applyBlock) <- produce rig secondBlock
                _ <- forkIO (applyBlock >> putMVar done ())
                threadDelay 300_000
                inside <- viewUTxOsAt v payer
                settled <- tryReadMVar done
                pure (inside, settled, p2)
            inside `shouldBe` readsAt mem1 payer
            settled `shouldBe` Nothing
            released <- timeout 2_000_000 (takeMVar done)
            released `shouldBe` Just ()
            next <- observeAt (adapter rig longBound)
            mem2 <- observeAt (memoryProvider (rigChain rig))
            ixPoint next `shouldBe` p2
            next `shouldBe` mem2
    it
        "a rollback attempted while a view is held is not observed inside it"
        $ withRig fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            _ <- produce rig secondBlock >>= indexed rig
            mem2 <- observeAt (memoryProvider (rigChain rig))
            done <- newEmptyMVar
            (inside, settled) <- withView (adapter rig longBound) $ \v -> do
                _ <-
                    forkIO
                        ( rollbackTo (rigFollower rig) (toIndexerSlot (cpSlot p1))
                            >> putMVar done ()
                        )
                threadDelay 300_000
                inside <- viewUTxOsAt v payer
                settled <- tryReadMVar done
                pure (inside, settled)
            inside `shouldBe` readsAt mem2 payer
            settled `shouldBe` Nothing
            released <- timeout 2_000_000 (takeMVar done)
            released `shouldBe` Just ()
            atomically (indexedPoint (rigGate rig))
                >>= (`shouldBe` Just (pointOf p1))
    it
        "a view whose action fails releases the index: the next apply completes"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            r <-
                try
                    ( withView (adapter rig longBound) $ \_ ->
                        throwIO (ErrorCall "the view's action failed")
                    )
            r
                `shouldBe` (Left (ErrorCall "the view's action failed") :: Either ErrorCall ())
            (_, applyBlock) <- produce rig secondBlock
            applied <- timeout 2_000_000 applyBlock
            applied `shouldBe` Just ()
    it
        "a view acquired inside a held view, after the node moved, is refused \
        \within its bound rather than waiting for the outer view"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            inner <- timeout 5_000_000 $ withView (adapter rig longBound) $ \_ -> do
                (_, applyBlock) <- produce rig secondBlock
                _ <- forkIO applyBlock
                try (withView (adapter rig shortBound) (`viewUTxOsAt` payer))
            case inner of
                Nothing -> expectationFailure "the inner view waited past its bound"
                Just (Left IndexerLag{}) -> pure ()
                Just (Left other) -> expectationFailure ("refused as " <> show other)
                Just (Right answer) -> expectationFailure ("answered: " <> show answer)

-- ---------------------------------------------------------
-- Named refusals
-- ---------------------------------------------------------

refusalSpec :: Spec
refusalSpec = describe "named refusals, never an empty or partial answer" $ do
    it
        "an index at the node's slot on a different block is refused as a fork \
        \carrying the slot and both hashes"
        $ withRig fullCoverage
        $ \rig -> do
            (p1, _) <- produce rig firstBlock
            let other = BS.map (+ 1) (cpBlockHash p1)
            applyAtSlot
                (rigFollower rig)
                (toIndexerSlot (cpSlot p1))
                (Indexer.BlockHash other)
                (opsOf forkBlock)
            refusedAs rig $ \case
                IndexerFork{forkSlot, forkNodeHash, forkIndexedHash} ->
                    (forkSlot, forkNodeHash, forkIndexedHash)
                        == (cpSlot p1, cpBlockHash p1, other)
                _ -> False
    it
        "an index that started at a tip is refused as incomplete coverage"
        $ do
            let tipStart =
                    Coverage
                        { coverageStart = Just (IndexedPoint (SlotNo 1) (BS.replicate 32 7))
                        , coverageInterest = IndexAll
                        }
            withRig tipStart $ \rig -> do
                _ <- produce rig firstBlock >>= indexed rig
                refusedAs rig (== IndexerCoverageIncomplete tipStart)
    it
        "an index that filters addresses refuses an address outside its set \
        \and answers one inside it"
        $ do
            let filtered =
                    Coverage
                        { coverageStart = Nothing
                        , coverageInterest =
                            IndexAddressSet
                                (Set.singleton (Indexer.Address (serialiseAddr bystander)))
                        }
            withRig filtered $ \rig -> do
                _ <- produce rig firstBlock >>= indexed rig
                refusedAs rig (== IndexerCoverageIncomplete filtered)
                inSet <- withView (adapter rig longBound) (`viewUTxOsAt` bystander)
                mem <- observeAt (memoryProvider (rigChain rig))
                inSet `shouldBe` readsAt mem bystander
    it
        "an index still restoring is refused, carrying the processed and tip slots"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            atomically $ do
                r <- readTVar (rigReadiness rig)
                writeTVar
                    (rigReadiness rig)
                    r
                        { rProcessedSlot = Just (Indexer.SlotNo 1)
                        , rTipSlot = Just (Indexer.SlotNo 500)
                        }
            refusedAs
                rig
                (== IndexerRestoring (Just (SlotNo 1)) (Just (SlotNo 500)))
    it
        "an index exactly the restoring threshold behind its tip is answered, \
        \one slot more is refused"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            let lagBy n = atomically $ do
                    r <- readTVar (rigReadiness rig)
                    writeTVar
                        (rigReadiness rig)
                        r
                            { rProcessedSlot = Just (Indexer.SlotNo 100)
                            , rTipSlot = Just (Indexer.SlotNo (100 + n))
                            }
            lagBy (irThresholdSlots (readinessOf rig))
            atThreshold <-
                try (withView (adapter rig shortBound) (`viewUTxOsAt` payer))
            mem <- observeAt (memoryProvider (rigChain rig))
            atThreshold
                `shouldBe` ( Right (readsAt mem payer)
                                :: Either IndexerViewFailure [(TxIn, TxOut ConwayEra)]
                           )
            lagBy (irThresholdSlots (readinessOf rig) + 1)
            refusedAs rig $ \case
                IndexerRestoring{} -> True
                _ -> False
    it
        "an index whose upstream is disconnected is refused, carrying its status"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            let down = UpstreamDisconnected (DisconnectInfo "socket closed" 2 1_500)
            atomically $ do
                r <- readTVar (rigReadiness rig)
                writeTVar (rigReadiness rig) r{rUpstream = down}
            refusedAs rig (== IndexerDisconnected down)
    it
        "a node view in an era the index cannot decode is refused as unsupported"
        $ withRigOn genesis{csEra = "Babbage"} fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            refusedAs rig $ \case
                IndexerUnsupported what -> "Babbage" `T.isInfixOf` what
                _ -> False
    it "a node view on another network is refused as unsupported" $
        withRigOn genesis{csNetwork = 7} fullCoverage $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            refusedAs rig $ \case
                IndexerUnsupported what -> "7" `T.isInfixOf` what
                _ -> False

-- ---------------------------------------------------------
-- The indexer backend a singular session opens
-- ---------------------------------------------------------

backendSpec :: Spec
backendSpec = describe "the indexer backend a session opens" $ do
    it
        "a wallet holding outputs no block carried is refused as uncovered, \
        \naming the address, the view point and exactly those outputs"
        $ withRigOn genesis{csUTxO = genesisOutputs} fullCoverage
        $ \rig -> do
            p1 <- produce rig firstBlock >>= indexed rig
            mem <- observeAt (memoryProvider (rigChain rig))
            fromIndex <-
                withView (adapter rig longBound) (`viewUTxOsAt` payer)
            let unseen =
                    [ i
                    | (i, _) <- readsAt mem payer
                    , i `notElem` map fst fromIndex
                    ]
            unseen `shouldBe` Map.keys genesisOutputs
            r <- try (cover rig payer)
            r
                `shouldBe` Left
                    IndexerUncovered
                        { uncoveredAddress = payer
                        , uncoveredPoint = p1
                        , uncoveredOutputs = unseen
                        }
    it
        "a wallet whose outputs blocks carried is admitted, beside one that \
        \is refused"
        $ withRigOn genesis{csUTxO = genesisOutputs} fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            cover rig bystander `shouldReturn` ()
            r <- try (cover rig payer)
            r `shouldSatisfy` \case
                Left IndexerUncovered{} -> True
                _ -> False
    it
        "a wallet is checked at an agreed point: an index one block behind \
        \is refused as lag, never as uncovered"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            _ <- produce rig secondBlock
            r <-
                try
                    ( requireCovered
                        nullTracer
                        (rigGate rig)
                        (readinessOf rig)
                        shortBound
                        (memoryProvider (rigChain rig))
                        payer
                    )
            r `shouldSatisfy` \case
                Left IndexerLag{} -> True
                _ -> False
    it
        "a follower that becomes ready within the bound is waited for; one \
        \still restoring at the bound is refused with its slots"
        $ withRig fullCoverage
        $ \rig -> do
            let restoring =
                    setReadiness rig $ \r ->
                        r
                            { rProcessedSlot = Just (Indexer.SlotNo 1)
                            , rTipSlot = Just (Indexer.SlotNo 500)
                            }
            restoring
            _ <- forkIO $ do
                threadDelay 200_000
                setReadiness rig $ \r -> r{rProcessedSlot = Just (Indexer.SlotNo 500)}
            awaitIndexerReady (readinessOf rig) longBound `shouldReturn` ()
            restoring
            r <- try (awaitIndexerReady (readinessOf rig) shortBound)
            r
                `shouldBe` Left
                    (IndexerRestoring (Just (SlotNo 1)) (Just (SlotNo 500)))
    it
        "every address read the index answers is counted as served by it; \
        \a refused view and the node's own reads count none"
        $ withRig fullCoverage
        $ \rig -> do
            _ <- produce rig firstBlock >>= indexed rig
            gateServed (rigGate rig) `shouldReturn` 0
            withView (adapter rig longBound) $ \v ->
                mapM_ (viewUTxOsAt v) [payer, bystander, payer]
            _ <- observeAt (memoryProvider (rigChain rig))
            gateServed (rigGate rig) `shouldReturn` 3
            _ <- produce rig secondBlock
            _ <-
                try (withView (adapter rig shortBound) (`viewUTxOsAt` payer))
                    :: IO (Either IndexerViewFailure [(TxIn, TxOut ConwayEra)])
            gateServed (rigGate rig) `shouldReturn` 3
    it
        "each refusal renders as one line naming its class and the points \
        \or setting involved"
        $ do
            let point =
                    ChainPoint
                        { cpNetwork = 42
                        , cpEra = "Conway"
                        , cpSlot = SlotNo 6007
                        , cpBlockHash = BS.replicate 32 0xab
                        }
            let hex = BC.unpack . B16.encode
                slotText = show (unSlotNo (cpSlot point))
                nodePoint = slotText <> "." <> hex (cpBlockHash point)
                down = UpstreamDisconnected (DisconnectInfo "socket closed" 2 1_500)
                other = BS.map (+ 1) (cpBlockHash point)
                cases =
                    [
                        ( IndexerLag
                            { lagNodePoint = point
                            , lagIndexedPoint = Just (IndexedPoint (SlotNo 4711) other)
                            , lagBoundMicros = 250_000
                            }
                        , ["(lag)", nodePoint, "4711." <> hex other]
                        )
                    ,
                        ( IndexerFork
                            { forkSlot = cpSlot point
                            , forkNodeHash = cpBlockHash point
                            , forkIndexedHash = other
                            }
                        , ["(fork)", "slot " <> slotText, hex (cpBlockHash point), hex other]
                        )
                    ,
                        ( IndexerCoverageIncomplete
                            Coverage
                                { coverageStart = Just (IndexedPoint (SlotNo 9173) other)
                                , coverageInterest = IndexAll
                                }
                        , ["(coverage-incomplete)", "9173." <> hex other]
                        )
                    ,
                        ( IndexerRestoring (Just (SlotNo 5113)) (Just (SlotNo 7019))
                        , ["(restoring)", "5113", "7019"]
                        )
                    ,
                        ( IndexerDisconnected down
                        , ["(disconnected)", "socket closed"]
                        )
                    ,
                        ( IndexerUnsupported "address reads in era Babbage"
                        , ["(unsupported)", "Babbage"]
                        )
                    ,
                        ( IndexerUncovered
                            { uncoveredAddress = payer
                            , uncoveredPoint = point
                            , uncoveredOutputs = Map.keys genesisOutputs
                            }
                        ,
                            [ "(coverage-incomplete)"
                            , nodePoint
                            , bech32Address payer
                            , "2 output"
                            , replicate 64 '8' <> "#0"
                            , replicate 64 '9' <> "#0"
                            , "genesis"
                            ]
                        )
                    ]
            mapM_
                ( \(failure, parts) -> do
                    let line = displayException failure
                    line `shouldNotSatisfy` elem '\n'
                    line `shouldSatisfy` isPrefixOf "indexer backend refused the read "
                    mapM_ (\p -> line `shouldSatisfy` isInfixOf p) parts
                )
                cases
  where
    cover rig =
        requireCovered
            nullTracer
            (rigGate rig)
            (readinessOf rig)
            longBound
            (memoryProvider (rigChain rig))

-- | Two outputs at the payer that the ledger's initial state holds.
genesisOutputs :: Map.Map TxIn (TxOut ConwayEra)
genesisOutputs =
    Map.fromList
        [ (outRef '8', ada payer 80_000_000)
        , (outRef '9', ada payer 90_000_000)
        ]

-- ---------------------------------------------------------
-- Rig
-- ---------------------------------------------------------

withRig :: Coverage -> (Rig -> IO a) -> IO a
withRig = withRigOn genesis

withRigOn :: ChainState -> Coverage -> (Rig -> IO a) -> IO a
withRigOn = withRigAt (csNetwork genesis)

-- | The adapter refuses the view, never answering an address read.
refusedAs :: Rig -> (IndexerViewFailure -> Bool) -> Expectation
refusedAs rig expected = do
    r <- try (withView (adapter rig shortBound) (`viewUTxOsAt` payer))
    case r of
        Left failure
            | expected failure -> pure ()
            | otherwise -> expectationFailure ("refused as " <> show failure)
        Right answer -> expectationFailure ("answered: " <> show answer)

-- ---------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------

-- | Two outputs at the payer and one at a bystander.
firstBlock :: Block
firstBlock =
    Block
        { spends = []
        , creates =
            [ (outRef '1', ada payer 10_000_000)
            , (outRef '2', ada payer 20_000_000)
            , (outRef '3', ada bystander 30_000_000)
            ]
        }

-- | Spends one payer output and creates another: the payer's content changes.
secondBlock :: Block
secondBlock =
    Block
        { spends = [outRef '1']
        , creates = [(outRef '4', ada payer 40_000_000)]
        }

-- | Creates one more payer output.
thirdBlock :: Block
thirdBlock =
    Block{spends = [], creates = [(outRef '6', ada payer 60_000_000)]}

-- | A block at the first block's slot with other content.
forkBlock :: Block
forkBlock =
    Block{spends = [], creates = [(outRef '5', ada payer 50_000_000)]}

-- ---------------------------------------------------------
-- Observation
-- ---------------------------------------------------------

-- | A view's point, parameters and address reads at both fixture addresses.
data Observed = Observed
    { ixPoint :: ChainPoint
    , ixReads :: [(Addr, [(TxIn, TxOut ConwayEra)])]
    , ixParams :: PParams ConwayEra
    }
    deriving stock (Eq, Show)

observeAt :: Provider IO -> IO Observed
observeAt prov = withView prov $ \v -> do
    reads' <- traverse (\a -> (a,) <$> viewUTxOsAt v a) [payer, bystander]
    pure
        Observed
            { ixPoint = viewPoint v
            , ixReads = reads'
            , ixParams = viewProtocolParams v
            }

bothAt :: Rig -> IO (Observed, Observed)
bothAt rig =
    (,)
        <$> observeAt (adapter rig longBound)
        <*> observeAt (memoryProvider (rigChain rig))

readsAt :: Observed -> Addr -> [(TxIn, TxOut ConwayEra)]
readsAt o a = fromMaybe [] (lookup a (ixReads o))

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
        , csNetworkTime = syntheticTime
        }

outRef :: Char -> TxIn
outRef c =
    either
        (error . ("IndexerViewSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#0")))

ada :: Addr -> Integer -> TxOut ConwayEra
ada addr n = mkBasicTxOut addr (MaryValue (Coin n) mempty)

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

bystander :: Addr
bystander = addrFromKeyHashBytes Testnet (BS.replicate 28 0x6b)
