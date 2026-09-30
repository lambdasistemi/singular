{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Session
Description : The node and wallet a write command runs with, and its journalled submissions
License     : Apache-2.0

A write command connects to the node its caller named — never one of its
own — loads the caller's signing key, and hands every transaction it
builds to 'journalledSubmit', which signs it and walks the first three
journal phases of "Singular.CLI.Receipt": prepared, the node's answer,
the confirmation. Each phase is synchronised to disk before the next
step starts, so a process killed anywhere leaves the journal saying how
far that transaction got.

The fourth phase, @observed@, is the command's own: 'journalObserved'
records it only after the command has read back what the transaction
made. A confirmation proves inclusion, not that readback, so a
transaction confirmed but never read back stays unresolved.

A failure is a 'CommandFailure' naming its outcome class; the command
prints it and exits with that class's status.
-}
module Singular.CLI.Session
    ( -- * Failures
      CommandFailure (..)
    , failWith

      -- * Writes
    , WriteContext (..)
    , withWrite
    , withSession
    , journalledSubmit
    , Expectation (..)
    , expecting
    , journalObserved
    , journalObservedId
    , txIdHex
    , refuseUnresolved
    ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception
    ( Exception
    , IOException
    , SomeException
    , bracket
    , throwIO
    , try
    )
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (SeekMode (..))
import System.Posix.IO
    ( LockRequest (..)
    , OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , openFd
    , setLock
    )
import System.Timeout (timeout)

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ConwayEra)

import Singular.CLI.Command (NodeSettings (..), WriteSettings (..))
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , bodiesDir
    , durableWrite
    , readJournal
    , unresolved
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeSession (..)
    , Wallet (..)
    , awaitTxWindow
    , loadWallet
    , withNodeMode
    )

-- | Why a command stopped, in its outcome class.
data CommandFailure = CommandFailure OutcomeClass String
    deriving stock (Show)

instance Exception CommandFailure

failWith :: OutcomeClass -> String -> IO a
failWith c why = throwIO (CommandFailure c why)

-- | Everything a write's submissions need.
data WriteContext = WriteContext
    { wcDir :: FilePath
    , wcCommand :: Text
    , wcWallet :: Wallet
    , wcSession :: NodeSession
    , wcTimeout :: Maybe Int
    }

{- | Take the target directory's write lock, connect to the named node with
the caller's wallet, and run the body holding the lock throughout. A
second writer on the same directory is refused @concurrent-writer@
before it reads the journal or contacts the node; the lock is the
operating system's, released when the process ends however it ends,
so a crash leaves no stale lock. A node that cannot be used before the
body starts is @node-unavailable@; once connected, failures are the
body's own.
-}
withWrite
    :: FilePath
    -> Text
    -> WriteSettings
    -> (WriteContext -> IO a)
    -> IO a
withWrite dir command ws body = do
    harnessHold
    withTargetLock dir (withSession dir command ws body)

