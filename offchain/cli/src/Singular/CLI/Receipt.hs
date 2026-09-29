{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Receipt
Description : The journal a write appends and the receipt a command prints
License     : Apache-2.0

A write submits several transactions, and a process can die between any
two of them. The journal is appended BEFORE each submission is awaited
and again when it is confirmed, so every transaction id that reached a
node survives the process, and a later write can see that an earlier one
never finished and refuse rather than silently repair or resubmit.

A receipt is what one command prints: its public identity, what it
submitted, what it read back from the ledger and how, and its outcome.
Ledger observations, the locally proven leaf and the model's
expectation are separate fields; a field nothing observed is absent,
never filled from an expectation. No secret is ever written.
-}
module Singular.CLI.Receipt
    ( -- * Journal
      JournalEntry (..)
    , journalPath
    , appendJournal
    , readJournal
    , unresolved

      -- * Outcomes
    , OutcomeClass (..)
    , outcomeName
    , exitCodeOf
    ) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

-- | One journal line: a submission or its confirmation.
data JournalEntry = JournalEntry
    { journalCommand :: Text
    , journalStep :: Text
    , journalTxId :: Text
    , journalEvent :: Text
    -- ^ @submitted@, @confirmed@ or @failed@
    , journalDetail :: Maybe Text
    }
    deriving stock (Eq, Show, Generic)

instance ToJSON JournalEntry where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON JournalEntry where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

journalPath :: FilePath -> FilePath
journalPath dir = dir </> "journal.jsonl"

-- | Append one line, flushed before the caller goes on to wait.
appendJournal :: FilePath -> JournalEntry -> IO ()
appendJournal dir entry =
    BL.appendFile (journalPath dir) (Aeson.encode entry <> "\n")

-- | Every line, in the order it was appended; a missing journal is empty.
readJournal :: FilePath -> IO [JournalEntry]
readJournal dir = do
    let path = journalPath dir
    there <- doesFileExist path
    if not there
        then pure []
        else do
            raw <- BS.readFile path
            traverse decodeLine (filter (not . BS.null) (BC.lines raw))
  where
    decodeLine l =
        either
            (\err -> throwIO (ErrorCall ("journal line does not decode: " <> err)))
            pure
            (Aeson.eitherDecodeStrict' l)

-- | The first submission the journal never saw confirmed, if any.
unresolved :: [JournalEntry] -> Maybe JournalEntry
unresolved entries =
    case [ e
         | e <- entries
         , journalEvent e == "submitted"
         , journalTxId e `notElem` confirmedIds
         ] of
        (e : _) -> Just e
        [] -> Nothing
  where
    confirmedIds =
        [journalTxId e | e <- entries, journalEvent e == "confirmed"]

-- | The attributable classes a command ends in.
data OutcomeClass
    = Success
    | ClientRefusal
    | LedgerRefusal
    | NodeUnavailable
    | Timeout
    | StaleState
    | Partial
    deriving stock (Eq, Show, Enum, Bounded)

-- | The class as a receipt names it.
outcomeName :: OutcomeClass -> Text
outcomeName = \case
    Success -> "success"
    ClientRefusal -> "client-refusal"
    LedgerRefusal -> "ledger-refusal"
    NodeUnavailable -> "node-unavailable"
    Timeout -> "timeout"
    StaleState -> "stale-state"
    Partial -> "partial"

-- | The exit status of each class; 2 stays the command line's own.
exitCodeOf :: OutcomeClass -> ExitCode
exitCodeOf = \case
    Success -> ExitSuccess
    ClientRefusal -> ExitFailure 10
    LedgerRefusal -> ExitFailure 11
    NodeUnavailable -> ExitFailure 12
    Timeout -> ExitFailure 13
    StaleState -> ExitFailure 14
    Partial -> ExitFailure 15
