{-# LANGUAGE LambdaCase #-}

-- | Validated run receipts are the only source of execution credit.
module Conformance.Receipt
    ( Outcome (..)
    , Verdict (..)
    , RefusalInfo (..)
    , Receipt (..)
    , maxReceiptBytes
    , checkReceiptSize
    , loadReceipts
    , writeReceiptFile
    , currentBase
    ) where

import Conformance.Replay
    ( ReplayCorrespondence (..)
    , ReplayEvidence (..)
    , causeName
    )
import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (forM_, unless, when)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (..)
    , eitherDecode
    , encode
    , object
    , withObject
    , withText
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.List (isPrefixOf, isSuffixOf, nub, sort)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

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

{- | The refusal attribution for a refused row: the scripts that
refused — one role, or several @+@-joined roles in ledger-reported
order when a malformed transaction trips two validators at once —
and the node's phase-2 reason verbatim.
-}
data RefusalInfo = RefusalInfo
    { refusalScript :: !Text
    , refusalReason :: !Text
    , refusalPhase :: !Text
    -- ^ observed phase (phase-2 for script-execution failures)
    , refusalHashes :: ![Text]
    -- ^ extracted failure script hashes (structured attribution)
    , refusalBranch :: !(Maybe Text)
    {- ^ named validator branch, when the compiled trace exposes
    one; Nothing states explicitly that none is available (never
    infer a branch name from the intended property)
    -}
    , refusalLimit :: !(Maybe Text)
    -- ^ explicit attribution limit when no branch is available
    , refusalReplay :: !(Maybe [ReplayEvidence])
    {- ^ the traced replay of each failing purpose of the refused transaction
    (absent on receipts written before it)
    -}
    }
    deriving stock (Show, Eq)

instance FromJSON RefusalInfo where
    parseJSON = withObject "RefusalInfo" $ \o ->
        RefusalInfo
            <$> o .: "script"
            <*> o .: "reason"
            <*> o .: "phase"
            <*> o .: "hashes"
            <*> o .:? "branch"
            <*> o .:? "limit"
            <*> o .:? "replay"

instance ToJSON RefusalInfo where
    toJSON r =
        object
            [ "script" .= refusalScript r
            , "reason" .= refusalReason r
            , "phase" .= refusalPhase r
            , "hashes" .= refusalHashes r
            , "branch" .= refusalBranch r
            , "limit" .= refusalLimit r
            , "replay" .= refusalReplay r
            ]

data Verdict
    = AgreesWithModel
    | HeldQ002
    | DivergesFromLean
    | ResolvedByRuling
    | UnmetByRuling
    | Partial
    deriving stock (Show, Eq, Enum, Bounded)

instance FromJSON Verdict where
    parseJSON = withText "Verdict" $ \t -> case t of
        "agrees-with-model" -> pure AgreesWithModel
        "held-q002" -> pure HeldQ002
        "diverges-from-lean" -> pure DivergesFromLean
        "resolved-by-ruling" -> pure ResolvedByRuling
        "unmet-by-ruling" -> pure UnmetByRuling
        "partial" -> pure Partial
        _ -> fail ("unknown receipt verdict: " <> T.unpack t)

instance ToJSON Verdict where
    toJSON AgreesWithModel = toJSON ("agrees-with-model" :: Text)
    toJSON HeldQ002 = toJSON ("held-q002" :: Text)
    toJSON DivergesFromLean = toJSON ("diverges-from-lean" :: Text)
    toJSON ResolvedByRuling = toJSON ("resolved-by-ruling" :: Text)
    toJSON UnmetByRuling = toJSON ("unmet-by-ruling" :: Text)
    toJSON Partial = toJSON ("partial" :: Text)

data Receipt = Receipt
    { receiptRow :: !Text
    , receiptOutcome :: !Outcome
    , receiptVerdict :: !Verdict
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
    , receiptReplayCorrespondence :: !(Maybe ReplayCorrespondence)
    {- ^ the traced build every replay reason in the receipt relies on (absent
    on receipts written before it)
    -}
    }
    deriving stock (Show, Eq)

instance FromJSON Receipt where
    parseJSON = withObject "Receipt" $ \o -> do
        -- The removed runners' evidence forms cannot be silently ignored.
        forM_ ["steps", "partial", "derivation"] $ \name ->
            unless
                (maybe True (== Null) (KM.lookup name o))
                (fail ("unsupported receipt field: " <> show name))
        Receipt
            <$> o .: "row"
            <*> o .: "outcome"
            <*> o .: "verdict"
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
            <*> o .:? "replayCorrespondence"

instance ToJSON Receipt where
    toJSON r =
        object
            [ "row" .= receiptRow r
            , "outcome" .= receiptOutcome r
            , "verdict" .= receiptVerdict r
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
            , "replayCorrespondence" .= receiptReplayCorrespondence r
            ]

-- | The public receipt bound remains unchanged.
maxReceiptBytes :: Int
maxReceiptBytes = 18432

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

-- | The caller owns the receipt directory and its lifetime.
writeReceiptFile :: FilePath -> Receipt -> IO ()
writeReceiptFile dir r = case checkReceiptSize r of
    Left problem -> throwIO (ErrorCall problem)
    Right () ->
        BSL.writeFile
            (dir </> ("receipt-" <> T.unpack (receiptRow r) <> ".json"))
            (encode r)

-- | Read and validate every receipt; missing directories and duplicate rows fail closed.
loadReceipts :: FilePath -> IO (Either String [Receipt])
loadReceipts dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then pure (Left ("receipt directory does not exist: " <> dir))
        else do
            names <- listDirectory dir
            parsed <-
                mapM
                    loadOne
                    [ dir </> n
                    | n <- sort names
                    , "receipt-" `isPrefixOf` n
                    , ".json" `isSuffixOf` n
                    ]
            pure $ do
                receipts <- sequence parsed
                unless
                    (length (nub (map receiptRow receipts)) == length receipts)
                    (Left "two receipts for one row")
                pure receipts
  where
    loadOne path = do
        content <- BSL.readFile path
        pure $ do
            r <-
                either
                    (Left . ((path <> " does not parse: ") <>))
                    Right
                    (eitherDecode content)
            either (Left . ((path <> ": ") <>)) Right (validateReceipt r)
            pure r

validateReceipt :: Receipt -> Either String ()
validateReceipt r = do
    checkReceiptSize r
    when
        (receiptVerdict r == Partial)
        (Left "partial receipt has no supported constructor accounting")
    when
        ( any
            T.null
            [receiptRow r, receiptBase r, receiptNode r, receiptBlueprint r]
        )
        (Left "receipt has an empty identity")
    when
        (receiptDirty r)
        (Left "receipt was recorded on a dirty tree")
    case receiptOutcome r of
        Accepted -> do
            unless
                (receiptVenue r == "node-submit")
                (Left "accepted receipt must use node-submit")
            when
                (null (receiptTransactions r) || any T.null (receiptTransactions r))
                (Left "accepted receipt names no transaction")
            unless
                (all (maybe False (>= 0)) [receiptMem r, receiptCpu r, receiptTxSize r])
                (Left "accepted receipt misses measurements")
            unless
                (isNothing (receiptRefusal r) && isNothing (receiptRejected r))
                (Left "accepted receipt carries a refusal or rejected transaction")
        Refused -> do
            unless
                (null (receiptTransactions r))
                (Left "refused receipt names accepted transactions")
            unless
                ( ( receiptVenue r == "node-submit"
                        && maybe False (not . T.null) (receiptRejected r)
                  )
                    || (receiptVenue r == "ledger-eval" && isNothing (receiptRejected r))
                )
                (Left "refused receipt needs a rejected id exactly for node-submit")
            case receiptRefusal r of
                Nothing -> Left "refused receipt has no attribution"
                Just info -> do
                    unless
                        (refusalPhase info == "phase-2")
                        (Left "refusal phase is not phase-2")
                    when
                        (null (refusalHashes info) || any T.null (refusalHashes info))
                        (Left "refusal names no extracted failure hashes")
                    when
                        (any T.null [refusalScript info, refusalReason info])
                        (Left "refusal has an empty script or reason")
                    unless
                        ( any isJust [refusalBranch info, refusalLimit info]
                            && all
                                (maybe True (not . T.null))
                                [refusalBranch info, refusalLimit info]
                        )
                        (Left "refusal states neither a branch nor its limit")
                    replayProblem (refusalBranch info) (refusalReplay info)
                    let reasons =
                            [ reason
                            | entry <- fromMaybe [] (refusalReplay info)
                            , Just reason <- [replayReason entry]
                            ]
                    case (reasons, receiptReplayCorrespondence r) of
                        ([], _) -> Right ()
                        (_, Just c)
                            | not . any T.null $
                                [ correspondenceSource c
                                , correspondenceCompiler c
                                , correspondenceFlags c
                                , correspondenceDigest c
                                ] ->
                                Right ()
                        _ -> Left "replay reasons without the traced build they rely on"

replayProblem
    :: Maybe Text -> Maybe [ReplayEvidence] -> Either String ()
replayProblem claim = \case
    Nothing -> case claim of
        Just reason ->
            Left
                ( "claims the traced reason "
                    <> show reason
                    <> " without the replay that admitted it"
                )
        Nothing -> Right ()
    Just [] -> Left "replay names no failing purpose"
    Just entries -> do
        mapM_ entryProblem entries
        case claim of
            Just reason
                | reason `notElem` [r | e <- entries, Just r <- [replayReason e]] ->
                    Left
                        ("claims " <> show reason <> ", a reason the replay did not admit")
            _ -> Right ()
  where
    entryProblem e
        | T.null (replayDeployedHash e) =
            Left "replay names a purpose without its deployed hash"
        | otherwise = case (replayReason e, replayCause e) of
            (Just _, Just _) -> Left "replay names both a reason and a cause"
            (Nothing, Nothing) -> Left "replay names neither a reason nor a cause"
            (Just reason, Nothing)
                | T.null reason -> Left "replay names an empty reason"
                | maybe True T.null (replayTracedHash e) ->
                    Left "replay names a reason without its traced hash"
                | maybe True T.null (replayCaptureId e) ->
                    Left "replay names a reason without the capture it was replayed from"
                | otherwise -> Right ()
            (Nothing, Just cause)
                | cause `elem` map causeName [minBound .. maxBound] -> Right ()
                | otherwise -> Left ("replay names an unknown cause " <> show cause)

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
