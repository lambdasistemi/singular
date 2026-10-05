{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Receipt
Description : The journal a write appends and the receipt a command prints
License     : Apache-2.0

A write submits several transactions, and a process can die between any
two of them. Each submission is journalled in four phases, each line
appended before the next step starts:

1. @prepared@: the signed body is saved beside the journal with its
   transaction id, inputs and the chain point — network, era, slot and
   block hash — of the one view its body was built from. This proves
   only that the transaction was built.
2. @submitted@, @rejected@ or @submit-unknown@: the node's answer to the
   send, or that none arrived (a timeout, a dropped connection, a
   process killed between the send and the answer).
3. @confirmed@ or @unconfirmed@: whether it was seen on chain before the
   deadline.
4. @observed@: a fresh readback of what it made.

Every line is stamped with the time of its append (@journalTime@, ISO-8601
UTC, to the millisecond); lines written before the stamp existed carry
none and read as before.

A later command may append two more, each naming the chain point it read
and the outputs it found live: @rolled-back@, when an included
transaction is no longer on the chain (its observation stays, superseded
by the appended line), and @excluded@, when an unresolved one can never
be included (off the chain, the tip past its validity upper bound).

A transaction whose last phase is not @observed@, @rejected@ or
@excluded@ is unresolved. The next command reconciles it from chain
evidence about that exact transaction ("Singular.CLI.Reconcile"); a
write stops on what remains, naming its 'SubmissionCase', and nothing is
resubmitted or rebooted implicitly.

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
    , bodiesDir
    , durableWrite

      -- * The case each submission met
    , SubmissionCase (..)
    , caseName
    , submissionCase

      -- * Outcomes
    , OutcomeClass (..)
    , outcomeName
    , exitCodeOf
    ) where

import Control.Exception (ErrorCall (..), bracket, throwIO)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , openFd
    )
import System.Posix.IO.ByteString (fdWrite)
import System.Posix.Unistd (fileSynchronise)

import Singular.Registry.PhaseLog (isoNow)

-- | One journal line: one phase of one submission.
data JournalEntry = JournalEntry
    { journalCommand :: Text
    , journalStep :: Text
    , journalTxId :: Text
    , journalEvent :: Text
    {- ^ @prepared@, @submitted@, @rejected@, @submit-unknown@,
    @confirmed@, @unconfirmed@, @observed@, @rolled-back@ or @excluded@
    -}
    , journalDetail :: Maybe Text
    , journalInputs :: Maybe [Text]
    {- ^ At @prepared@: the exact inputs the body spends. At
    @rolled-back@ and @excluded@: those of them found live
    -}
    , journalBody :: Maybe FilePath
    -- ^ At @prepared@: where the signed transaction's CBOR is saved
    , journalBodyHash :: Maybe Text
    -- ^ At @prepared@: BLAKE2b-256 of those saved bytes
    , journalNetwork :: Maybe Word32
    {- ^ At @prepared@: the network magic of the view the body was
    built from
    -}
    , journalEra :: Maybe Text
    -- ^ At @prepared@: the era of that view
    , journalChainPoint :: Maybe Text
    {- ^ At @prepared@: that view's chain point, @slot.headerhash@. At
    @rolled-back@ and @excluded@: the chain point the evidence was read at
    -}
    , journalSession :: Maybe Aeson.Value
    -- ^ Actual session identity, binding, consumed facts and raw source observations.
    , journalObservedTip :: Maybe Text
    -- ^ A latest observation; it does not bind the session to this point.
    , journalKey :: Maybe Text
    -- ^ At @prepared@: the registry key the step concerns, hex
    , journalExpect :: Maybe Text
    {- ^ At @prepared@: the after-state the step's readback must find —
    @reference:HASH@, @state@, @request@, @active:ENVELOPEHASH@,
    @payload:ENVELOPEHASH@ or @terminal@
    -}
    , journalEdge :: Maybe Integer
    -- ^ At @prepared@, for a fold: the edge it commits to the mirror
    , journalRootBefore :: Maybe Text
    {- ^ At @prepared@, for a fold: the root it folds from. At a fold's
    @rolled-back@: the root the mirror returned to
    -}
    , journalRootAfter :: Maybe Text
    -- ^ At @prepared@, for a fold: the root the mirror commits to after it
    , journalTime :: Maybe Text
    {- ^ When the line was appended, ISO-8601 UTC with millisecond precision.
    Stamped by 'appendJournal'; absent from lines written before it was
    -}
    }
    deriving stock (Eq, Show, Generic)

instance ToJSON JournalEntry where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON JournalEntry where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

journalPath :: FilePath -> FilePath
journalPath dir = dir </> "journal.jsonl"

