{- |
Module      : Conformance.Run.Receipts
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Receipts (writeCL01Receipt, writeCaCL01, writeStoryReceipt, writeRowReceipt, recordHold, writeCL01Issue70) where

import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Observe

import Data.Aeson (
    Value (..),
    eitherDecode,
 )
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (modifyIORef', readIORef)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Conformance.Mirror (
    emit,
    failWith,
    require,
 )
import Conformance.Receipt (
    DerivationEvidence (..),
    Outcome (..),
    Receipt (..),
    RefusalInfo (..),
    Verdict (..),
    writeReceiptFile,
 )

{- | CL01 for these rows: worst-case units and size across the
slice's accepting folds, with the fold transactions named. The
per-row values live in the row receipts; this receipt records that
every accepting row above reported against the devnet maxima. Full
CL01 closes when every accepting row in the inventory reports.
-}
writeCL01Receipt :: Env -> [String] -> IO ()
writeCL01Receipt env rows = do
    receipts <- mapM readRowReceipt ["CG02", "CG03", "CG04"]
    case (rows, sequence receipts) of
        (requested, Just rs)
            | all (`elem` requested) ["CG02", "CG03", "CG04"] ->
                writeRowReceipt
                    env
                    "CL01"
                    Accepted
                    AgreesWithModel                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
                    Nothing
        _ ->
            emit
                "measure"
                "CL01 not receipted: run did not cover CG02 CG03 CG04"
  where
    readRowReceipt row = do
        let path =
                envReceiptsDir env
                    </> ("receipt-" <> row <> ".json")
        exists <- doesFileExist path
        if not exists
            then pure Nothing
            else do
                content <- BSL.readFile path
                case eitherDecode content of
                    Right r -> pure (Just (r :: Receipt))
                    Left _ -> pure Nothing
    getMem r = case receiptMem r of Just m -> m; Nothing -> 0
    getCpu r = case receiptCpu r of Just c -> c; Nothing -> 0
    getSize r = case receiptTxSize r of Just s -> s; Nothing -> 0


{- | CL01 for the CA rows: worst-case units and size across the
session's two accepting boots (CA01 canonical, CA02 rival). CA03 and
CA04 name one of those two transactions and reuse its measurements;
CA05 executes no script and reports zeros honestly. Written only
when the full CA set ran, and bound to the run's own receipts.
-}
writeCaCL01 :: Env -> [String] -> IO ()
writeCaCL01 env rows
    | all (`elem` rows) caRows = do
        receipts <- mapM readRowReceipt ["CA01", "CA02"]
        case sequence receipts of
            Just rs ->
                writeRowReceipt
                    env
                    "CL01"
                    Accepted
                    AgreesWithModel                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
                    Nothing
            Nothing ->
                emit
                    "measure"
                    "CL01 not receipted: the CA01/CA02 receipts are missing"
    | otherwise =
        emit
            "measure"
            "CL01 not receipted: run did not cover CA01 CA02 CA03 CA04 CA05"
  where
    readRowReceipt row = do
        let path =
                envReceiptsDir env
                    </> ("receipt-" <> row <> ".json")
        exists <- doesFileExist path
        if not exists
            then pure Nothing
            else do
                content <- BSL.readFile path
                case eitherDecode content of
                    Right r -> pure (Just (r :: Receipt))
                    Left _ -> pure Nothing
    getMem r = case receiptMem r of Just m -> m; Nothing -> 0
    getCpu r = case receiptCpu r of Just c -> c; Nothing -> 0
    getSize r = case receiptTxSize r of Just s -> s; Nothing -> 0


-- | One envelope, with the generic body computed by Compare instructions.
writeStoryReceipt :: Env -> T.Text -> [Value] -> IO ()
writeStoryReceipt env row records = do
    txids <- fmap concat $ mapM acceptedTx records
    measures <- readIORef (envLiveMeasurements env)
    require "story receipt has no accepted transaction" (not (null txids))
    require "story receipt measurement count differs from accepted steps"
        (length txids == length measures)
    let (mem, cpu, size) = foldr
            (\(m, c, s) (ms, cs, largest) -> (m + ms, c + cs, max s largest))
            (0, 0, 0) measures
    writeReceiptFile (envReceiptsDir env) $
        Receipt
            { receiptRow = row
            , receiptOutcome = Accepted
            , receiptVerdict = AgreesWithModel
            , receiptTransactions = txids
            , receiptRefusal = Nothing
            , receiptRejected = Nothing
            , receiptMem = Just mem
            , receiptCpu = Just cpu
            , receiptTxSize = Just size
            , receiptBase = T.pack (envBase env)
            , receiptDirty = envDirty env
            , receiptPartial = Nothing
            , receiptDerivation = Nothing
            , receiptSteps = Just records
            , receiptNode = T.pack (envNode env)
            , receiptBlueprint = T.pack (envBlueprint env)
            , receiptVenue = "node-submit"
            }
  where
    acceptedTx record = do
        chain <- storyField "chain" record
        outcome <- storyField "outcome" chain
        if outcome == String "accepted"
            then do
                txid <- storyField "txid" chain
                case txid of
                    String t -> pure [t]
                    _ -> failWith "accepted step names no transaction id"
            else pure []


-- ---------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------

writeRowReceipt ::
    Env ->
    String ->
    Outcome ->
    Verdict ->
    [String] ->
    Maybe RefusalInfo ->
    Maybe String ->
    Maybe Integer ->
    Maybe Integer ->
    Maybe Integer ->
    T.Text ->
    Maybe [DerivationEvidence] ->
    IO ()
writeRowReceipt env row outcome verdict txs refusal rejected mem cpu size venue derivation =
    writeReceiptFile (envReceiptsDir env) $
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = outcome
            , receiptVerdict = verdict
            , receiptTransactions = map T.pack txs
            , receiptRefusal = refusal
            , receiptRejected = fmap T.pack rejected
            , receiptMem = mem
            , receiptCpu = cpu
            , receiptTxSize = size
            , receiptBase = T.pack (envBase env)
            , receiptDirty = envDirty env
            , receiptPartial = Nothing

            , receiptDerivation = derivation
            , receiptSteps = Nothing
            , receiptNode = T.pack (envNode env)
            , receiptBlueprint = T.pack (envBlueprint env)
            , receiptVenue = venue
            }


