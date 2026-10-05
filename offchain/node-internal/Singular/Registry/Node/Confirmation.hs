{- |
Module      : Singular.Registry.Node.Confirmation
Description : Waits, deadlines and chain observation for a runner
License     : Apache-2.0

The one place a runner waits for the chain: confirmations of submitted
transactions through the session's followed indexer, the deadlines
that bound those waits (a transaction's own validity window, or the
historical fixed window), and the settling wait after a submission
whose transaction the runner does not hold.

Every observation here reads the open session and the installed
follower through their owners — 'Singular.Registry.Node.Session' and
'Singular.Registry.Node.Indexer' — and names its error when called
outside them rather than guessing a chain.
-}
module Singular.Registry.Node.Confirmation
    ( -- * Confirmation
      awaitTx
    , awaitTxId
    , awaitTxWindow
    , confirmWithin
    , windowReadBound
    , confirmDeadline
    , txUpperBoundSlot
    , awaitChain
    , confirmationDelay
    ) where

import Control.Concurrent (threadDelay)
import Control.Exception (fromException, throwIO)
import Control.Monad (void)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , outputsTxBodyL
    , txIdTx
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (..))
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( awaitTxIn
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.NetworkTime (NetworkTimeFailure)
import Singular.Registry.Node.Indexer
    ( Following (..)
    , confirmationAttempts
    , confirmationPollSeconds
    , currentFollower
    )
import Singular.Registry.Node.Options (NodeMode (..), die, runMode)
import Singular.Registry.Node.PhaseLog (phaseLogFromEnv, queryPhase)
import Singular.Registry.Node.Session
    ( NodeSession (..)
    , sessionFor
    )
import Singular.Registry.Node.Wait
    ( WaitClock
    , WaitStage (..)
    , boundWaitClosingSince
    , boundWaitSince
    , startWaitClock
    , tryOutcome
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Services qualified as Services

{- | Wait until a submitted transaction is visible on the chain.

A fixed sleep is a devnet assumption: the factory devnet makes a block
about every second, a public test network about every twenty, so a
five-second wait calibrated on the devnet silently becomes a race on
preprod. This waits for the transaction's first output — the strongest
evidence the chain carries — and names the transaction when it never
appears.

The wait is bounded by the transaction's own validity upper bound plus
a two-minute margin, not by a fixed poll count: a transaction that is
still valid can still land, and a fixed five-minute window declared a
healthy preprod fold lost while eight minutes of its validity remained
(2026-09-14, registry request for spelling "alice"). A transaction
with no upper bound cannot expire, so the historical fixed window
stays its only bound.
-}
awaitTx :: ConwayTx -> IO ()
awaitTx tx = do
    clock <- startWaitClock
    sess <- sessionFor "awaitTx"
    case toList (tx ^. bodyTxL . outputsTxBodyL) of
        _ : _ -> pure ()
        [] ->
            die
                ( "cannot confirm transaction "
                    <> show (txIdTx tx)
                    <> ": it creates no output to observe"
                )
    confirmTxWindow clock sess tx (show (txIdTx tx)) (txIdTx tx)

{- | Confirm a just-submitted transaction by observing output zero.
Call before a dependent transaction spends that output. This supports
journey helpers that retain a transaction id but not the complete body.

Prefer 'awaitTxWindow' wherever the runner still holds the transaction:
there the wait is bounded by the transaction's own validity window
rather than by this fixed window.
-}
awaitTxId :: String -> IO ()
awaitTxId txid = do
    clock <- startWaitClock
    sess <- sessionFor "awaitTxId"
    wanted <- txIdFromHex "awaitTxId" txid
    deadline <-
        boundWaitSince
            clock
            SessionConfirmationWait
            wanted
            windowReadBound
            (fixedWindowDeadline (nsProvider sess))
    confirmSince clock fixedLimit sess txid wanted deadline

{- | Confirm a just-submitted transaction by observing output zero,
until the transaction's own validity upper bound plus a two-minute
margin. The runner holds the transaction it just built and signed, so
the wait can be exactly as long as the transaction can still land —
and the failure names the expired window instead of a fixed poll
count. A transaction with no upper bound cannot expire; the fixed
window of 'awaitTxId' stays its bound.
-}
awaitTxWindow :: ConwayTx -> String -> IO ()
awaitTxWindow tx txid = do
    clock <- startWaitClock
    sess <- sessionFor "awaitTxWindow"
    wanted <- txIdFromHex "awaitTxWindow" txid
    confirmTxWindow clock sess tx txid wanted

{- | Confirm a transaction under the window its validity gives it. The
node reads that derive the window run under 'windowReadBound', before
the wait starts, because the wait's limit is not known until they
return: a node that never answers them ends the wait as the same wait
failure. The wait itself then obeys the limit the window yields. The
clock is the public call's, so a failure reports the time of the whole
call.
-}
confirmTxWindow
    :: WaitClock -> NodeSession -> ConwayTx -> String -> TxId -> IO ()
confirmTxWindow clock sess tx label tid = do
    (deadline, limit) <-
        boundWaitSince
            clock
            SessionConfirmationWait
            tid
            windowReadBound
            (windowFor sess tx)
    confirmSince clock limit sess label tid deadline

-- | A transaction id from its hex rendering.
txIdFromHex :: String -> String -> IO TxId
txIdFromHex what txid = do
    raw <-
        either
            (const (die (what <> ": transaction id is not hex")))
            pure
            (B16.decode (BC.pack txid))
    h <-
        maybe
            (die (what <> ": transaction id is not 32 bytes"))
            pure
            (hashFromBytes raw)
    pure (TxId (unsafeMakeSafeHash h))

{- | Wait until the indexer following the session's chain reports the
block that carries output zero of a transaction, or the latest observed block time
reaches the POSIX deadline — the whole wait obeying the named wall-clock
limit (in seconds), tip reads included. The node is asked only for its
tip, and only while the output has not appeared. A tip that passes the
deadline ends the wait earlier, as the same wait failure carrying the
POSIX deadline in milliseconds; the limit is the backstop for a chain that never gets
there.
-}
confirmWithin
    :: Int -> NodeSession -> String -> TxId -> Integer -> IO ()
confirmWithin limit sess label tid deadline = do
    clock <- startWaitClock
    confirmSince clock limit sess label tid deadline

-- | 'confirmWithin' under the clock of the public call that waits.
confirmSince
    :: WaitClock
    -> Int
    -> NodeSession
    -> String
    -> TxId
    -> Integer
    -> IO ()
confirmSince clock limit sess label tid deadline =
    boundWaitClosingSince
        clock
        SessionConfirmationWait
        tid
        limit
        (confirmOutputZero sess label tid deadline)

{- | Wait until the indexer following the session's chain reports the
block that carries output zero of a transaction, or the latest observed block time
reaches the POSIX deadline, which it answers with the POSIX deadline in milliseconds. The node
is asked only for its tip, and only while the output has not appeared.
-}
confirmOutputZero
    :: NodeSession -> String -> TxId -> Integer -> IO (Either Integer ())
confirmOutputZero sess label tid deadline = do
    lg <- phaseLogFromEnv
    currentFollower
        >>= maybe
            (die (label <> ": no indexer follows this session's chain"))
            (indexed lg . followingIndexer)
  where
    indexed lg idx = do
        let TxId h = tid
        seen <-
            queryPhase lg "awaitTxIn" (maybe 0 (const 1)) $
                awaitTxIn
                    idx
                    (Indexer.TxIn (hashToBytes (extractHash h)) 0)
                    (Just confirmationPollSeconds)
        case seen of
            Just _ -> pure (Right ())
            Nothing -> do
                tip <- nsTipTime sess
                if tip >= deadline
                    then pure (Left deadline)
                    else indexed lg idx

{- | The observed-block POSIX deadline, retaining the transaction's entire
validity window. A ledger bound outside the validated finite context is
refused. Other synchronous read failures retain the historical fallback;
its block-time read still obeys the enclosing window-read bound.
-}
windowFor :: NodeSession -> ConwayTx -> IO (Integer, Int)
windowFor sess tx = do
    result <- tryOutcome (confirmWindow (nsProvider sess) tx)
    case result of
        Right window -> pure window
        Left failure
            | Just (_ :: NetworkTimeFailure) <- fromException failure ->
                throwIO failure
            | otherwise -> do
                void (nsTipTime sess)
                deadline <- (+ fromIntegral fixedWindow * 1000) <$> nowMs
                pure (deadline, fixedLimit)

{- | The bound on the node reads that derive a confirmation's window, in
seconds: a healthy node answers them at once.
-}
windowReadBound :: Int
windowReadBound = 30

-- | The historical fixed confirmation window, in seconds.
fixedWindow :: Int
fixedWindow = confirmationAttempts * confirmationPollSeconds

-- | The wall-clock limit of the fixed window: the window, then the backstop.
fixedLimit :: Int
fixedLimit = backstop fixedWindow

{- | A wall-clock limit that lets the chain's own deadline end a live
wait first: two polls after the window it backs, the tip has been read
past the deadline and its refusal has been raised. Only a chain that
never gets there reaches the limit.
-}
backstop :: Int -> Int
backstop window = window + 2 * confirmationPollSeconds

-- | Current POSIX milliseconds; never converted into a future ledger slot.
nowMs :: IO Integer
nowMs = round . (* 1000) . utcTimeToPOSIXSeconds <$> getCurrentTime

{- | A finite validity bound is converted through the pinned context before
adding an uncapped two-minute POSIX margin. An unbounded transaction retains
an uncapped five-minute local wait. Neither margin extends the ledger horizon.
-}
confirmWindow :: Cage.Provider IO -> ConwayTx -> IO (Integer, Int)
confirmWindow prov tx = case txUpperBoundSlot tx of
    Just upper -> do
        start <- Cage.withView prov (`Services.slotStart` upper)
        now <- nowMs
        let deadline = start + 120_000
            remaining = max 0 ((deadline - now + 999) `div` 1000)
        pure (deadline, backstop (fromInteger remaining))
    Nothing -> do
        deadline <- fixedWindowDeadline prov
        pure (deadline, fixedLimit)

-- | The POSIX wait deadline. It is never a transaction validity bound.
confirmDeadline :: Cage.Provider IO -> ConwayTx -> IO Integer
confirmDeadline prov tx = fst <$> confirmWindow prov tx

{- | Retain the initial bounded chain/context read, then wait five minutes
from the current POSIX time. No future time-to-slot conversion is performed.
-}
fixedWindowDeadline :: Cage.Provider IO -> IO Integer
fixedWindowDeadline prov = do
    void $ Cage.withView prov $ \view ->
        Services.slotStart view (Cage.cpSlot (Cage.viewPoint view))
    (+ fromIntegral fixedWindow * 1000) <$> nowMs

{- | The validity upper bound a transaction carries, if any. The fold,
update and retract builders pin one (request deadline, phase-2 end);
registration, request and boot transactions leave it open.
-}
txUpperBoundSlot :: ConwayTx -> Maybe SlotNo
txUpperBoundSlot tx =
    let vldt = tx ^. bodyTxL . vldtTxBodyL
    in  case invalidHereafter vldt of
            SJust bound -> Just bound
            SNothing -> Nothing

{- | Retry a chain observation until it yields, then return it; name
what never appeared when it does not.

Every "read back what the last transaction created" in a runner is one
of these. On the factory devnet the first read succeeds, because a
block lands about every second; on a public test network the same read
is a race against a twenty-second block, and a one-shot query turns a
healthy run into a spurious failure. The observation itself is the
confirmation — there is no separate notion of "confirmed" here beyond
the node reporting the output.
-}
awaitChain :: String -> IO (Maybe a) -> IO a
awaitChain what observe = go confirmationAttempts
  where
    go 0 =
        die
            ( what
                <> " (still not observable after "
                <> show (confirmationAttempts * confirmationPollSeconds)
                <> " seconds of polling the node)"
            )
    go n = do
        seen <- observe
        case seen of
            Just a -> pure a
            Nothing -> do
                threadDelay (confirmationPollSeconds * 1_000_000)
                go (n - 1)

{- | The settling wait a runner takes after a submission it does not
carry the transaction for.

Named residual: where a runner holds the submitted transaction,
'awaitTx' observes it and this constant is not used. Where it holds
only a label, there is nothing to observe and the wait is calibrated
per network instead — one second is a devnet block, twenty is a public
test network's. The assertions that follow such a wait go through
'awaitChain', so a wait that is still too short retries rather than
failing the run.
-}
confirmationDelay :: Int
confirmationDelay = case runMode of
    Devnet -> 5_000_000
    External _ -> 30_000_000
