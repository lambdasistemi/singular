-- | Bounded signed submission and confirmation waits, independent of transport.
module Singular.Registry.Wait
    ( WaitStage (..)
    , WaitFailure (..)
    , WaitClock
    , startWaitClock
    , boundWait
    , boundWaitSince
    , boundWaitClosingSince
    , submissionBound
    , boundedSignedSubmission
    , tryOutcome
    ) where

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.TxIn (TxId)
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import GHC.Clock (getMonotonicTime)
import Singular.Registry.Signing (SignedTx, signedTx)
import Singular.Registry.WaitTypes (WaitFailure (..), WaitStage (..))
import System.Timeout (timeout)

{- | The start of a wait on the monotonic clock. The public call that
waits takes it at its entry and hands it to every bound it runs under,
so the elapsed time a failure reports covers the whole call — reads
made before the wait proper included — and never less than the time
actually spent.
-}
newtype WaitClock = WaitClock Double

-- | Start a wait's clock.
startWaitClock :: IO WaitClock
startWaitClock = WaitClock <$> getMonotonicTime

{- | Run an action as one wait on a transaction: the whole action, from
its first step to its last, obeys the bound. When it has not returned
after @bound@ seconds the waiting thread is cancelled and the wait
failure is raised. A prompt return passes through unchanged, and the
action's own asynchronous exceptions reach it exactly as without the
wrap: nothing here masks them. The elapsed time the failure reports is
measured from this call.
-}
boundWait :: WaitStage -> TxId -> Int -> IO a -> IO a
boundWait stage tid bound action = do
    clock <- startWaitClock
    boundWaitSince clock stage tid bound action

{- | 'boundWait' with the elapsed time measured from an earlier clock:
the bound applies to this action, the reported time to the whole call
that started the clock.
-}
boundWaitSince
    :: WaitClock -> WaitStage -> TxId -> Int -> IO a -> IO a
boundWaitSince clock stage tid bound action =
    boundWaitClosingSince clock stage tid bound (Right <$> action)

{- | 'boundWaitSince' for a wait that can also give up on its own: an
action that finds the confirmation window closed returns 'Left' the
POSIX deadline in milliseconds, and the wait ends at once with the same failure,
carrying that POSIX deadline. The failure a closed window raises is the one a
bound raises, so no caller can read it as a refusal.
-}
boundWaitClosingSince
    :: WaitClock
    -> WaitStage
    -> TxId
    -> Int
    -> IO (Either Integer a)
    -> IO a
boundWaitClosingSince (WaitClock start) stage tid bound action = do
    outcome <- timeout (bound * 1_000_000) action
    end <- getMonotonicTime
    let giveUp closedAt =
            throwIO
                WaitFailure
                    { waitStage = stage
                    , waitTxId = tid
                    , waitElapsed = end - start
                    , waitBound = bound
                    , waitClosedAt = closedAt
                    }
    case outcome of
        Nothing -> giveUp Nothing
        Just (Left deadline) -> giveUp (Just deadline)
        Just (Right a) -> pure a

-- | Preserve the existing five-minute infrastructure bound.
submissionBound :: Int
submissionBound = 300

-- | A timeout remains a named infrastructure exception, never a submit verdict.
boundedSignedSubmission
    :: Int -> (SignedTx -> IO a) -> SignedTx -> IO a
boundedSignedSubmission bound submit signed =
    boundWait
        SubmissionWait
        (txIdTx (signedTx signed))
        bound
        (submit signed)

{- | Run an action and classify what it throws: any synchronous exception
is returned as 'Left', except the wait failure, which is rethrown, and
asynchronous exceptions, which propagate. Every site that turns a
failure into a refusal, a control outcome or a reason to retry catches
through this, so a wait that gave up on a stalled node is never
published as a ledger refusal nor retried as one.
-}
tryOutcome :: IO a -> IO (Either SomeException a)
tryOutcome action = do
    outcome <- try action
    case outcome of
        Right a -> pure (Right a)
        Left e
            | Just (_ :: SomeAsyncException) <- fromException e ->
                throwIO e
            | Just (_ :: WaitFailure) <- fromException e -> throwIO e
            | otherwise -> pure (Left e)
