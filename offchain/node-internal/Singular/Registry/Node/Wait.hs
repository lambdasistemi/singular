{-# LANGUAGE LambdaCase #-}

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
    ( Exception
    , SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import GHC.Clock (getMonotonicTime)

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.Submitter
    ( Submitter (..)
    )

{- | The wait a bound ended, named by the wait itself and never by its
caller: exactly one stage per failure.
-}
data WaitStage
    = -- | Waiting for the node's verdict on a submitted transaction.
      SubmissionWait
    | {- | Waiting for the followed indexer to show a submitted
      transaction's first output.
      -}
      IndexedConfirmationWait
    | {- | Waiting for a session confirmation: the output, or the
      chain's tip passing the confirmation window.
      -}
      SessionConfirmationWait
    deriving stock (Eq, Show)

{- | A wait on a submitted transaction that did not end within its
bound. It is an exception, never a submit result: a stalled node is
infrastructure failure, and the run that sees it has no verdict, no
refusal and no acceptance to report.
-}
data WaitFailure = WaitFailure
    { waitStage :: WaitStage
    -- ^ The wait that gave up
    , waitTxId :: TxId
    -- ^ The transaction the wait was on
    , waitElapsed :: Double
    {- ^ Seconds measured on the monotonic clock from the start of the
    whole wait
    -}
    , waitBound :: Int
    -- ^ The bound the wait was under, in seconds
    , waitClosedAt :: Maybe Integer
    {- ^ The POSIX deadline in milliseconds reached by the latest observed block, when a session
    confirmation ended because its window closed before the bound
    -}
    }

instance Show WaitFailure where
    show
        WaitFailure
            { waitStage
            , waitTxId
            , waitElapsed
            , waitBound
            , waitClosedAt
            } =
            "the "
                <> stageLabel waitStage
                <> " wait for transaction "
                <> txIdHex waitTxId
                <> " gave up after "
                <> seconds waitElapsed
                <> " s against its "
                <> show waitBound
                <> " s bound: "
                <> stageDetail waitStage waitClosedAt

instance Exception WaitFailure

-- | The stage's own name, as its failure renders it.
stageLabel :: WaitStage -> String
stageLabel = \case
    SubmissionWait -> "submission"
    IndexedConfirmationWait -> "indexed confirmation"
    SessionConfirmationWait -> "session confirmation"

-- | What the stage's wait was still waiting for when it gave up.
stageDetail :: WaitStage -> Maybe Integer -> String
stageDetail stage closedAt = case (stage, closedAt) of
    (SubmissionWait, _) ->
        "the node returned no verdict for the transaction"
    (IndexedConfirmationWait, _) ->
        "the node accepted the transaction but its first output never \
        \reached the followed indexer"
    (SessionConfirmationWait, Nothing) ->
        "the chain neither showed the transaction's first output nor \
        \closed its confirmation window in time"
    (SessionConfirmationWait, Just deadline) ->
        "the transaction was accepted by the node but has not appeared \
        \in a block: its confirmation window closed at POSIX milliseconds "
            <> show deadline

-- | A transaction id's hex rendering.
txIdHex :: TxId -> String
txIdHex (TxId h) =
    BC.unpack (B16.encode (hashToBytes (extractHash h)))

-- | A duration in seconds, to a tenth.
seconds :: Double -> String
seconds s = show (fromIntegral (round (s * 10) :: Integer) / 10 :: Double)

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
