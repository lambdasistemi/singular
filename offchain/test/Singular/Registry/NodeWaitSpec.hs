{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.NodeWaitSpec
Description : The bound every wait on a submitted transaction obeys
License     : Apache-2.0

A run waits on a submitted transaction in three places: for the node's
verdict on the submission, for the followed indexer to show the
transaction's first output, and for a session confirmation of that
output. None of the three may outlive a known bound: a stalled node
must cost minutes, not a manual interrupt, and the failure must name
the transaction and the elapsed time rather than read as a ledger
refusal or an acceptance.

Every negative case runs its subject under its own time guard, so a
wait that does not end fails the case instead of hanging the suite.
The prompt halves prove those guards are not vacuous: a verdict, an
indexed output and a still-open window all return as before, and a
closed confirmation window ends as the same named failure, never as a
refusal a classifier could publish.
-}
module Singular.Registry.NodeWaitSpec (spec) where

import Control.Concurrent (forkIO, myThreadId, threadDelay)
import Control.Exception
    ( AsyncException (UserInterrupt)
    , ErrorCall (..)
    , finally
    , fromException
    , getMaskingState
    , throwIO
    , throwTo
    , try
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Timeout (timeout)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )
import Text.Read (readMaybe)

import Lens.Micro ((&), (.~))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , SlotNo (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle (..)
    , UtxoOp (..)
    , withInMemoryIndexer
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node.Confirmation
    ( awaitTx
    , awaitTxId
    , awaitTxWindow
    , confirmWithin
    , windowReadBound
    )
import Singular.Registry.Node.Indexer
    ( Following (..)
    , awaitIndexedWithin
    , confirmationAttempts
    , confirmationPollSeconds
    , withFollowing
    )
import Singular.Registry.Node.Options (NodeMode (..))
import Singular.Registry.Node.Session
    ( NodeSession (..)
    , withOpenSession
    )
import Singular.Registry.Node.Wait
    ( WaitFailure (..)
    , WaitStage (..)
    , boundWait
    , boundedSubmitter
    , submissionBound
    , tryOutcome
    )
import Singular.Registry.Provider qualified as Cage

spec :: Spec
spec =
    describe "the bound every wait on a submitted transaction obeys" $ do
        describe "a submission the node never decides" $ do
            it "ends as the named wait failure within its bound" $ do
                w <-
                    theWaitFailure 6_000_000 "the submission" $
                        stalledSubmission 1
                waitStage w `shouldBe` SubmissionWait
                waitTxId w `shouldBe` basicTxId
                waitBound w `shouldBe` 1
                waitElapsed w
                    `shouldSatisfy` (\s -> s >= 0.9 && s < 4)
                let rendering = show w
                rendering `shouldSatisfy` isInfixOf "submission wait"
                rendering
                    `shouldSatisfy` isInfixOf (txIdHex basicTxId)
                rendering
                    `shouldSatisfy` isInfixOf "against its 1 s bound"
                rendering
                    `shouldSatisfy` isInfixOf "returned no verdict"
                case renderedElapsed rendering of
                    Nothing ->
                        fail "the failure does not render an elapsed time"
                    Just s ->
                        s `shouldSatisfy` (\x -> x >= 0.9 && x < 4)

            it "passes a prompt acceptance through unchanged" $ do
                r <- promptSubmission (Submitted basicTxId)
                case r of
                    Submitted tid -> tid `shouldBe` basicTxId
                    Rejected why ->
                        fail ("became a refusal: " <> show why)

            it "passes a prompt refusal through unchanged" $ do
                r <- promptSubmission (Rejected "a reason")
                case r of
                    Rejected why -> why `shouldBe` "a reason"
                    Submitted tid ->
                        fail ("became an acceptance: " <> show tid)

            it "cancels the waiting thread when the bound fires" $ do
                cleaned <- newIORef False
                w <-
                    theWaitFailure 6_000_000 "the submission" $
                        boundWait SubmissionWait basicTxId 1 $
                            finally
                                (threadDelay 600_000_000)
                                (writeIORef cleaned True)
                waitStage w `shouldBe` SubmissionWait
                readIORef cleaned `shouldReturn` True

            it "runs the wait in the masking state of its caller" $ do
                outside <- getMaskingState
                inside <-
                    boundWait
                        SubmissionWait
                        basicTxId
                        10
                        getMaskingState
                inside `shouldBe` outside

            it "lets a caller's exception through while the wait runs" $ do
                us <- myThreadId
                _ <-
                    forkIO
                        ( threadDelay 200_000
                            >> throwTo us (ErrorCall "interrupted")
                        )
                let endless = threadDelay 600_000_000
                r <-
                    try (boundWait SubmissionWait basicTxId 10 endless)
                case r of
                    Left (err :: ErrorCall) ->
                        show err
                            `shouldSatisfy` isInfixOf "interrupted"
                    Right () ->
                        fail "the wait outlived the caller's exception"

        describe "the indexed confirmation window" $ do
            it "ends as the named wait failure when the indexer never \
               \shows the output" $
                withFollowedIndexer $ \_ -> do
                    w <-
                        theWaitFailure 6_000_000 "the indexed wait" $
                            awaitIndexedWithin 1 basicTx
                    waitStage w `shouldBe` IndexedConfirmationWait
                    waitTxId w `shouldBe` basicTxId
                    waitBound w `shouldBe` 1
                    waitElapsed w
                        `shouldSatisfy` (\s -> s >= 0.9 && s < 4)
                    show w
                        `shouldSatisfy` isInfixOf (txIdHex basicTxId)

            it "returns when the indexer shows the transaction's \
               \output zero" $
                withFollowedIndexer $ \idx -> do
                    applyOutputZero idx
                    r <-
                        timeout
                            6_000_000
                            (awaitIndexedWithin 1 basicTx)
                    r `shouldBe` Just ()

            it "returns while already waiting for the output" $
                withFollowedIndexer $ \idx -> do
                    _ <-
                        forkIO
                            ( threadDelay 200_000
                                >> applyOutputZero idx
                            )
                    r <-
                        timeout
                            6_000_000
                            (awaitIndexedWithin 5 basicTx)
                    r `shouldBe` Just ()

        describe "the session confirmation limit" $ do
            it "ends the whole wait when the chain's tip stops advancing" $
                withFollowedIndexer $ \_ -> do
                    w <-
                        theWaitFailure 8_000_000 "the session wait" $
                            confirmWithin
                                3
                                stubSession
                                "a stalled tip"
                                basicTxId
                                (SlotNo 100)
                    waitStage w `shouldBe` SessionConfirmationWait
                    waitTxId w `shouldBe` basicTxId
                    waitBound w `shouldBe` 3
                    waitElapsed w
                        `shouldSatisfy` (\s -> s >= 2.9 && s < 6)

            it "ends the whole wait when the tip read itself never \
               \returns" $
                withFollowedIndexer $ \_ -> do
                    released <- newIORef False
                    w <-
                        theWaitFailure 10_000_000 "the session wait" $
                            confirmWithin
                                4
                                (blockedTipSession released)
                                "a blocked tip read"
                                basicTxId
                                (SlotNo 100)
                    waitStage w `shouldBe` SessionConfirmationWait
                    waitBound w `shouldBe` 4
                    readIORef released `shouldReturn` True

            it "returns when the indexer shows the output, tip or not" $
                withFollowedIndexer $ \idx -> do
                    applyOutputZero idx
                    r <-
                        timeout
                            6_000_000
                            ( confirmWithin
                                10
                                stubSession
                                "an observed output"
                                basicTxId
                                (SlotNo 100)
                            )
                    r `shouldBe` Just ()

            it "ends at the window the tip deadline closes, as the wait \
               \failure carrying the deadline slot" $
                withFollowedIndexer $ \_ -> do
                    w <-
                        theWaitFailure 12_000_000 "a closed window" $
                            confirmWithin
                                10
                                pastDeadlineSession
                                "a closed window"
                                basicTxId
                                (SlotNo 100)
                    waitStage w `shouldBe` SessionConfirmationWait
                    waitTxId w `shouldBe` basicTxId
                    waitBound w `shouldBe` 10
                    waitClosedAt w `shouldBe` Just (SlotNo 100)
                    waitElapsed w `shouldSatisfy` (< 5)
                    show w `shouldSatisfy` isInfixOf "closed at slot 100"

            it "ends the public awaitTx on a closed window as the wait \
               \failure naming its deadline slot" $
                withFollowedIndexer $ \_ ->
                    withOpenSession pastWindowSession $ do
                        w <-
                            theWaitFailure 12_000_000 "awaitTx" $
                                awaitTx txWithBoundOutput
                        waitStage w `shouldBe` SessionConfirmationWait
                        waitTxId w `shouldBe` txIdTx txWithBoundOutput
                        waitClosedAt w `shouldBe` Just (SlotNo 1120)
                        show w `shouldSatisfy` isInfixOf "closed at slot 1120"

            it "does not let a closed window read as a refusal" $
                withFollowedIndexer $ \_ ->
                    withOpenSession pastWindowSession $ do
                        r <-
                            try
                                ( timeout
                                    12_000_000
                                    (tryOutcome (awaitTx txWithBoundOutput))
                                )
                        case r of
                            Left w ->
                                waitClosedAt w `shouldBe` Just (SlotNo 1120)
                            Right Nothing ->
                                fail "the closed window never ended"
                            Right (Just (Left e)) ->
                                fail ("classified a closed window: " <> show e)
                            Right (Just (Right ())) ->
                                fail "confirmed a transaction never shown"

            it "bounds the public awaitTx with the derived window" $
                withFollowedIndexer $ \_ ->
                    withOpenSession slotSession $ do
                        w <-
                            theWaitFailure 8_000_000 "awaitTx" $
                                awaitTx txWithBoundOutput
                        waitStage w `shouldBe` SessionConfirmationWait
                        waitTxId w `shouldBe` txIdTx txWithBoundOutput

            it "leaves a still-valid transaction its whole window" $
                withFollowedIndexer $ \_ ->
                    withOpenSession slotSession $ do
                        tx <- txValidForAnHour
                        r <- timeout 5_000_000 (awaitTx tx)
                        r `shouldBe` Nothing

            it "leaves a transaction that never expires the fixed window" $
                withFollowedIndexer $ \_ ->
                    withOpenSession slotSession $ do
                        r <-
                            timeout
                                5_000_000
                                (awaitTx (txWithOutput SNothing))
                        r `shouldBe` Nothing

        describe "the reads that derive a confirmation's window" $ do
            it "ends awaitTx when the time-to-slot read never returns" $
                withFollowedIndexer $ \_ ->
                    withOpenSession blockedSlotSession $ do
                        w <-
                            theWaitFailure 45_000_000 "awaitTx" $
                                awaitTx txWithBoundOutput
                        theReadFailure w (txIdTx txWithBoundOutput)

            it "ends awaitTxWindow when the time-to-slot read never \
               \returns" $
                withFollowedIndexer $ \_ ->
                    withOpenSession blockedSlotSession $ do
                        w <-
                            theWaitFailure 45_000_000 "awaitTxWindow" $
                                awaitTxWindow
                                    txWithBoundOutput
                                    (txIdHex (txIdTx txWithBoundOutput))
                        theReadFailure w (txIdTx txWithBoundOutput)

            it "ends awaitTx when the fallback tip read never returns" $
                withFollowedIndexer $ \_ -> do
                    released <- newIORef False
                    let session = unconvertibleBlockedTipSession released
                    withOpenSession session $ do
                        w <-
                            theWaitFailure 45_000_000 "awaitTx" $
                                awaitTx txWithBoundOutput
                        theReadFailure w (txIdTx txWithBoundOutput)
                        readIORef released `shouldReturn` True

            it "ends awaitTxId when the time-to-slot read never returns" $
                withFollowedIndexer $ \_ ->
                    withOpenSession blockedSlotSession $ do
                        w <-
                            theWaitFailure 45_000_000 "awaitTxId" $
                                awaitTxId (txIdHex basicTxId)
                        theReadFailure w basicTxId

        describe "the production bounds" $ do
            it "keeps the submission bound inside the confirmation \
               \window" $ do
                submissionBound `shouldSatisfy` (> 0)
                submissionBound `shouldSatisfy` (<= indexedWindow)

            it "keeps the indexed window at 300 seconds" $
                indexedWindow `shouldBe` 300

        describe "the wait-aware catch" $ do
            it "returns an ordinary exception as a failure" $ do
                r <- tryOutcome (throwIO (ErrorCall "the fold was refused"))
                case r of
                    Left e ->
                        show e
                            `shouldSatisfy` isInfixOf "the fold was refused"
                    Right () -> fail "the exception vanished"

            it "returns a value unchanged" $ do
                r <- tryOutcome (pure (7 :: Int))
                case r of
                    Right n -> n `shouldBe` 7
                    Left e -> fail ("a value became a failure: " <> show e)

            it "lets the wait failure pass unclassified" $ do
                r <- try (tryOutcome (throwIO theFailure))
                case r of
                    Left w -> waitStage w `shouldBe` SubmissionWait
                    Right (Left e) ->
                        fail ("classified the wait failure: " <> show e)
                    Right (Right ()) -> fail "the wait failure vanished"

            it "lets an asynchronous exception propagate" $ do
                r <- try (tryOutcome (throwIO UserInterrupt))
                case r of
                    Left UserInterrupt -> pure ()
                    Left other -> fail ("propagated as " <> show other)
                    Right (Left e) ->
                        fail ("classified an async exception: " <> show e)
                    Right (Right ()) -> fail "the exception vanished"

{- | The wait failure an action raised, or a named complaint when the
action did not end within its guard, returned a value instead of
failing, or failed as some other exception. The guard is what makes a
wait that does not end a failing case rather than a hanging one, and
the value branch is what keeps a stalled submission from reading as a
verdict. The guard sits inside the catch so that its own expiry is
never mistaken for the action's failure.
-}
theWaitFailure
    :: (Show a)
    => Int
    -> String
    -> IO a
    -> IO WaitFailure
theWaitFailure guardMicros what action = do
    outcome <- try (timeout guardMicros action)
    case outcome of
        Right Nothing ->
            fail (what <> " did not end within its time guard")
        Right (Just a) ->
            fail (what <> " returned " <> show a)
        Left e ->
            case fromException e of
                Nothing -> fail (what <> " failed as " <> show e)
                Just w -> pure w

{- | What a stalled node read while a confirmation derives its window
must end as: the wait failure of the session confirmation stage, on the
transaction, under the read bound, after that long.
-}
theReadFailure :: WaitFailure -> TxId -> IO ()
theReadFailure w tid = do
    waitStage w `shouldBe` SessionConfirmationWait
    waitTxId w `shouldBe` tid
    waitBound w `shouldBe` windowReadBound
    waitElapsed w
        `shouldSatisfy` ( \s ->
                            s >= fromIntegral windowReadBound - 0.1
                                && s < fromIntegral windowReadBound + 10
                        )

{- | The elapsed seconds a wait failure's rendering carries, read back
out of it: the rendering must say what was measured, not something a
template invented.
-}
renderedElapsed :: String -> Maybe Double
renderedElapsed rendering = do
    rest <- afterMark "after " rendering
    readMaybe (takeWhile (/= ' ') rest)
  where
    afterMark mark s =
        listToMaybe
            [drop (length mark) t | t <- tails s, mark `isPrefixOf` t]

-- | Submit the spec's basic transaction through a bounded submitter
-- the node never answers.
stalledSubmission :: Int -> IO SubmitResult
stalledSubmission bound =
    submitTx (boundedSubmitter bound neverDecides) basicTx

-- | The production indexed confirmation window, in seconds.
indexedWindow :: Int
indexedWindow = confirmationAttempts * confirmationPollSeconds

-- | Submit the spec's basic transaction through a bounded submitter
-- that answers at once.
promptSubmission :: SubmitResult -> IO SubmitResult
promptSubmission result =
    submitTx (boundedSubmitter 1 (prompt result)) basicTx

-- | A transaction id's raw bytes, as the indexer keys them.
txIdBytes :: TxId -> BS.ByteString
txIdBytes (TxId h) = hashToBytes (extractHash h)

-- | A transaction id's hex rendering.
txIdHex :: TxId -> String
txIdHex = BC.unpack . B16.encode . txIdBytes

-- | A submitter that answers at once with the given result.
prompt :: SubmitResult -> Submitter IO
prompt result = Submitter (\_ -> pure result)

-- | A submitter the node never answers: no verdict ever arrives.
neverDecides :: Submitter IO
neverDecides =
    Submitter
        (\_ -> threadDelay 600_000_000 >> pure (Submitted basicTxId))

{- | Run an action with a real in-memory indexer installed as the
process's followed chain. No chain is followed; the indexer observes
only what the spec applies to it.
-}
withFollowedIndexer :: (IndexerHandle -> IO a) -> IO a
withFollowedIndexer action =
    withInMemoryIndexer $ \idx ->
        withFollowing (stubFollowing idx) (action idx)

-- | Apply the block that creates output zero of the spec's basic
-- transaction, waking any wait already watching for it.
applyOutputZero :: IndexerHandle -> IO ()
applyOutputZero idx =
    applyAtSlot
        idx
        (Indexer.SlotNo 1)
        (Indexer.BlockHash (BS.pack (replicate 32 7)))
        [ UtxoCreate
            (Indexer.TxIn (txIdBytes basicTxId) 0)
            (Indexer.Address (BC.pack "watched"))
            (Indexer.TxOut (BC.pack "an output"))
        ]

-- | A follower around a real in-memory indexer; no chain is followed.
stubFollowing :: IndexerHandle -> Following
stubFollowing idx =
    Following{followingIndexer = idx, followingFromOrigin = True}

-- | A session whose tip never moves and whose provider is never read.
stubSession :: NodeSession
stubSession =
    NodeSession
        { nsProvider = neverQueried
        , nsSubmitter = prompt (Rejected "unused submitter")
        , nsMagic = NetworkMagic 42
        , nsNetwork = Testnet
        , nsPParams = emptyPParams
        , nsScriptRegistered = \_ -> pure False
        , nsTipSlot = pure (SlotNo 7)
        , nsMode = Devnet
        }

{- | A session whose tip read never returns, releasing the marker when
the read is cancelled.
-}
blockedTipSession :: IORef Bool -> NodeSession
blockedTipSession released =
    stubSession
        { nsTipSlot =
            finally
                (threadDelay 600_000_000 >> pure (SlotNo 7))
                (writeIORef released True)
        }

-- | A session whose tip has already passed any deadline it is given.
pastDeadlineSession :: NodeSession
pastDeadlineSession = stubSession{nsTipSlot = pure (SlotNo 200)}

{- | The one-slot-per-second session whose time-to-slot conversion never
returns.
-}
blockedSlotSession :: NodeSession
blockedSlotSession =
    slotSession
        { nsProvider =
            slotProv
                { Cage.posixMsToSlot =
                    \_ -> threadDelay 600_000_000 >> pure (SlotNo 0)
                }
        }

{- | A session whose time-to-slot conversion fails at once, so the wait
falls back to the tip, and whose tip read never returns, releasing the
marker when the read is cancelled.
-}
unconvertibleBlockedTipSession :: IORef Bool -> NodeSession
unconvertibleBlockedTipSession released =
    (blockedTipSession released)
        { nsProvider =
            slotProv
                { Cage.posixMsToSlot =
                    \_ -> throwIO (userError "the time cannot be converted")
                }
        }

{- | The one-slot-per-second session whose tip is long past the window
of a transaction valid until slot 1000.
-}
pastWindowSession :: NodeSession
pastWindowSession = slotSession{nsTipSlot = pure (SlotNo 5000)}

{- | The stub session over the one-slot-per-second provider: the
public confirmation path derives its window through it.
-}
slotSession :: NodeSession
slotSession = stubSession{nsProvider = slotProv}

{- | A provider whose chain numbers one slot per second. Only the
time-to-slot conversion is ever read.
-}
slotProv :: Cage.Provider IO
slotProv =
    Cage.Provider
        { Cage.queryUTxOs = \_ -> pure []
        , Cage.queryProtocolParams = pure (error "unused")
        , Cage.evaluateTx = \_ -> pure (error "unused")
        , Cage.posixMsToSlot = pure . SlotNo . fromIntegral . (`div` 1000)
        , Cage.posixMsCeilSlot =
            pure . SlotNo . fromIntegral . (\ms -> (ms + 999) `div` 1000)
        }

-- | The provider of the stub sessions, never queried.
neverQueried :: Cage.Provider IO
neverQueried =
    Cage.Provider
        { Cage.queryUTxOs = \_ -> error "the stub session is never queried"
        , Cage.queryProtocolParams =
            pure (error "the stub session is never queried")
        , Cage.evaluateTx = \_ -> error "the stub session is never queried"
        , Cage.posixMsToSlot =
            pure (error "the stub session is never queried")
        , Cage.posixMsCeilSlot =
            pure (error "the stub session is never queried")
        }

-- | A transaction that creates nothing; only its identity is read.
basicTx :: ConwayTx
basicTx = mkBasicTx mkBasicTxBody

-- | The identity of the spec's basic transaction.
basicTxId :: TxId
basicTxId = txIdTx basicTx

-- | A wait failure on the spec's basic transaction.
theFailure :: WaitFailure
theFailure =
    WaitFailure
        { waitStage = SubmissionWait
        , waitTxId = basicTxId
        , waitElapsed = 1
        , waitBound = 1
        , waitClosedAt = Nothing
        }

{- | A transaction that creates one output and pins a validity upper
bound the one-slot-per-second chain has long passed: its confirmation
window is already closed, so a bounded wait on it ends through the
derived limit rather than through a live window.
-}
txWithBoundOutput :: ConwayTx
txWithBoundOutput = txWithOutput (SJust 1000)

{- | A transaction whose validity ends an hour from now on the
one-slot-per-second chain of 'slotProv': its confirmation window is
open for an hour of wall clock.
-}
txValidForAnHour :: IO ConwayTx
txValidForAnHour = do
    now <- getCurrentTime
    let seconds = round (utcTimeToPOSIXSeconds now) :: Integer
    pure (txWithOutput (SJust (SlotNo (fromIntegral (seconds + 3600)))))

-- | A transaction that creates one output, valid until the given slot.
txWithOutput :: StrictMaybe SlotNo -> ConwayTx
txWithOutput upper =
    mkBasicTx
        ( mkBasicTxBody
            & outputsTxBodyL .~ StrictSeq.singleton theOutput
            & vldtTxBodyL .~ ValidityInterval SNothing upper
        )
  where
    theOutput = mkBasicTxOut zeroHashAddr (inject (Coin 1_000_000))

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
