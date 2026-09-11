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

Two venues need no node. CS01 checks Haskell encodings against the
compiled blueprint's declared schemas read at run time
(@blueprint-check@); CS06 checks parameter application in Haskell
(@param-check@). Both record @mem@/@cpu@ zero — no script executed
— and @txSize@ the measured serialized bytes, with no transactions.
Every other accepted row is a @node-submit@ observation with
transactions and units from the running node.
-}
module Conformance.Receipt (
    Outcome (..),
    RefusalInfo (..),
    Receipt (..),
    maxReceiptBytes,
    checkReceiptSize,
    loadReceipts,
    writeReceiptFile,
    currentBase,
) where

import Control.Exception (ErrorCall (..), throwIO)

import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    eitherDecode,
    encode,
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.=),
 )
import Data.ByteString.Lazy qualified as BSL
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (isJust, isNothing)
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

instance ToJSON Outcome where
    toJSON Accepted = toJSON ("accepted" :: Text)
    toJSON Refused = toJSON ("refused" :: Text)

{- | The refusal attribution for a refused row: the script that
refused and the node's phase-2 reason verbatim.
-}
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

instance ToJSON RefusalInfo where
    toJSON r =
        object
            [ "script" .= refusalScript r
            , "reason" .= refusalReason r
            ]

{- | Evidence that a row executed. Accepted rows name the chain's
transaction ids and carry measurements; refused rows carry the
attribution and the submitted transaction's id under @rejected@
(empty @transactions@: nothing was accepted). @receiptVenue@
records where the refusal was observed: @node-submit@ (a node
ruling on a submitted transaction) or @ledger-eval@ (local ledger
evaluation only — never described as ledger execution).
@receiptDirty@ records whether the running tree had uncommitted
changes: a receipt from a dirty tree is honest working evidence,
but only a clean-tree receipt names a commit that reproduces it.
-}
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
    , receiptVenue :: !Text
    , receiptRejected :: !(Maybe Text)
    , receiptDirty :: !Bool
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
            <*> o .: "venue"
            <*> o .:? "rejected"
            <*> o .: "dirty"

instance ToJSON Receipt where
    toJSON r =
        object
            [ "row" .= receiptRow r
            , "outcome" .= receiptOutcome r
            , "transactions" .= receiptTransactions r
            , "refusal" .= receiptRefusal r
            , "rejected" .= receiptRejected r
            , "mem" .= receiptMem r
            , "cpu" .= receiptCpu r
            , "txSize" .= receiptTxSize r
            , "base" .= receiptBase r
            , "dirty" .= receiptDirty r
            , "node" .= receiptNode r
            , "blueprint" .= receiptBlueprint r
            , "venue" .= receiptVenue r
            ]

{- | Write one @receipt-<ROW>.json@ under the run's output directory.
Receipts over 'maxReceiptBytes' fail the run: a receipt nobody
can open is weak evidence, and a size convention would quietly
break on a later row.
-}
writeReceiptFile :: FilePath -> Receipt -> IO ()
writeReceiptFile dir r = case checkReceiptSize r of
    Left err -> throwIO (ErrorCall err)
    Right () ->
        BSL.writeFile
            (dir </> ("receipt-" <> T.unpack (receiptRow r) <> ".json"))
            (encode r)

{- | Receipts stay readable: the CG05 refusal once embedded the whole
compiled validator (~30KB of base64) because @show@ on the
evaluation context prints every script and cost model.
-}
maxReceiptBytes :: Int
maxReceiptBytes = 16384

{- | The size bound, purely: oversized receipts are an error naming
the row and the byte count.
-}
checkReceiptSize :: Receipt -> Either String ()
checkReceiptSize r
    | BSL.length (encode r) <= fromIntegral maxReceiptBytes = Right ()
    | otherwise =
        Left
            ( "receipt for row "
                <> T.unpack (receiptRow r)
                <> " is "
                <> show (BSL.length (encode r))
                <> " bytes, over the "
                <> show maxReceiptBytes
                <> " limit"
            )

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
        Accepted -> checkAccepted path r
        Refused
            | null (receiptTransactions r)
            , Just _ <- receiptRefusal r
            , receiptVenue r == "node-submit"
            , Just _ <- receiptRejected r ->
                Right r
            | null (receiptTransactions r)
            , Just _ <- receiptRefusal r
            , receiptVenue r == "ledger-eval"
            , Nothing <- receiptRejected r ->
                Right r
            | otherwise ->
                Left
                    ( path
                        <> ": refused row "
                        <> T.unpack (receiptRow r)
                        <> " must carry a refusal, no transactions, and "
                        <> "a rejected id exactly for node-submit"
                    )
    checkAccepted p x
        | receiptVenue x == "node-submit" = checkNodeAccepted p x
        | receiptVenue x == "blueprint-check", receiptRow x == "CS01" =
            checkLocalAccepted p x
        | receiptVenue x == "param-check", receiptRow x == "CS06" =
            checkLocalAccepted p x
        | otherwise =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " has venue "
                    <> T.unpack (receiptVenue x)
                    <> ", want node-submit or its own local venue"
                )
    checkNodeAccepted p x
        | null (receiptTransactions x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " names no transaction"
                )
        | any isNothing [receiptMem x, receiptCpu x, receiptTxSize x] =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " misses measurements"
                )
        | isJust (receiptRejected x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " must not name a rejected transaction"
                )
        | otherwise = Right x
    checkLocalAccepted p x
        | not (null (receiptTransactions x)) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " is local and must name no transaction"
                )
        | receiptMem x /= Just 0 || receiptCpu x /= Just 0 =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " is local and must record zero units"
                )
        | Nothing <- receiptTxSize x =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " misses measurements"
                )
        | isJust (receiptRejected x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " must not name a rejected transaction"
                )
        | isJust (receiptRefusal x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " must not carry a refusal"
                )
        | otherwise = Right x
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
