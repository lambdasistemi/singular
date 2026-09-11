{- |
Module      : Conformance.Receipt
Description : Run receipts: the only way a row becomes executed
License     : Apache-2.0

A receipt is written by a @run@ that actually executed a row,
recording the row id, the outcome, the transaction ids the chain
accepted or the refusal attribution, the measured execution units
and size, the base commit, and the node and blueprint identities.
@list@ prints a row as executed iff a receipt for it exists and its
base matches the current tree; otherwise it prints the declared
plan. Receipts live under the run's own output directory — never in
the tracked tree — and @list@ takes the directory as @--receipts@
or @CONFORMANCE_RECEIPTS@, defaulting to none.
-}
module Conformance.Receipt (
    Outcome (..),
    RefusalInfo (..),
    Receipt (..),
    loadReceipts,
    currentBase,
) where

import Data.Aeson (
    FromJSON (..),
    eitherDecode,
    withObject,
    withText,
    (.:),
    (.:?),
 )
import Data.ByteString.Lazy qualified as BSL
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

-- | A row's observed outcome on the ledger.
data Outcome
    = Accepted
    | Refused
    deriving stock (Show, Eq)

instance FromJSON Outcome where
    parseJSON = withText "Outcome" $ \t -> case t of
        "accepted" -> pure Accepted
        "refused" -> pure Refused
        _ -> fail ("unknown receipt outcome: " <> T.unpack t)

-- | The refusal attribution for a refused row: the script that
-- refused and the node's phase-2 reason verbatim.
data RefusalInfo = RefusalInfo
    { refusalScript :: !Text
    , refusalReason :: !Text
    }
    deriving stock (Show, Eq)

instance FromJSON RefusalInfo where
    parseJSON = withObject "RefusalInfo" $ \o ->
        RefusalInfo
            <$> o .: "script"
            <*> o .: "reason"

-- | Evidence that a row executed. Accepted rows name the chain's
-- transaction ids and carry measurements; refused rows carry the
-- attribution and no transactions.
data Receipt = Receipt
    { receiptRow :: !Text
    , receiptOutcome :: !Outcome
    , receiptTransactions :: ![Text]
    , receiptRefusal :: !(Maybe RefusalInfo)
    , receiptMem :: !(Maybe Integer)
    , receiptCpu :: !(Maybe Integer)
    , receiptTxSize :: !(Maybe Integer)
    , receiptBase :: !Text
    , receiptNode :: !Text
    , receiptBlueprint :: !Text
    }
    deriving stock (Show, Eq)

instance FromJSON Receipt where
    parseJSON = withObject "Receipt" $ \o ->
        Receipt
            <$> o .: "row"
            <*> o .: "outcome"
            <*> o .: "transactions"
            <*> o .:? "refusal"
            <*> o .:? "mem"
            <*> o .:? "cpu"
            <*> o .:? "txSize"
            <*> o .: "base"
            <*> o .: "node"
            <*> o .: "blueprint"

{- | Load every @receipt-*.json@ in a directory. A malformed receipt,
an accepted row with no transactions or measurements, a refused row
with no attribution, or two receipts for one row is an error naming
the file: evidence that does not parse is not evidence.
-}
loadReceipts :: FilePath -> IO (Either String [Receipt])
loadReceipts dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then
            pure
                ( Left
                    ("receipt directory does not exist: " <> dir)
                )
        else do
            names <- listDirectory dir
            let files =
                    [ dir </> n
                    | n <- names
                    , "receipt-" `isPrefixOf` n
                    , ".json" `isSuffixOf` n
                    ]
            parsed <- mapM loadOne files
            pure (sequence parsed >>= checkReceipts)
  where
    loadOne path = do
        content <- BSL.readFile path
        pure $ case eitherDecode content of
            Left err ->
                Left (path <> " does not parse: " <> err)
            Right r -> checkOne path r
    checkOne path r = case receiptOutcome r of
        Accepted
            | null (receiptTransactions r) ->
                Left
                    ( path
                        <> ": accepted row "
                        <> T.unpack (receiptRow r)
                        <> " names no transaction"
                    )
            | any
                isNothing
                [ receiptMem r
                , receiptCpu r
                , receiptTxSize r
                ] ->
                Left
                    ( path
                        <> ": accepted row "
                        <> T.unpack (receiptRow r)
                        <> " misses measurements"
                    )
            | otherwise -> Right r
        Refused
            | null (receiptTransactions r)
            , Just _ <- receiptRefusal r ->
                Right r
            | otherwise ->
                Left
                    ( path
                        <> ": refused row "
                        <> T.unpack (receiptRow r)
                        <> " must carry a refusal and no transactions"
                    )
    checkReceipts rs
        | length rows /= length (nub rows) =
            Left "two receipts for one row"
        | otherwise = Right rs
      where
        rows = map receiptRow rs
        nub [] = []
        nub (x : xs) = x : nub (filter (/= x) xs)

{- | The current tree's base commit. 'Nothing' when git cannot say
(no checkout, no git): receipts then match nothing and @list@
prints the declared plan with a warning.
-}
currentBase :: IO (Maybe Text)
currentBase = do
    (code, out, _) <-
        readProcessWithExitCode "git" ["rev-parse", "HEAD"] ""
    case code of
        ExitSuccess ->
            pure (Just (T.strip (T.pack out)))
        _ -> do
            hPutStrLn
                stderr
                "conformance list: git base unknown; \
                \printing the declared plan"
            pure Nothing
