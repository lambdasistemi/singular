{- |
Module      : Singular.Registry.Node.Wait
Description : The bound every wait on a submitted transaction obeys
License     : Apache-2.0

The one owner of what a bounded wait is: the wait stages, the failure a
bound raises, the whole-wait bound ('boundWait') and the submitter
every construction site submits through ('boundedSubmitter').
Submission, indexed confirmation and session confirmation all bound
their waits here, and no other module adds a timeout of its own.

A wait that does not end is infrastructure failure, never a model
outcome: it is raised as the named 'WaitFailure' exception, which no
submit result, refusal receipt or acceptance ever reports.
-}
module Singular.Registry.Node.Wait
    ( -- * The wait failure
      WaitStage (..)
    , WaitFailure (..)

      -- * The whole-wait bound
    , WaitClock
    , startWaitClock
    , boundWait
    , boundWaitSince
    , boundWaitClosingSince

      -- * The bounded submitter
    , submissionBound
    , boundedSubmitter

      -- * The wait-aware catch
    , tryOutcome
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import GHC.Clock (getMonotonicTime)

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.TxIn (TxId)
import Cardano.Node.Client.Submitter
    ( Submitter (..)
    )
import Singular.Registry.WaitTypes (WaitFailure (..), WaitStage (..))

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
    outcome <- race (threadDelay (bound * 1_000_000)) action
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
        Left () -> giveUp Nothing
        Right (Left deadline) -> giveUp (Just deadline)
        Right (Right a) -> pure a

{- | The production bound on a submission, in seconds: the widest the
confirmation window allows, so no verdict a run could still use is cut
short. A node-to-client submission is a synchronous request the node
answers at once; one still undecided after this long is a stalled
node, and the run ends naming it.
-}
submissionBound :: Int
submissionBound = 300

{- | A submitter whose every submission is one bounded wait: a prompt
verdict passes through unchanged, and a submission the node has not
decided within the bound ends as the wait failure — never as a submit
result, so a stalled node cannot read as a refusal or an acceptance.
-}
boundedSubmitter :: Int -> Submitter IO -> Submitter IO
boundedSubmitter bound submit =
    Submitter
        { submitTx = \tx ->
            boundWait
                SubmissionWait
                (txIdTx tx)
                bound
                (submitTx submit tx)
        }

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