{- | Append one line, stamped with the time of the append whatever time the
entry carried (a line copied from an earlier one must not keep that one's),
and make it durable — the file and its directory synchronised to disk —
before the caller takes the next step.
-}
appendJournal :: FilePath -> JournalEntry -> IO ()
appendJournal dir entry = do
    now <- isoNow
    durableAppend
        (journalPath dir)
        (BL.toStrict (Aeson.encode entry{journalTime = Just now} <> "\n"))

-- | Append bytes to a file, creating it, and synchronise file and directory.
durableAppend :: FilePath -> BS.ByteString -> IO ()
durableAppend path bytes = do
    bracket
        ( openFd
            path
            WriteOnly
            defaultFileFlags{append = True, creat = Just 0o644}
        )
        closeFd
        (\fd -> writeAll fd bytes >> fileSynchronise fd)
    syncDirectory (takeDirectory path)
  where
    writeAll fd b
        | BS.null b = pure ()
        | otherwise = do
            n <- fdWrite fd b
            writeAll fd (BS.drop (fromIntegral n) b)

-- | Write a new file whole, synchronised with its directory.
durableWrite :: FilePath -> BS.ByteString -> IO ()
durableWrite path bytes = do
    bracket
        ( openFd
            path
            WriteOnly
            defaultFileFlags{trunc = True, creat = Just 0o644}
        )
        closeFd
        (\fd -> writeAll fd bytes >> fileSynchronise fd)
    syncDirectory (takeDirectory path)
  where
    writeAll fd b
        | BS.null b = pure ()
        | otherwise = do
            n <- fdWrite fd b
            writeAll fd (BS.drop (fromIntegral n) b)

syncDirectory :: FilePath -> IO ()
syncDirectory dir =
    bracket (openFd dir ReadOnly defaultFileFlags) closeFd fileSynchronise

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

{- | The latest line of the first transaction whose last phase does not
settle it, if any.
-}
unresolved :: [JournalEntry] -> Maybe JournalEntry
unresolved entries =
    case [ lastOf t
         | t <- txIds
         , journalEvent (lastOf t) `notElem` settled
         ] of
        (e : _) -> Just e
        [] -> Nothing
  where
    settled = ["observed", "rejected", "excluded"]
    txIds = nub (map journalTxId entries)
    lastOf t = last [e | e <- entries, journalTxId e == t]

-- | The journal's directory of saved signed bodies.
bodiesDir :: FilePath -> FilePath
bodiesDir dir = dir </> "submissions"

{- | The case a submission met, named in the journal by its phases and
in the receipt of the command that met it: the node acknowledged it
(@submitted@), no answer arrived (@submit-unknown@, or nothing after
@prepared@), the node rejected it, it was seen included (@confirmed@,
or observed), the confirmation deadline passed (@unconfirmed@), its
inclusion is no longer on the chain (@rolled-back@), or it can never be
included (@excluded@).
-}
data SubmissionCase
    = CaseAcknowledged
    | CaseUnknown
    | CaseRejected
    | CaseIncluded
    | CaseTimeout
    | CaseRolledBack
    | CaseExcluded
    deriving stock (Eq, Show, Enum, Bounded)

-- | The case as a receipt names it.
caseName :: SubmissionCase -> Text
caseName = \case
    CaseAcknowledged -> "acknowledged"
    CaseUnknown -> "unknown"
    CaseRejected -> "rejected"
    CaseIncluded -> "included"
    CaseTimeout -> "timeout"
    CaseRolledBack -> "rolled-back"
    CaseExcluded -> "excluded"

{- | The case the transaction met, from its journalled phases: the
latest one that names a case. Inclusion recorded later — by a
reconciliation — supersedes an earlier unknown answer or timeout; a
rollback supersedes an inclusion, and a later inclusion the rollback;
an exclusion settles whatever came before it. A transaction the journal
does not name has no case.
-}
submissionCase :: [JournalEntry] -> Text -> Maybe SubmissionCase
submissionCase entries t = case [journalEvent e | e <- entries, journalTxId e == t] of
    [] -> Nothing
    events -> Just (foldl' after CaseUnknown events)
  where
    after current = \case
        "submitted" -> CaseAcknowledged
        "submit-unknown" -> CaseUnknown
        "rejected" -> CaseRejected
        "unconfirmed" -> CaseTimeout
        "confirmed" -> CaseIncluded
        "observed" -> CaseIncluded
        "rolled-back" -> CaseRolledBack
        "excluded" -> CaseExcluded
        _ -> current

-- | The attributable classes a command ends in.
data OutcomeClass
    = Success
    | ClientRefusal
    | LedgerRefusal
    | NodeUnavailable
    | Timeout
    | StaleState
    | Partial
    | ConcurrentWriter
    | ProofMissing
    | ProofInconsistent
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
    ConcurrentWriter -> "concurrent-writer"
    ProofMissing -> "proof-missing"
    ProofInconsistent -> "proof-inconsistent"

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
    ConcurrentWriter -> ExitFailure 16
    ProofMissing -> ExitFailure 17
    ProofInconsistent -> ExitFailure 18
