{- |
Module      : Conformance.Run.Receipts
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Receipts
    ( writeExecutionUnitsAndTransactionSizeReceipt
    , writeIdentityExecutionUnitsAndTransactionSize
    , writeStoryReceipt
    , addReceiptSteps
    , writeRowReceipt
    , recordHold
    , recordUnmet
    , debtReport
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
import Data.Aeson.KeyMap qualified as KM
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

{- | execution-units-and-transaction-size for the registry rows: the worst units and size across the accepting
folds of update-existing-key, delete-existing-key and reinsert-deleted-key, each read off the step that folded it in its row's
receipt, with the fold transactions named. This receipt records that every
accepting fold of those rows reported against the devnet maxima. Full execution-units-and-transaction-size
closes when every accepting row in the inventory reports.
-}
writeExecutionUnitsAndTransactionSizeReceipt
    :: Env -> [String] -> IO ()
writeExecutionUnitsAndTransactionSizeReceipt env rows = do
    receipts <-
        mapM
            readRowReceipt
            ["update-existing-key", "delete-existing-key", "reinsert-deleted-key"]
    case (rows, sequence receipts) of
        (requested, Just rs)
            | all
                (`elem` requested)
                ["update-existing-key", "delete-existing-key", "reinsert-deleted-key"] -> do
                let transactions = concatMap receiptTransactions rs
                    measured =
                        [ units
                        | r <- rs
                        , step <- fromMaybe [] (receiptSteps r)
                        , Just units <- [stepMeasured step]
                        ]
                require
                    "execution-units-and-transaction-size: an accepting fold of update-existing-key, delete-existing-key or reinsert-deleted-key carries no units"
                    (not (null measured) && length measured == length transactions)
                writeRowReceipt
                    env
                    "execution-units-and-transaction-size"
                    Accepted
                    AgreesWithModel
                    (map T.unpack transactions)
                    Nothing
                    Nothing
                    (Just (maximum [m | (m, _, _) <- measured]))
                    (Just (maximum [c | (_, c, _) <- measured]))
                    (Just (maximum [s | (_, _, s) <- measured]))
                    "node-submit"
                    Nothing
        _ ->
            emit
                "measure"
                "execution-units-and-transaction-size not receipted: run did not cover update-existing-key delete-existing-key reinsert-deleted-key"
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
    stepMeasured step = case step of
        Object fields
            | Just (Object chain) <- KM.lookup "chain" fields
            , KM.lookup "outcome" chain == Just (String "accepted")
            , Just (Object units) <- KM.lookup "measured" chain
            , Just (Number m) <- KM.lookup "mem" units
            , Just (Number c) <- KM.lookup "cpu" units
            , Just (Number s) <- KM.lookup "size" units ->
                Just (round m, round c, round s)
        _ -> Nothing :: Maybe (Integer, Integer, Integer)

{- | execution-units-and-transaction-size for the registry-identity rows: worst-case units and size across the
session's two accepting boots (canonical-seed-identity canonical, rival-seed-authentication rival). policy-address-only-authentication-control and
applied-validator-identity name one of those two transactions and reuse its measurements;
tokenless-output-authentication executes no script and reports zeros honestly. Written only
when the full registry-identity set ran, and bound to the run's own receipts.
-}
writeIdentityExecutionUnitsAndTransactionSize
    :: Env -> [String] -> IO ()
writeIdentityExecutionUnitsAndTransactionSize env rows
    | all (`elem` rows) authenticationRows = do
        receipts <-
            mapM
                readRowReceipt
                ["canonical-seed-identity", "rival-seed-authentication"]
        case sequence receipts of
            Just rs ->
                writeRowReceipt
                    env
                    "execution-units-and-transaction-size"
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
                    "execution-units-and-transaction-size not receipted: the canonical-seed-identity/rival-seed-authentication receipts are missing"
    | otherwise =
        emit
            "measure"
            "execution-units-and-transaction-size not receipted: run did not cover canonical-seed-identity rival-seed-authentication policy-address-only-authentication-control applied-validator-identity tokenless-output-authentication"
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
writeStoryReceipt :: Env -> T.Text -> Verdict -> [Value] -> IO ()
writeStoryReceipt env row verdict records = do
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
            , receiptVerdict = verdict
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
