module Singular.Registry.WaitSpec (spec) where

import Cardano.Ledger.Api.Tx (txIdTx)
import Control.Concurrent (threadDelay)
import Control.Exception
    ( AsyncException (..)
    , ErrorCall (..)
    , finally
    , throwIO
    , try
    )
import Data.IORef (newIORef, readIORef, writeIORef)
import Singular.Provider.Koios.Scripted (signedTransaction)
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
            let send _ = (threadDelay 5000000 >> pure ()) `finally` writeIORef released True
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