{- | __Test harness only__ (#299 journey). When
@SINGULAR_HARNESS_HOLD_BEFORE_LOCK@ names a path, write @PATH.waiting@ and
wait until @PATH@ exists before taking the target's lock, so a journey
can make another process act between a command's pre-lock checks and
its lock. Unset in ordinary use, where it does nothing.
-}
harnessHold :: IO ()
harnessHold =
    lookupEnv "SINGULAR_HARNESS_HOLD_BEFORE_LOCK" >>= \case
        Nothing -> pure ()
        Just path -> do
            writeFile (path <> ".waiting") ""
            let waitFor = do
                    there <- doesFileExist path
                    if there then pure () else threadDelay 100_000 >> waitFor
            waitFor

{- | The node and wallet without the target's lock: for a command that
writes nothing to its target (a create preview), so the target directory
is neither created nor touched.
-}
withSession
    :: FilePath
    -> Text
    -> WriteSettings
    -> (WriteContext -> IO a)
    -> IO a
withSession dir command ws body = do
    let NodeSettings sock magic = writeNode ws
    wallet <- loadWallet magic (writeWalletKey ws)
    connected <- newIORef False
    result <-
        try $
            withNodeMode (External (ExternalNode sock magic (writeWalletKey ws))) $ \sess -> do
                writeIORef connected True
                body
                    WriteContext
                        { wcDir = dir
                        , wcCommand = command
                        , wcWallet = wallet
                        , wcSession = sess
                        , wcTimeout = writeConfirmTimeout ws
                        }
    case result of
        Right a -> pure a
        Left (e :: SomeException) -> do
            was <- readIORef connected
            if was
                then throwIO e
                else
                    failWith
                        NodeUnavailable
                        ("the node at " <> sock <> " could not be used: " <> show e)

{- | Hold an exclusive advisory lock on @dir/.lock@ for the action, or
refuse at once when another process holds it.
-}
withTargetLock :: FilePath -> IO a -> IO a
withTargetLock dir action = do
    createDirectoryIfMissing True dir
    bracket
        ( openFd
            (dir </> ".lock")
            WriteOnly
            defaultFileFlags{creat = Just 0o644}
        )
        closeFd
        ( \fd -> do
            taken <- try (setLock fd (WriteLock, AbsoluteSeek, 0, 0))
            case taken of
                Left (_ :: IOException) ->
                    failWith
                        ConcurrentWriter
                        ( "another singular process is writing to "
                            <> dir
                            <> "; nothing was read or submitted"
                        )
                Right () -> action
        )

{- | __Test harness only__ (#299 journey). When
@SINGULAR_HARNESS_HOLD_AFTER_SUBMIT@ names a path and
@SINGULAR_HARNESS_HOLD_STEP@ names this step, write @PATH.waiting@ right
after the node's acceptance is journalled and wait until @PATH@ exists,
so a journey can interrupt exactly at the accepted-send boundary. Unset
in ordinary use, where it does nothing.
-}
harnessHoldAfterSubmit :: Text -> IO ()
harnessHoldAfterSubmit step = do
    path <- lookupEnv "SINGULAR_HARNESS_HOLD_AFTER_SUBMIT"
    wanted <- lookupEnv "SINGULAR_HARNESS_HOLD_STEP"
    case (path, wanted) of
        (Just p, Just w) | T.pack w == step -> do
            writeFile (p <> ".waiting") ""
            let waitFor = do
                    there <- doesFileExist p
                    if there then pure () else threadDelay 100_000 >> waitFor
            waitFor
        _ -> pure ()

{- | How long a write waits for a confirmation when the caller names no
@--confirm-timeout@: ten minutes. Past it the submission is journalled
@unconfirmed@, unresolved, and never resubmitted.
-}
defaultConfirmSeconds :: Int
defaultConfirmSeconds = 600

-- | A write refuses while any journalled submission is unresolved.
refuseUnresolved :: FilePath -> IO ()
refuseUnresolved dir = do
    entries <- readJournal dir
    case unresolved entries of
        Nothing -> pure ()
        Just e ->
            failWith
                Partial
                ( "the journal holds an unresolved submission "
                    <> T.unpack (journalTxId e)
                    <> " ("
                    <> T.unpack (journalStep e)
                    <> ", last phase "
                    <> T.unpack (journalEvent e)
                    <> "); inspect resolves it only from chain evidence, \
                       \and nothing is resubmitted"
                )

-- | A transaction's id, as hex.
txIdHex :: ConwayTx -> Text
txIdHex tx =
    let TxId h = txIdTx tx
    in  hexT (hashToBytes (extractHash h))

blankEntry :: WriteContext -> Text -> Text -> Text -> JournalEntry
blankEntry wc step txid event =
    JournalEntry
        { journalCommand = wcCommand wc
        , journalStep = step
        , journalTxId = txid
        , journalEvent = event
        , journalDetail = Nothing
        , journalInputs = Nothing
        , journalTipSlot = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalChainPoint = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        }

{- | What a submission's readback must find, journalled at @prepared@ so a
later inspect can check exactly that step's after-state and nothing
more general.
-}
data Expectation = Expectation
    { exKey :: Maybe ByteString
    , exAfter :: Text
    , exEdge :: Maybe Integer
    , exRootBefore :: Maybe ByteString
    , exRootAfter :: Maybe ByteString
    }

-- | An expectation with no key or roots.
expecting :: Text -> Expectation
expecting after = Expectation Nothing after Nothing Nothing Nothing

{- | Sign; save the signed transaction and journal @prepared@ with its
inputs, body hash and the node's chain point; send; journal the answer;
await the confirmation; journal it. Returns the signed transaction once
confirmed. The command journals @observed@ after its own readback.
-}
journalledSubmit
    :: WriteContext -> Text -> Expectation -> ConwayTx -> IO ConwayTx
journalledSubmit wc step ex unsigned = do
    let signed = addKeyWitness (walletSignKey (wcWallet wc)) unsigned
        txid = txIdHex signed
        dir = wcDir wc
        sess = wcSession wc
        journal event detail =
            appendJournal
                dir
                (blankEntry wc step txid event){journalDetail = detail}
        bytes = serialize' (eraProtVerHigh @ConwayEra) signed
        bodyPath = bodiesDir dir </> T.unpack txid <> ".cbor.hex"
    createDirectoryIfMissing True (bodiesDir dir)
    durableWrite bodyPath (B16.encode bytes)
    SlotNo tip <- nsTipSlot sess
    point <- nsChainPoint sess
    appendJournal
        dir
        (blankEntry wc step txid "prepared")
            { journalInputs =
                Just (map renderOutRef (toList (signed ^. bodyTxL . inputsTxBodyL)))
            , journalTipSlot = Just (fromIntegral tip)
            , journalBody = Just bodyPath
            , journalBodyHash =
                Just (hexT (hashToBytes (hashWith @Blake2b_256 id bytes)))
            , journalChainPoint =
                Just $ case point of
                    Nothing -> "genesis"
                    Just (slot, h) -> T.pack (show slot) <> "." <> hexT h
            , journalKey = hexT <$> exKey ex
            , journalExpect = Just (exAfter ex)
            , journalEdge = exEdge ex
            , journalRootBefore = hexT <$> exRootBefore ex
            , journalRootAfter = hexT <$> exRootAfter ex
            }
    answer <- try (submitTx (nsSubmitter sess) signed)
    case answer of
        Left (e :: SomeException) -> do
            journal "submit-unknown" (Just (T.pack (show e)))
            failWith
                Partial
                ( "no answer from the node for "
                    <> T.unpack txid
                    <> "; it may or may not have been accepted: "
                    <> show e
                )
        Right (Rejected reason) -> do
            journal "rejected" (Just (T.pack (show reason)))
            failWith
                LedgerRefusal
                (T.unpack step <> " refused by the node: " <> show reason)
        Right (Submitted _) -> do
            journal "submitted" Nothing
            harnessHoldAfterSubmit step
    -- The wait runs on its own thread and this thread only waits for its
    -- result, bounded by the caller's --confirm-timeout or, when none is
    -- given, by the default bound. The bound therefore holds whatever
    -- the wait does inside — including when the node is gone and the
    -- wait never returns. A wait abandoned at the bound is cancelled
    -- without this thread waiting for that cancellation to finish.
    let limit = fromMaybe defaultConfirmSeconds (wcTimeout wc) * 1_000_000
    waiter <- async (awaitTxWindow signed (T.unpack txid))
    outcome <- timeout limit (waitCatch waiter)
    when (isNothing outcome) $ void (forkIO (cancel waiter))
    let seen = case outcome of
            Nothing -> Right Nothing
            Just (Left e) -> Left e
            Just (Right ()) -> Right (Just ())
    case seen of
        Left (e :: SomeException) -> do
            -- The node accepted the transaction; only the wait for its
            -- confirmation failed. It stays unresolved, named, and is
            -- never resubmitted.
            journal
                "unconfirmed"
                (Just ("the confirmation wait failed: " <> T.pack (show e)))
            failWith
                Partial
                ( T.unpack txid
                    <> " was accepted by the node, but waiting for its \
                       \confirmation failed ("
                    <> show e
                    <> "); it is journalled unresolved and never resubmitted"
                )
        Right Nothing -> do
            journal "unconfirmed" (Just "the confirmation deadline passed")
            failWith
                Timeout
                ( T.unpack txid
                    <> " was accepted but not seen on chain in time; it is \
                       \journalled and never resubmitted"
                )
        Right (Just ()) -> do
            journal "confirmed" Nothing
            pure signed

{- | Journal the fourth phase: the command read back what a confirmed
transaction made, and says what it read.
-}
journalObserved :: WriteContext -> Text -> ConwayTx -> Text -> IO ()
journalObserved wc step tx = journalObservedId wc step (txIdHex tx)

-- | The same, for a transaction known by its id.
journalObservedId :: WriteContext -> Text -> Text -> Text -> IO ()
journalObservedId wc step txid detail =
    appendJournal
        (wcDir wc)
        (blankEntry wc step txid "observed"){journalDetail = Just detail}

hexT :: ByteString -> Text
hexT = T.pack . BC.unpack . B16.encode
