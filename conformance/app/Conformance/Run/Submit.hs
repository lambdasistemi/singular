{- |
Module      : Conformance.Run.Submit
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Submit (attributeSubmitRefusal, submitExpectRefusedControl, attributeControlRefusal, submitTxResilient, submitExpectAccepted, submitExpectRefused, submitWithGenesis, awaitTx, millis) where

import Conformance.Run.Environment

import Control.Concurrent (threadDelay)
import Control.Exception (
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)

import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Node (
    NodeMode (..),
    awaitIndexed,
    runMode,
 )
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )

import Conformance.Mirror (
    emit,
    failWith,
    txIdHex,
 )
import Conformance.Receipt (Verdict (..))
import Conformance.Refusal (
    RefusalRole (..),
    attributeRefusalReceipt,
 )

attributeSubmitRefusal :: Env -> String -> Verdict -> String -> String -> String -> IO ()
attributeSubmitRefusal env row verdict marker text rejectedTxid = do
    -- NOTE-003 discipline: the node may report several failing
    -- scripts in an order that is not stable, so the matcher asserts
    -- the expected script is AMONG them (the reason text is matched
    -- raw, never a single first hash). The write policy lives in the
    -- library (A-002): a refusal ROW's receipt IS the row outcome.
    let script = if row `elem` ["CG07"] then "request" else "state"
    r <-
        attributeRefusalReceipt
            RefusalRow
            (envReceiptsDir env)
            row
            verdict
            script
            marker
            text
            rejectedTxid
            (envBase env)
            (envDirty env)
            (envNode env)
            (envBlueprint env)
    case r of
        Right () ->
            emit
                "row"
                ( row
                    <> ": REFUSED at submit, attributed to "
                    <> script
                    <> " (phase-2, marker 0x"
                    <> shortMarker marker
                    <> ")"
                )
        Left mismatch ->
            failWith
                ( row
                    <> ": refusal did not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )


{- | A refused CONTROL: submitted and attributed like a refusal row,
but its outcome is run-log evidence under its own identity and never
writes the row's receipt (A-002 — CG11/CG12/CG19's held receipts were
being replaced by their controls' refusals). It cannot silently pass:
an accepted control fails the run as a FINDING, and a refusal that
does not attribute fails the run naming the mismatch.
-}
submitExpectRefusedControl :: Env -> String -> Verdict -> String -> ConwayTx -> IO ()
submitExpectRefusedControl env row verdict marker tx = do
    let signed = addKeyWitness genesisSignKey tx
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            attributeControlRefusal
                env
                row
                verdict
                marker
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signed)
        Submitted txid ->
            failWith
                ( row
                    <> " FINDING: the node ACCEPTED the control transaction "
                    <> "expected to refuse (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )


attributeControlRefusal :: Env -> String -> Verdict -> String -> String -> String -> IO ()
attributeControlRefusal env row verdict marker text rejectedTxid = do
    let script = if row `elem` ["CG07"] then "request" else "state"
    r <-
        attributeRefusalReceipt
            RefusalControl
            (envReceiptsDir env)
            row
            verdict
            script
            marker
            text
            rejectedTxid
            (envBase env)
            (envDirty env)
            (envNode env)
            (envBlueprint env)
    case r of
        Right () ->
            emit
                "control"
                ( row
                    <> " control: REFUSED at submit, attributed to "
                    <> script
                    <> " (phase-2, marker 0x"
                    <> shortMarker marker
                    <> ") — run-log evidence only; the row's receipt is "
                        <> "not overwritten (A-002)"
                )
        Left mismatch ->
            failWith
                ( row
                    <> ": control refusal did not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )


-- | Evaluate a transaction's script purposes on the node.
-- ---------------------------------------------------------
-- Issue #70 rows
-- ---------------------------------------------------------

{- | Submit and require acceptance (key-witnessed by the given
signer); a refusal is a loud failure naming the reason.
-}
-- | Submit with transient-failure resilience: the N2C local-tx
-- supervisor reopens the bearer after a lost connection mid-submit;
-- the client contract says callers treat 'ConnectionLost' as
-- transient and retry. Re-evaluation is deterministic, so the retry
-- yields the same verdict (a phase-2 failure is not a chain effect:
-- a locally rejected transaction never entered the ledger, and no
-- collateral moves).
submitTxResilient :: Submitter IO -> ConwayTx -> IO SubmitResult
submitTxResilient submit tx = do
    start <- getMonotonicTime
    result <- go (4 :: Int)
    end <- getMonotonicTime
    let answer = case result of
            Submitted _ -> "accepted"
            Rejected _ -> "refused"
    emit "submit" (txIdHex tx <> " " <> answer <> " after " <> millis (end - start))
    pure result
  where
    go 0 = submitTx submit tx
    go n = do
        r <- try @SomeException (submitTx submit tx)
        case r of
            Right res -> pure res
            Left e
                | "ConnectionLost" `isInfixOf` displayException e -> do
                    emit "submit" "connection lost mid-submit; retrying"
                    threadDelay 3_000_000
                    go (n - 1)
                | otherwise -> throwIO e


-- | Submit and require acceptance (key-witnessed by the given
-- signer); a refusal is a loud failure naming the reason.
--}
submitExpectAccepted :: Env -> ConwayTx -> IO ConwayTx
submitExpectAccepted env tx = do
    result <- submitTxResilient (envSubmit env) tx
    case result of
        Submitted _ -> awaitTx tx >> pure tx
        Rejected reason ->
            failWith
                ( "expected acceptance, the node refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )


{- | Submit a hand-built refusing transaction and close the row on
the node's phase-2 attribution. A submission success is a FINDING:
reported, never relabelled.
-}
-- The refusal transaction is signed with the genesis key (the
-- collateral pot and fee inputs are genesis's); rows needing a
-- second witness pre-sign before calling.
submitExpectRefused :: Env -> String -> Verdict -> String -> ConwayTx -> IO ()
submitExpectRefused env row verdict marker tx = do
    let signed = addKeyWitness genesisSignKey tx
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            attributeSubmitRefusal
                env
                row
                verdict
                marker
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signed)
        Submitted txid ->
            failWith
                ( row
                    <> " FINDING: the node ACCEPTED the transaction the "
                    <> "consumer's requirement refuses (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )


submitWithGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithGenesis submit unsignedTx = do
    let signedTx = addKeyWitness genesisSignKey unsignedTx
    result <- submitTxResilient submit signedTx
    case result of
        Submitted _ -> awaitTx signedTx >> pure signedTx
        Rejected reason ->
            failWith
                ( "transaction rejected: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )


{- | Wait until a submitted transaction is on chain, and log how long
that took. On the factory devnet the chain-sync indexer reports the
block that carries it; against an external node the historical fixed
five-second wait is unchanged.
-}
awaitTx :: ConwayTx -> IO ()
awaitTx tx = case runMode of
    Devnet -> do
        start <- getMonotonicTime
        awaitIndexed tx
        end <- getMonotonicTime
        emit "confirm" (txIdHex tx <> " indexed after " <> millis (end - start))
    External _ -> threadDelay 5_000_000


-- | A monotonic-clock duration in whole milliseconds, for the run log.
millis :: Double -> String
millis seconds = show (round (seconds * 1000) :: Integer) <> " ms"
