{- |
Module      : Conformance.Run.Receipts
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Receipts
    ( writeCL01Receipt
    , writeCaCL01
    , writeStoryReceipt
    , addReceiptSteps
    , writeRowReceipt
    , recordHold
    , recordUnmet
    , debtReport
    , writeCL01Issue70
    ) where

import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Replay (sessionCorrespondence)
import Data.Maybe (fromMaybe)

import Data.Aeson
    ( Value (..)
    , eitherDecode
    )
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (modifyIORef', readIORef)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Conformance.Mirror
    ( emit
    , failWith
    , require
    )
import Conformance.Receipt
    ( DerivationEvidence (..)
    , Outcome (..)
    , Receipt (..)
    , RefusalInfo (..)
    , Verdict (..)
    , storyCorrespondence
    , unmetReading
    , unmetRuling
    , writeReceiptFile
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
                    AgreesWithModel
                    (map T.unpack (concatMap receiptTransactions rs))
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
    getMem r = fromMaybe 0 (receiptMem r)
    getCpu r = fromMaybe 0 (receiptCpu r)
    getSize r = fromMaybe 0 (receiptTxSize r)

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
                    AgreesWithModel
                    (map T.unpack (concatMap receiptTransactions rs))
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
    getMem r = fromMaybe 0 (receiptMem r)
    getCpu r = fromMaybe 0 (receiptCpu r)
    getSize r = fromMaybe 0 (receiptTxSize r)

-- | One envelope, with the generic body computed by Compare instructions.
writeStoryReceipt :: Env -> T.Text -> [Value] -> IO ()
writeStoryReceipt env row records = do
    txids <- concat <$> mapM acceptedTx records
    correspondence <- sessionCorrespondence (envReplay env)
    measures <- readIORef (envLiveMeasurements env)
    require "story receipt has no accepted transaction" (not (null txids))
    require
        "story receipt measurement count differs from accepted steps"
        (length txids == length measures)
    let (mem, cpu, size) =
            foldr
                (\(m, c, s) (ms, cs, largest) -> (m + ms, c + cs, max s largest))
                (0, 0, 0)
                measures
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
            , receiptReplayCorrespondence =
                storyCorrespondence correspondence records
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

writeRowReceipt
    :: Env
    -> String
    -> Outcome
    -> Verdict
    -> [String]
    -> Maybe RefusalInfo
    -> Maybe String
    -> Maybe Integer
    -> Maybe Integer
    -> Maybe Integer
    -> T.Text
    -> Maybe [DerivationEvidence]
    -> IO ()
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
            , receiptReplayCorrespondence = Nothing
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

{- | Record an unmet consumer requirement kept by operator ruling: the
chain's outcome is the registry's ruled behaviour and the consumer's
theorem requires otherwise. The row is visible here, in its receipt
(@unmet-by-ruling@), and in the run's exit — the session ends
non-zero while any requirement is unmet.
-}
recordUnmet :: Env -> String -> String -> String -> String -> IO ()
recordUnmet env row ruling registrySays consumerSays = do
    modifyIORef' (envUnmet env) (row :)
    emit
        "unmet"
        ( row
            <> " UNMET BY RULING: "
            <> ruling
            <> "; "
            <> registrySays
            <> "; the consumer's theorem says "
            <> consumerSays
            <> " — the run cannot exit 0 while this requirement is unmet"
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
                    AgreesWithModel
                    (map T.unpack (concatMap receiptTransactions rs))
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
    getMem r = fromMaybe 0 (receiptMem r)
    getCpu r = fromMaybe 0 (receiptCpu r)
    getSize r = fromMaybe 0 (receiptTxSize r)

{- | Add the batch records a row compared to the receipt it already wrote: the
model's batch question beside the chain's outcome, the refusal's traced replay
included, and the traced build those replays rely on when the receipt does not
yet name it.
-}
addReceiptSteps :: Env -> String -> [Value] -> IO ()
addReceiptSteps env row records = do
    let path = envReceiptsDir env </> ("receipt-" <> row <> ".json")
    written <- BSL.readFile path
    receipt <-
        either
            (\problem -> failWith (row <> ": unreadable receipt: " <> problem))
            pure
            (eitherDecode written)
    correspondence <- sessionCorrespondence (envReplay env)
    writeReceiptFile (envReceiptsDir env) $
        receipt
            { receiptSteps = Just records
            , receiptReplayCorrespondence =
                case receiptReplayCorrespondence receipt of
                    Just named -> Just named
                    Nothing -> storyCorrespondence correspondence records
            }

{- | The report a session ends with while any row it ran is held, unmet or
failing: every such row named under its verdict, so none can read as a pass.
-}
debtReport :: [String] -> [String] -> [String] -> String
debtReport held unmet failed =
    "ROWS THE RUN CANNOT REPORT AS PASSING"
        <> "\n- Held (Q-002, story 2: Singular's Lean and \
           \the consumer's theorem disagree and the \
           \chain sided with Singular's Lean; \
           \receipts carry verdict held-q002): "
        <> named held
        <> "\n- Unmet by ruling (a consumer \
           \requirement the registry deliberately \
           \does not meet, or a row with no model counterpart, kept \
           \unmet by operator ruling; receipts carry verdict \
           \unmet-by-ruling): "
        <> named unmet
        <> concatMap meaning unmet
        <> "\n- Failing against this candidate \
           \(verdict diverges-from-lean — the chain \
           \refused what the Lean requires \
           \accepted): "
        <> named failed
        <> "\nThese rows are the milestone owner's to \
           \carry to the user."
  where
    named rows = if null rows then "none" else unwords rows
    -- Which ruling keeps each unmet row unmet, in plain words.
    meaning row =
        "\n  - "
            <> row
            <> ": "
            <> maybe
                "unmet by a ruling no reader surface states"
                (T.unpack . unmetReading)
                (unmetRuling (T.pack row))
