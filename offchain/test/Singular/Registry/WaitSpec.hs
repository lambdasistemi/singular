module Singular.Registry.WaitSpec (spec) where

import Cardano.Ledger.Api.Tx (txIdTx)
import Control.Concurrent (myThreadId, threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception
    ( AsyncException (..)
    , ErrorCall (..)
    , finally
    , getMaskingState
    , mask_
    , throwIO
    , throwTo
    , try
    )
import Control.Monad qualified
import Data.IORef (newIORef, readIORef, writeIORef)
import Singular.Provider.Koios.Scripted (signedTransaction)
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.Signing (signedTx)
import Singular.Registry.Wait
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "Generic transport waits" $ do
    it
        "cancels a stalled signed submission and retains its transaction identity"
        $ do
            released <- newIORef False
            let send _ =
                    Control.Monad.void (threadDelay 5000000)
                        `finally` writeIORef released True
            result <-
                try
                    (timeout 3000000 (boundedSignedSubmission 1 send signedTransaction))
            case result of
                Left failure -> do
                    waitStage failure `shouldBe` SubmissionWait
                    waitTxId failure `shouldBe` txIdTx (signedTx signedTransaction)
                    waitBound failure `shouldBe` 1
                    waitElapsed failure
                        `shouldSatisfy` (\seconds -> seconds >= 0.9 && seconds < 3)
                    waitClosedAt failure `shouldBe` Nothing
                _ ->
                    expectationFailure
                        "a stalled signed submission did not raise its infrastructure failure"
            readIORef released `shouldReturn` True

    -- Retained obligations from the old node-specific wait spec. They now
    -- exercise the shipping transport-independent bound with actual IO.
    it "preserves prompt signed acceptance and refusal unchanged" $ do
        let accepted = SubmitAccepted identity
            refused = SubmitRefused "original producer refusal"
        boundedSignedSubmission 1 (const (pure accepted)) signedTransaction
            `shouldReturn` accepted
        boundedSignedSubmission 1 (const (pure refused)) signedTransaction
            `shouldReturn` refused

    it "runs the bounded action in its caller's masking state" $ do
        let inspect = do
                outside <- getMaskingState
                inside <- boundWait SubmissionWait identity 10 getMaskingState
                inside `shouldBe` outside
        inspect
        mask_ inspect

    it "propagates the caller's interrupt and cleans the running action" $ do
        caller <- myThreadId
        released <- newIORef False
        let interrupt =
                threadDelay 200000 >> throwTo caller (ErrorCall "caller interrupted")
            action = threadDelay 5000000 `finally` writeIORef released True
        outcome <- withAsync interrupt $ \_ ->
            try (timeout 3000000 (boundWait SubmissionWait identity 10 action))
        case outcome of
            Left failure -> show (failure :: ErrorCall) `shouldBe` "caller interrupted"
            Right _ -> expectationFailure "the bound swallowed the caller's interrupt"
        readIORef released `shouldReturn` True

    it "counts preceding IO in elapsed time from the original wait clock" $ do
        clock <- startWaitClock
        threadDelay 4000000
        outcome <-
            try $
                boundWaitClosingSince
                    clock
                    SessionConfirmationWait
                    identity
                    10
                    (pure (Left 100000 :: Either Integer ()))
        case outcome of
            Left failure -> do
                waitStage failure `shouldBe` SessionConfirmationWait
                waitTxId failure `shouldBe` identity
                waitBound failure `shouldBe` 10
                waitClosedAt failure `shouldBe` Just 100000
                waitElapsed failure
                    `shouldSatisfy` (\seconds -> seconds >= 3.9 && seconds < 10)
            Right () -> expectationFailure "a closed window became success"

    it "keeps a closed POSIX window as the same infrastructure exception" $ do
        clock <- startWaitClock
        result <-
            try $
                boundWaitClosingSince
                    clock
                    SessionConfirmationWait
                    identity
                    10
                    (pure (Left 100000 :: Either Integer ()))
        case result of
            Left failure -> do
                waitStage failure `shouldBe` SessionConfirmationWait
                waitTxId failure `shouldBe` identity
                waitClosedAt failure `shouldBe` Just 100000
                waitBound failure `shouldBe` 10
            Right () -> expectationFailure "the closed window became success"

    it
        "lets wait and asynchronous failures pass through refusal classification"
        $ do
            let failure = WaitFailure SubmissionWait identity 1 1 Nothing
            wait <- try (tryOutcome (throwIO failure :: IO ()))
            case wait of
                Left observed -> show (observed :: WaitFailure) `shouldBe` show failure
                Right _ -> expectationFailure "a wait failure became a classified refusal"
            interrupted <- try (tryOutcome (throwIO UserInterrupt :: IO ()))
            case interrupted of
                Left observed -> observed `shouldBe` UserInterrupt
                Right _ ->
                    expectationFailure
                        "an asynchronous exception became a classified refusal"

    it "preserves prompt verdicts and ordinary synchronous failures" $ do
        boundedSignedSubmission 1 (const (pure (7 :: Int))) signedTransaction
            `shouldReturn` 7
        result <- tryOutcome (throwIO (ErrorCall "original refusal") :: IO ())
        case result of
            Left failure -> show failure `shouldBe` "original refusal"
            Right () -> expectationFailure "an ordinary refusal disappeared"
  where
    identity = txIdTx (signedTx signedTransaction)