{- | Record a held row (Q-002, story 2): the chain's outcome agrees
with Singular's Lean and contradicts the consumer's theorem. The
row is visible here, in its receipt (@held-q002@), and in the
run's exit — the session ends non-zero while anything is held.
-}
recordHold :: Env -> String -> String -> String -> String -> IO ()
recordHold env row holdId leanSays consumerSays = do
    modifyIORef' (envHeld env) (row :)
    emit
        "held"
        ( row
            <> " HELD FOR "
            <> holdId
            <> ": "
            <> leanSays
            <> "; the consumer's theorem says "
            <> consumerSays
            <> "; which model is the behavioral authority is the \
               \user's ruling, not ours — the run cannot exit 0 \
               \while this row is held"
        )


writeCL01Issue70 :: Env -> [String] -> IO ()
writeCL01Issue70 env rows
    | all (`elem` rows) issue70Rows = do
        receipts <- mapM readRowReceiptFile issue70AcceptingRows
        case sequence receipts of
            Just rs ->
                writeRowReceipt
                    env
                    "CL01"
                    Accepted
                    AgreesWithModel                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
                    Nothing
            Nothing ->
                emit
                    "measure"
                    "CL01 not receipted: an accepting row's receipt is \
                     \missing"
    | otherwise =
        emit
            "measure"
            "CL01 not receipted: run did not cover the issue #70 rows"
  where
    readRowReceiptFile row = do
        let path = envReceiptsDir env </> ("receipt-" <> row <> ".json")
        exists <- doesFileExist path
        if not exists
            then pure Nothing
            else do
                content <- BSL.readFile path
                case eitherDecode content of
                    Right r -> pure (Just (r :: Receipt))
                    Left _ -> pure Nothing
    getMem r = case receiptMem r of Just m -> m; Nothing -> 0
    getCpu r = case receiptCpu r of Just c -> c; Nothing -> 0
    getSize r = case receiptTxSize r of Just s -> s; Nothing -> 0
