{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Session
Description : The node and wallet a write command runs with, and its journalled submissions
License     : Apache-2.0

A write command holds the capabilities "Singular.Registry.Terminal" opens for the
node its caller named — never one of its own — and the caller's signing
key. Every transaction it builds goes through 'submitBuilt': built from
one view, then signed and walked through the first three journal phases
of "Singular.CLI.Receipt": prepared, the node's answer, the
confirmation. The signed-only write is the one way to the node. Each phase is synchronised to disk before the next
step starts, so a process killed anywhere leaves the journal saying how
far that transaction got.

The fourth phase, @observed@, is the command's own: 'journalObserved'
records it only after the command has read back what the transaction
made. A confirmation proves inclusion, not that readback, so a
transaction confirmed but never read back stays unresolved until a later
command reconciles it. The receipt names each transaction the command
prepared and the case it met.

A failure is a 'CommandFailure' naming its outcome class; the command
prints it and exits with that class's status.
-}
module Singular.CLI.Session
    ( -- * Failures
      CommandFailure (..)
    , Reported (..)
    , reportedOf
    , failWith
    , failWithFields
    , admitSubmissions

      -- * The environment
    , Env (..)
    , koiosEnv

      -- * Writes
    , WriteContext (..)
    , StagedRun (..)
    , StagedEnd (..)
    , openWriteSigner
    , reportSeen
    , ConfirmedSubmission
    , confirmedTx
    , confirmedTxId
    , confirmedScopes
    , confirmedElapsed
    , withWrite
    , withSession
    , signerWallet
    , refuseTakenBundle
    , stageRegistry
    , signingWallet
    , readsIn
    , readOnce
    , submitBuilt
    , submitBuiltIn
    , bundleOfRun
    , loadSignerWallet
    , unopenedVault
    , Building (..)
    , readStep
    , timedRead
    , inScopes
    , Expectation (..)
    , expecting
    , foldExpectationScalars
    , expectationJournalFields
    , journalObserved
    , journalObservedId
    , txIdHex

      -- * The target's lock
    , withTargetLockOr

      -- * Test harness points
    , harnessHoldAt
    ) where

import Control.Exception
    ( ErrorCall (..)
    , Exception (..)
    , IOException
    , SomeAsyncException
    , SomeException (..)
    , bracket
    , evaluate
    , fromException
    , throwIO
    , toException
    , try
    , tryJust
    )
import Control.Monad (forM_, unless, when, (>=>))
import Control.Tracer (Tracer (..), traceWith)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing, doesPathExist)
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
import System.Posix.IO.ByteString (fdWrite)
import System.Posix.Unistd (fileSynchronise)
import System.Timeout (timeout)

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , feeTxBodyL
    , inputsTxBodyL
    , referenceInputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (Coin (..), ConwayEra)

import Singular.CLI.Command
    ( ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.Failure
    ( CommandFailure (..)
    , Env (..)
    , Reported (..)
    , failWith
    , failWithFields
    , markedLike
    , reportedOf
    )
import Singular.CLI.FlagGroup
    ( OpenedVault (..)
    , Signer (..)
    , signerAddress
    )
import Singular.CLI.Harness
    ( harnessHoldAt
    , harnessSubmission
    , holdAfterSubmit
    , holdBeforeLock
    )
import Singular.CLI.Passphrase
    ( Confirmation (AskOnce)
    , readPassphrase
    , renderPassphraseRefusal
    , sourceFor
    )
import Singular.CLI.Receipt
    ( BundleState (..)
    , FoldTransition (..)
    , JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , bodiesDir
    , caseName
    , durableWrite
    , journalWaitingForSignatures
    , outcomeName
    , readJournal
    , submissionCase
    )
import Singular.CLI.Reconcile (reconcileBundles, renderPoint)
import Singular.CLI.Sign
    ( SignRefusal (..)
    , bundleWitnesses
    , renderSignRefusal
    )
import Singular.CLI.Submit (submitInMemory)
import Singular.CLI.Trace
    ( ConfirmVerdict (..)
    , Ended (..)
    , Fetch (..)
    , How (..)
    , RefusalKind (..)
    , Scope (..)
    , SubmitVerdict (..)
    , TipAt (..)
    , Trace (..)
    , TxEvent (..)
    , What (..)
    , backendUnder
    , ended
    , how
    , readsUnder
    , report
    , txUnder
    , what
    , within
    )
import Singular.CLI.Vault (openVault)
import Singular.Provider.Koios.Runtime (koiosSource)
import Singular.Registry.Bundle
    ( Bundle (..)
    , BundleTransaction (..)
    , bodyDeadline
    , bodyIdentity
    , encodeBundle
    , transactionEnvelope
    )
import Singular.Registry.Capabilities (sessionReceipt)
import Singular.Registry.ChainedView
    ( StagedTransaction (..)
    , chainedSession
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Terminal
    ( Capabilities (..)
    , tracedReads
    , withReaderReads
    , withReads
    , withWrites
    )
import Singular.Registry.Trace
    ( Evaluation (..)
    , errorClassOf
    , startTimer
    , timedTrace
    )
import Singular.Registry.Wait qualified as Wait
import Singular.Registry.WaitTypes (WaitFailure)
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    , walletFromSignKey
    )

-- | The environment over Koios, its mechanics and reads traced into this tracer.
koiosEnv :: Tracer IO Trace -> Env
koiosEnv tracer =
    Env
        { envTracer = tracer
        , envSource = koiosSource
        , envReads = withReads (backendUnder tracer) (readsUnder tracer)
        , envReaderReads = withReaderReads (backendUnder tracer)
        , envWrites = withWrites (backendUnder tracer) (readsUnder tracer)
        }

{- | Everything a write's submissions need: immutable explicit inputs.
Successful per-submission metadata (placement scopes, confirmation age)
travels in the returned 'ConfirmedSubmission' value, never in a
command-wide mutable index.
-}
data WriteContext = WriteContext
    { wcDir :: FilePath
    , wcCommand :: Text
    , wcWallet :: Maybe Wallet
    {- ^ The loaded key-file wallet, present only when the signer is a key
    file: the signing path's own input. A staged run holds no key at all.
    -}
    , wcCaller :: Addr
    -- ^ The address every command reads its caller through, whichever signer
    , wcCapabilities :: Capabilities Cage.NoWitness IO
    , wcTimeout :: Maybe Int
    , wcTracer :: Tracer IO Trace
    -- ^ Where the write reports its transactions, in the scope that runs it
    , wcSource :: Text
    -- ^ The name the provider's reads report as
    , wcStaged :: Maybe StagedRun
    {- ^ The staged run, when the write signs externally: its transactions
    are collected here, one owner (this command's lifetime), single-threaded
    (the constitution's single-writer rule), and the run ends in the bundle.
    -}
    }

{- | The state one staged write collects: the transactions in build order
with the step that built each, the effect lines the command's readbacks
produced for each, the signer's address as given, how the run ends, the
registry state token the command attached to, and the observations its
readbacks would have narrated. Owned by the one command; nothing else sees
it.
-}
data StagedRun = StagedRun
    { srDir :: FilePath
    -- ^ the journal's directory, where the bundle and bodies are saved
    , srTxs :: IORef [(Text, StagedTransaction)]
    -- ^ each staged transaction with the journal step that built it
    , srEffects :: IORef [(Text, [Text])]
    -- ^ per identity, the effect lines in the order the readbacks produced
    , srSigner :: Text
    , srEnd :: StagedEnd
    , srToken :: IORef (Maybe Text)
    {- ^ the registry's state token, written when the command attaches; a
    bundle before a registry exists carries none
    -}
    , srSeen :: IORef [IO ()]
    {- ^ what the readbacks would narrate as seen on chain, held back: a
    staged body was never there; told once the bundle has landed
    -}
    }

{- | How a staged run ends: the bundle file written for a signer
elsewhere, or the bundle signed from the opened vault and sent through
the core of @singular submit@.
-}
data StagedEnd
    = WriteBundleFile FilePath
    | SignFromVault Wallet

{- | A CONFIRMED successful submission: the signed transaction, the scopes
its build placed it in, and how long its readback took to report once
journalled observed. The constructors are private to this module, so only
a submission this command confirmed can produce one; an already-live
reference found before this command carries no such value (see
'journalObservedId'). Every later step — readback, observation, receipt
fields — takes this value, never a command-wide transaction-id lookup.
-}
data ConfirmedSubmission = ConfirmedSubmission
    { csSigned :: ConwayTx
    , csTxId :: Text
    , csScopes :: [Scope]
    , csElapsed :: IO Double
    , csStaged :: Maybe (Text -> IO ())
    {- ^ In a staged run, where the command's readback of this body lands:
    the staged transaction's effect lines, not a journal @observed@ line.
    Absent in the key-file path.
    -}
    }

-- | The signed transaction a confirmed submission carries.
confirmedTx :: ConfirmedSubmission -> ConwayTx
confirmedTx = csSigned

-- | The confirmed submission's transaction id, as hex.
confirmedTxId :: ConfirmedSubmission -> Text
confirmedTxId = csTxId

-- | The scopes the confirmed submission's build placed it in.
confirmedScopes :: ConfirmedSubmission -> [Scope]
confirmedScopes = csScopes

{- | How long the confirmed submission's readback took when journalled
observed: the milliseconds since its confirmation.
-}
confirmedElapsed :: ConfirmedSubmission -> IO Double
confirmedElapsed = csElapsed

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
    :: Env
    -> FilePath
    -> Text
    -> WriteSettings
    -> (WriteContext -> IO Value)
    -> IO Value
withWrite env dir command ws body = do
    holdBeforeLock
    withTargetLock dir (withSession env dir command ws body)

{- | The node and wallet without the target's lock: for a command that
writes nothing to its target (a create preview), so the target directory
is neither created nor touched.

The receipt names every transaction the command prepared and the case
it met, read from the journal when the command ends ('submissionsOf'),
whether it succeeded or stopped.
-}
withSession
    :: Env
    -> FilePath
    -> Text
    -> WriteSettings
    -> (WriteContext -> IO Value)
    -> IO Value
withSession env dir command ws body = do
    let settings = writeProvider ws
        magic = providerMagic settings
        url = providerUrl settings
    (callerAddr, walletOpt, stagedOpt) <-
        signerWallet dir magic (writeSigner ws)
    connected <- newIORef False
    before <- length <$> readJournal dir
    result <-
        try $
            envWrites env settings $ \caps -> do
                writeIORef connected True
                let caps' = case stagedOpt of
                        Nothing -> caps
                        Just staged -> stagedCapabilities staged caps
                ran <-
                    tryJust failureOf $
                        body
                            WriteContext
                                { wcDir = dir
                                , wcCommand = command
                                , wcWallet = walletOpt
                                , wcCaller = callerAddr
                                , wcCapabilities = caps'
                                , wcTimeout = writeConfirmTimeout ws
                                , wcTracer = envTracer env
                                , wcSource = envSource env
                                , wcStaged = stagedOpt
                                }
                named <- submissionsOf dir before
                case (ran, stagedOpt) of
                    (Right (Object o), Just staged) ->
                        endStagedRun env settings caps magic o staged
                    (Right (Object o), Nothing) ->
                        pure (Object (KeyMap.insert "submissions" named o))
                    (Right v, _) -> pure v
                    (Left (reported, CommandFailure c why fields), Just staged) -> do
                        stagedSoFar <- readIORef (srTxs staged)
                        throwIO . markedLike reported . toException $
                            stagedFailure command stagedSoFar c why fields
                    (Left (reported, CommandFailure c why fields), Nothing) ->
                        throwIO . markedLike reported . toException $
                            CommandFailure c why (fields <> [("submissions", named)])
    case result of
        Right a -> pure a
        Left (e :: SomeException) -> do
            preserveInfrastructure e
            was <- readIORef connected
            if was
                then
                    -- The journal is read here only to say what was sent; a
                    -- journal that cannot be read now never replaces the
                    -- failure the command carries, it is named beside it.
                    try (drop before <$> readJournal dir) >>= \case
                        Right since -> throwIO (admitSubmissions since e)
                        Left (unread :: SomeException)
                            | Just (_ :: SomeAsyncException) <- fromException unread ->
                                throwIO unread
                            | otherwise -> throwIO (withJournalUnread unread e)
                else
                    failWith
                        NodeUnavailable
                        ("the provider at " <> url <> " could not be used: " <> show e)
  where
    failureOf e = case reportedOf e of
        (reported, inner) -> (,) reported <$> fromException inner

{- | Refuse a bundle path that already exists, of any kind, its bytes
untouched: a bundle is created exclusively. The first step of a write with
an external signer ('Singular.CLI.ManagedState.resolveSignerDir'), before
anything else of the run is read or written.
-}
refuseTakenBundle :: FilePath -> IO ()
refuseTakenBundle bundle = do
    taken <- doesPathExist bundle
    when taken $
        failWith
            ClientRefusal
            ( "the bundle file "
                <> bundle
                <> " already exists: name a new file, the bundle is created exclusively"
            )

{- | Name the registry a staged run attached to, for its bundle: the state
token as the command was given it. Nothing in the key-file path.
-}
stageRegistry :: WriteContext -> Text -> IO ()
stageRegistry wc token =
    forM_ (wcStaged wc) $ \staged -> writeIORef (srToken staged) (Just token)

{- | The key-file wallet a command that signs for itself needs: refused as
a client refusal when the write runs with an external signer, which holds
no key at all.
-}
signingWallet :: WriteContext -> IO Wallet
signingWallet wc = case wcWallet wc of
    Just loaded -> pure loaded
    Nothing ->
        failWith
            ClientRefusal
            "a staged run signs nothing: no key is held to sign with"

{- | The caller a write runs as and the wallet it signs from when the
signer is a key file; the staged run it collects when the signer is
external or a vault. The key file loads as today. The external signer
carries only its address — no key file is opened, no vault, and no key
value is held at all: a staged run signs nothing while it runs. The
opened vault stages the same run for its own address and signs only at
the end, from memory. An existing bundle path was already refused by
'refuseTakenBundle', before anything of the run was read.
-}
signerWallet
    :: FilePath
    -> Word32
    -> Signer
    -> IO (Addr, Maybe Wallet, Maybe StagedRun)
signerWallet dir magic = \case
    SignerKeyFile keyPath -> do
        loaded <- loadWallet magic keyPath
        pure (walletAddr loaded, Just loaded, Nothing)
    SignerExternal given bundlePath -> do
        addr <-
            either
                (failWith ClientRefusal)
                pure
                (signerAddress given)
        (,,) addr Nothing . Just
            <$> newStagedRun dir given (WriteBundleFile bundlePath)
    SignerVaultOpened (OpenedVault wallet) -> do
        let addr = walletAddr wallet
        (,,) addr Nothing . Just
            <$> newStagedRun dir (T.pack (bech32Address addr)) (SignFromVault wallet)
    SignerVault vault _ -> unopenedVault vault

-- | A staged run with nothing collected yet.
newStagedRun :: FilePath -> Text -> StagedEnd -> IO StagedRun
newStagedRun dir signer end = do
    staged <- newIORef []
    effects <- newIORef []
    token <- newIORef Nothing
    seen <- newIORef []
    pure
        StagedRun
            { srDir = dir
            , srTxs = staged
            , srEffects = effects
            , srSigner = signer
            , srEnd = end
            , srToken = token
            , srSeen = seen
            }

{- | A vault the command did not open: only the four registry writes open
one, before anything else of the run, so any other command signing from
it is refused, naming the vault.
-}
unopenedVault :: FilePath -> IO a
unopenedVault vault =
    failWith
        ClientRefusal
        ( "this command does not sign from the vault "
            <> vault
            <> ": name a key file, or an address with a bundle file"
        )

{- | Open the vault a write names, once and before anything else of the
run is read or written: the passphrase is read from its descriptor, or from
@SINGULAR_PASSPHRASE@ on a development network, or asked once at the
terminal, and the vault decrypted into the wallet its key derives, held in
memory for this run only. The variable on a public network is refused before
the vault is read. A refused passphrase, an unreadable vault and a wrong
passphrase are client refusals, the last two naming the vault alike. Every
other signer is left as it is.
-}
openWriteSigner :: WriteSettings -> IO WriteSettings
openWriteSigner ws = case writeSigner ws of
    SignerVault vault descriptor -> do
        chosen <- sourceFor (providerMagic (writeProvider ws)) descriptor
        asked <- either (pure . Left) (readPassphrase AskOnce) chosen
        passphrase <-
            either (failWith ClientRefusal . renderPassphraseRefusal) pure asked
        sealed <- try @IOException (BS.readFile vault)
        key <- case sealed of
            Left _ -> notOpened vault
            Right bytes -> either (const (notOpened vault)) pure (openVault passphrase bytes)
        pure
            ws
                { writeSigner =
                    SignerVaultOpened
                        (OpenedVault (walletFromSignKey (providerMagic (writeProvider ws)) key))
                }
    _ -> pure ws
  where
    notOpened = failWith ClientRefusal . renderSignRefusal . SignVaultNotOpened

{- | Narrate what a command's readback saw on chain after its write: at
once in the key-file path; in a staged run the readback read the chained
view over a body only staged, so nothing is narrated as seen until the
bundle lands, which the vault mode reports and the external mode never
does.
-}
reportSeen :: WriteContext -> [Scope] -> What -> IO ()
reportSeen wc scopes event = case wcStaged wc of
    Nothing -> report (wcTracer wc) scopes event
    Just staged ->
        modifyIORef' (srSeen staged) (<> [report (wcTracer wc) scopes event])

{- | The capabilities of a staged run: every acquisition reads through the
chained view over the transactions staged so far — one snapshot per
acquisition, exactly the model — and the submission capability is never
called: a staged run sends nothing.
-}
stagedCapabilities
    :: StagedRun
    -> Capabilities Cage.NoWitness IO
    -> Capabilities Cage.NoWitness IO
stagedCapabilities staged caps =
    let (network, provider) = capReads caps
        -- The composed provider with only its acquisition decorated: every
        -- other capability stays the one composition supplied.
        chained =
            provider
                { Cage.acquire = \requested action ->
                    Cage.acquire
                        provider
                        requested
                        ( chainedSession
                            (map snd <$> readIORef (srTxs staged))
                            >=> action
                        )
                }
    in  caps
            { capReads = (network, chained)
            , capSubmit = \_ ->
                throwIO
                    (ErrorCall "the submission capability is never called in a staged run")
            }

{- | A staged run's failure as its receipt states it. Nothing a staged run
builds is signed, sent or confirmed, but the command's own account of a
stop is written for the key-file path, where every built body has landed by
then ("the preparation … stands confirmed", "the reject confirmed but …").
So once a body is staged that account is replaced by one that claims nothing
landed, the staged bodies are listed as staged, and the account's structured
fields (amounts, allowances) are kept. Before anything is staged the account
stands as written. Never a submissions field: nothing was submitted.
-}
stagedFailure
    :: Text
    -> [(Text, StagedTransaction)]
    -> OutcomeClass
    -> String
    -> [(Text, Value)]
    -> CommandFailure
stagedFailure command stagedSoFar c why fields = case stagedSoFar of
    [] -> CommandFailure c why kept
    _ ->
        CommandFailure
            c
            ( T.unpack command
                <> " stopped after staging "
                <> show (length stagedSoFar)
                <> " unsigned transaction(s), before its bundle was written: none was"
                <> " signed, sent or confirmed, and no bundle file was written"
            )
            (kept <> [("staged", toJSON (map stagedEntry stagedSoFar))])
  where
    kept = [f | f@(k, _) <- fields, k `notElem` ["submissions", "submitted"]]
    stagedEntry (step, stagedTx) =
        object
            [ "step" .= step
            , "identity" .= txIdHex (stagedBody stagedTx)
            ]

{- | Each transaction this command prepared — the @prepared@ lines it
appended after the first @before@ — in order, with the case the journal shows
it met ('submissionCase') and whether its after-state was observed.
-}
submissionsOf :: FilePath -> Int -> IO Value
submissionsOf dir before = do
    entries <- readJournal dir
    pure $
        toJSON
            [ object
                [ "step" .= step
                , "tx" .= txid
                , "case" .= (caseName <$> submissionCase entries txid)
                , "observed"
                    .= any
                        (\e -> journalTxId e == txid && journalEvent e == "observed")
                        entries
                ]
            | p <- drop before entries
            , journalEvent p == "prepared"
            , let step = journalStep p
                  txid = journalTxId p
            ]

{- | The failure a command carries when its journal could not be read
afterwards: unchanged, its outcome, reason and fields kept, with the read's
failure named beside them; anything that is not a command failure is left
as it is.
-}
withJournalUnread :: SomeException -> SomeException -> SomeException
withJournalUnread unread e = case fromException inner of
    Just (CommandFailure c why fields) ->
        markedLike reported . toException $
            CommandFailure
                c
                why
                (fields <> [("journalUnread", toJSON (show unread))])
    Nothing -> e
  where
    (reported, inner) = reportedOf e

{- | A command that has sent a transaction never ends as a client refusal,
whose receipt says nothing was submitted. Given the journal lines this
command appended and the failure that stopped it, a failure left
unclassified or classified as a refusal becomes @partial@ when any of
those lines records a send (@submitted@ or @submit-unknown@), naming
the transactions sent; any other failure is returned unchanged.
-}
admitSubmissions :: [JournalEntry] -> SomeException -> SomeException
admitSubmissions since e
    | null sent = e
    | Just (_ :: SomeAsyncException) <- fromException e = e
    | Just (_ :: WaitFailure) <- fromException e = e
    | otherwise = case fromException inner of
        Just (CommandFailure c why fields)
            | c /= ClientRefusal -> e
            | otherwise -> markedLike reported (admitted why fields)
        Nothing -> markedLike reported (admitted (show inner) [])
  where
    (reported, inner) = reportedOf e
    sent =
        nub
            [ journalTxId j
            | j <- since
            , journalEvent j `elem` ["submitted", "submit-unknown"]
            ]
    admitted why fields =
        toException $
            CommandFailure
                Partial
                ( "this command sent "
                    <> T.unpack (T.intercalate ", " sent)
                    <> " before it stopped, and nothing is resubmitted: "
                    <> why
                )
                (("submitted", toJSON sent) : fields)

{- | Hold an exclusive advisory lock on @dir/.lock@ for the action, or
refuse at once when another process holds it.
-}
withTargetLock :: FilePath -> IO a -> IO a
withTargetLock dir action =
    withTargetLockOr
        dir
        action
        ( failWith
            ConcurrentWriter
            ( "another singular process is writing to "
                <> dir
                <> "; nothing was read or submitted"
            )
        )

{- | Run the action holding the target's lock, or the alternative at
once when another process holds it.
-}
withTargetLockOr :: FilePath -> IO a -> IO a -> IO a
withTargetLockOr dir action busy = do
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
                Left (_ :: IOException) -> busy
                Right () -> action
        )

{- | How long a write waits for a confirmation when the caller names no
@--confirm-timeout@: ten minutes. Past it the submission is journalled
@unconfirmed@, unresolved, and never resubmitted.
-}
defaultConfirmSeconds :: Int
defaultConfirmSeconds = 600

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
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalChainPoint = Nothing
        , journalSession = Nothing
        , journalObservedTip = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTransitions = Nothing
        , journalTime = Nothing
        }

{- | What a submission's readback must find, journalled at @prepared@ so a
later inspect can check exactly that step's after-state and nothing
more general.
-}
data Expectation
    = Expectation
        { exKey :: Maybe ByteString
        , exAfter :: Text
        , exEdge :: Maybe Integer
        , exRootBefore :: Maybe ByteString
        , exRootAfter :: Maybe ByteString
        }
    | FoldExpectation (NonEmpty FoldTransition)

-- | An expectation with no key or roots.
expecting :: Text -> Expectation
expecting after = Expectation Nothing after Nothing Nothing Nothing

{- | The scalar journal fields of a fold's transitions: the key,
expectation and edge of the first transition, the root before of the
first, the root after of the last, in one function.
-}
foldExpectationScalars
    :: NonEmpty FoldTransition -> (Text, Text, Integer, Text, Text)
foldExpectationScalars (first :| rest) =
    let lastT = case rest of
            [] -> first
            _ -> last rest
    in  ( transitionKey first
        , transitionExpect first
        , transitionEdge first
        , transitionRootBefore first
        , transitionRootAfter lastT
        )

{- | The prepared line's expectation fields: key, expectation, edge,
roots and the transition list. For a fold the list and the scalars that
mirror its first and last transition; otherwise what is written today
and no list.
-}
expectationJournalFields
    :: Expectation
    -> ( Maybe Text
       , Maybe Text
       , Maybe Integer
       , Maybe Text
       , Maybe Text
       , Maybe [FoldTransition]
       )
expectationJournalFields (Expectation k a e rb ra) =
    (hexT <$> k, Just a, e, hexT <$> rb, hexT <$> ra, Nothing)
expectationJournalFields (FoldExpectation ts) =
    let (k, e, edge, rb, ra) = foldExpectationScalars ts
    in  (Just k, Just e, Just edge, Just rb, Just ra, Just (toList ts))

{- | Build one transaction from one view of the node, then sign it and
submit it journalled under that view's chain point and the expectation
the build decided. The view is released before the transaction is signed
and sent. The only way a command writes: the journalled point is the
building view's by construction. Returns the confirmed submission and
whatever else the build produced.
-}
submitBuilt
    :: WriteContext
    -> Text
    -> (r -> Expectation)
    -> (Cage.Session Cage.NoWitness IO -> IO (ConwayTx, r))
    -> IO (ConfirmedSubmission, r)
submitBuilt wc step expect build = submitBuiltIn wc step [] expect (const build)

{- | 'submitBuilt', with the build reading what it names and placing its
transaction where it decides: a fold learns its request and edge only from
the view it builds from. The build is given 'Building'. Its read step (what
it read, from the view's acquisition) closes when it first reports what it
found or decides; when it decides, it reports the protocol event that opens
those scopes (an edge started), and from then on its own mechanics, the
signing, submission, confirmation and readback sit inside them; what it read
before deciding sits outside.

A build that fails is a refusal where it happens: by local script evaluation
when a script failed in the build's own view, by the client otherwise. A
submission the ledger refuses is a ledger rejection; a submission with no
answer, or a failed one, is the provider's transport. The command's outcome
class is unchanged.
-}
submitBuiltIn
    :: WriteContext
    -> Text
    -> [Text]
    -> (r -> Expectation)
    -> (Building -> Cage.Session Cage.NoWitness IO -> IO (ConwayTx, r))
    -> IO (ConfirmedSubmission, r)
submitBuiltIn wc step items expect build = do
    progress <-
        BuildProgress
            <$> newIORef []
            <*> newIORef (null items)
            <*> newIORef False
    since <- startTimer
    let building = Tracer $ \(Trace path event) -> do
            placed <- readIORef (bpScopes progress)
            traceWith
                (wcTracer wc)
                (Trace (placed <> (InTransaction step : path)) event)
        closeReadWith end = do
            open <- not <$> readIORef (bpReadClosed progress)
            when open $ do
                writeIORef (bpReadClosed progress) True
                ms <- since
                traceWith (how building) (Fetched (Fetch items (wcSource wc) ms end))
        closeRead = closeReadWith Done
        acting =
            Building
                { found = \scopes event -> do
                    closeRead
                    report (wcTracer wc) scopes event
                , place = \scopes event -> do
                    closeRead
                    writeIORef (bpScopes progress) scopes
                    report (wcTracer wc) scopes event
                }
    let provider = tracedReads (wcSource wc) (readsUnder building) (wcCapabilities wc)
        -- the build's own session records whether a script failed its local evaluation
        recording v =
            v
                { Cage.sessionEvaluated = \e -> do
                    when (evalFailed e > 0) (writeIORef (bpEvalFailed progress) True)
                    Cage.sessionEvaluated v e
                }
    built <-
        try $ Cage.withLatest provider $ \v -> do
            made@(unsigned, _) <-
                timedTrace
                    (txUnder building)
                    (\ms end -> TxBuilt step ms (ended end))
                    (build acting (recording v))
            -- A fresh acquisition: a preparation the build itself staged (the
            -- funding seam runs inside the build) is in this snapshot, not in v.
            forM_ (wcStaged wc) $ \staged -> do
                stagedTx <-
                    Cage.withLatest provider $ \now ->
                        stagedTransactionOf step now unsigned
                modifyIORef' (srTxs staged) (<> [(step, stagedTx)])
            scope <- sessionReceipt (wcCapabilities wc) v
            pure (scope, made)
    (scope, (unsigned, extra)) <- case built of
        Right made -> pure made
        Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise -> do
                failed <- readIORef (bpEvalFailed progress)
                let cls = errorClassOf e
                closeReadWith (FailedWith cls)
                refused building $
                    Refused
                        (if failed then EvaluationRefused else ClientRefused)
                        (Just cls)
                -- a bounded wait keeps its own type for the caller to recognise
                case fromException e of
                    Just (_ :: WaitFailure) -> throwIO e
                    Nothing -> throwIO (Reported e)
    placed <- readIORef (bpScopes progress)
    let tracer = within (InTransaction step) (inScopes placed (wcTracer wc))
    case wcStaged wc of
        Just staged -> do
            traceWith
                (how tracer)
                (Staged step (txIdHex unsigned))
            let record detail =
                    modifyIORef'
                        (srEffects staged)
                        (upsert (txIdHex unsigned) detail)
            pure
                ( ConfirmedSubmission
                    unsigned
                    (txIdHex unsigned)
                    placed
                    (pure 0)
                    (Just record)
                , extra
                )
        Nothing -> do
            (signed, elapsed) <-
                journalledSubmit tracer wc step (expect extra) scope unsigned
            pure
                ( ConfirmedSubmission signed (txIdHex signed) placed elapsed Nothing
                , extra
                )
  where
    upsert key detail = \case
        [] -> [(key, [detail])]
        ((k, ds) : rest)
            | k == key -> (k, ds <> [detail]) : rest
            | otherwise -> (k, ds) : upsert key detail rest

{- | One staged transaction: the unsigned body with the resolution of
every input it spends and references, read from a view acquired after the
build — the chained view holding every transaction staged before it,
including a preparation the build itself staged. A reference the view
cannot resolve is a refusal: the body would not have been built over it.
-}
stagedTransactionOf
    :: Text
    -> Cage.Session Cage.NoWitness IO
    -> ConwayTx
    -> IO StagedTransaction
stagedTransactionOf step v body = do
    spent <-
        concat <$> mapM resolve (Set.toList (body ^. bodyTxL . inputsTxBodyL))
    reference <-
        concat
            <$> mapM resolve (Set.toList (body ^. bodyTxL . referenceInputsTxBodyL))
    pure
        StagedTransaction
            { stagedBody = body
            , stagedSpentOutputs = spent
            , stagedReferenceOutputs = reference
            }
  where
    resolve ref =
        Cage.outputs v (Cage.AtTxIn ref) >>= \case
            Left failure ->
                failWith
                    ClientRefusal
                    ( "the staged "
                        <> T.unpack step
                        <> " spends or reads an output the view does not hold: "
                        <> show failure
                    )
            Right found -> pure (Cage.value found)

{- | The necessary synchronous exceptional state of one 'submitBuiltIn'
invocation, private to this module. 'bpScopes' collects the placement the
build's 'place' callback reports; 'bpReadClosed' marks the read step
closed before a sink may throw; 'bpEvalFailed' is monotonic: once a script
fails local evaluation it stays failed, marked before any delegated
callback can throw. A value alone cannot report a throw: when the build or
a callback throws, the return path carrying a value never runs, yet these
marks must already be recorded for the exception path to classify and
report them. Owned by the one invocation; never shared between
transactions, threads, or commands.
-}
data BuildProgress = BuildProgress
    { bpScopes :: IORef [Scope]
    , bpReadClosed :: IORef Bool
    , bpEvalFailed :: IORef Bool
    }

-- | What a build reports while it decides, from its own view.
data Building = Building
    { found :: [Scope] -> What -> IO ()
    -- ^ A protocol fact the build read, in these scopes, outermost first
    , place :: [Scope] -> What -> IO ()
    {- ^ The protocol event that opens these scopes: the rest of the build and
    its transaction sit inside them
    -}
    }

{- | One read step of a command: a view acquired and read through, timed and
reported with what it read.
-}
readStep
    :: Tracer IO Trace
    -> Text
    -> [Text]
    -> Capabilities Cage.NoWitness IO
    -> (Cage.Session Cage.NoWitness IO -> IO a)
    -> IO a
readStep tracer source items caps body =
    timedRead
        tracer
        source
        items
        (Cage.withLatest (readsIn source tracer caps) body)

{- | A read step inside a view already held: timed and reported with what it
read.
-}
timedRead :: Tracer IO Trace -> Text -> [Text] -> IO a -> IO a
timedRead tracer source items =
    timedTrace
        (how tracer)
        (\ms end -> Fetched (Fetch items source ms (ended end)))

-- | The tracer inside these scopes, outermost first.
inScopes :: [Scope] -> Tracer IO Trace -> Tracer IO Trace
inScopes scopes tracer = foldl (flip within) tracer scopes

-- | Report a refusal where it happened.
refused :: Tracer IO Trace -> What -> IO ()
refused tracer = traceWith (what tracer)

-- | Stop with a failure whose refusal was just reported.
reportedAs :: OutcomeClass -> String -> IO a
reportedAs c why = throwIO (Reported (toException (CommandFailure c why [])))

-- | The capabilities' provider, its reads traced into this scope.
readsIn
    :: Text
    -> Tracer IO Trace
    -> Capabilities Cage.NoWitness IO
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
readsIn source tracer = tracedReads source (readsUnder tracer)

{- | Sign; save the signed transaction and journal @prepared@ with its
inputs, body hash and the chain point of the view its body was built
from; send; journal the answer;
await the confirmation; journal it. Returns the signed transaction and the
milliseconds-since-confirmation action once confirmed. The command journals
@observed@ after its own readback.
-}
journalledSubmit
    :: Tracer IO Trace
    -> WriteContext
    -> Text
    -> Expectation
    -> Value
    -> ConwayTx
    -> IO (ConwayTx, IO Double)
journalledSubmit tracer wc step ex scope unsigned = do
    let txid = txIdHex unsigned
        txs = txUnder tracer
        Coin fee = unsigned ^. bodyTxL . feeTxBodyL
    (sealed, bytes) <-
        timedTrace
            txs
            (\ms end -> TxSigned step txid (Just fee) ms (ended end))
            $ do
                signing <- case wcWallet wc of
                    Just loaded -> pure (signTx (walletSignKey loaded) unsigned)
                    Nothing ->
                        failWith
                            ClientRefusal
                            "a staged run signs nothing: no key is held to sign with"
                let sealed' = signing
                    bytes' = serialize' (eraProtVerHigh @ConwayEra) (signedTx sealed')
                _ <- evaluate (BS.length bytes')
                pure (sealed', bytes')
    let signed = signedTx sealed
        dir = wcDir wc
        caps = wcCapabilities wc
        journal event detail =
            appendJournal
                dir
                (blankEntry wc step txid event){journalDetail = detail}
        bodyPath = bodiesDir dir </> T.unpack txid <> ".cbor.hex"
    createDirectoryIfMissing True (bodiesDir dir)
    durableWrite bodyPath (B16.encode bytes)
    let (jKey, jExpect, jEdge, jRootBefore, jRootAfter, jTransitions) =
            expectationJournalFields ex
    appendJournal
        dir
        (blankEntry wc step txid "prepared")
            { journalInputs =
                Just (map renderOutRef (toList (signed ^. bodyTxL . inputsTxBodyL)))
            , journalBody = Just bodyPath
            , journalBodyHash =
                Just (hexT (hashToBytes (hashWith @Blake2b_256 id bytes)))
            , journalNetwork = Just (providerNetwork caps)
            , journalEra = Just "Conway"
            , journalChainPoint = Nothing
            , journalSession = Just scope
            , journalObservedTip = Nothing
            , journalKey = jKey
            , journalExpect = jExpect
            , journalEdge = jEdge
            , journalRootBefore = jRootBefore
            , journalRootAfter = jRootAfter
            , journalTransitions = jTransitions
            }
    answer <-
        harnessSubmission
            step
            (tipAtSubmission (wcSource wc) tracer caps)
            ( \tip -> do
                let (lower, upper) = validityOf signed
                Wait.tryOutcome
                    ( timedTrace
                        txs
                        ( \ms end ->
                            TxSubmitted
                                { submitStep = step
                                , submitTxId = txid
                                , submitLower = lower
                                , submitUpper = upper
                                , submitTip = tip
                                , submitElapsed = ms
                                , submitVerdict = case end of
                                    Right (Cage.SubmitAccepted _) -> Accepted
                                    Right (Cage.SubmitRefused _) -> LedgerRefusedIt
                                    Right (Cage.SubmitFailed _) -> ProviderFailed
                                    Right (Cage.SubmitWrongNetwork _ _) -> WrongNetwork
                                    Left c -> SubmitThrew c
                                }
                        )
                        (capSubmit caps sealed)
                    )
            )
    case answer of
        Left (e :: SomeException) -> do
            journal "submit-unknown" (Just (T.pack (show e)))
            refused tracer (Refused TransportFailed (Just (errorClassOf e)))
            reportedAs
                Partial
                ( "no answer from the node for "
                    <> T.unpack txid
                    <> "; it may or may not have been accepted: "
                    <> show e
                )
        Right (Cage.SubmitRefused reason) -> do
            journal "rejected" (Just (T.pack (show reason)))
            refused tracer (Refused LedgerRejected Nothing)
            reportedAs
                LedgerRefusal
                (T.unpack step <> " refused by the node: " <> show reason)
        Right (Cage.SubmitFailed reason) -> do
            journal "submit-unknown" (Just reason)
            refused tracer (Refused TransportFailed Nothing)
            reportedAs Partial ("no submission answer: " <> T.unpack reason)
        Right (Cage.SubmitWrongNetwork wanted actual) -> do
            journal "rejected" (Just (T.pack (show (wanted, actual))))
            refused tracer (Refused ClientRefused Nothing)
            reportedAs
                ClientRefusal
                "submission refused on the configured network"
        Right (Cage.SubmitAccepted _) -> do
            journal "submitted" Nothing
            holdAfterSubmit step
    -- Confirmation belongs to this calling thread. capConfirm must be
    -- interruptible: its deadline and caller cancellation unwind the same
    -- action, including provider cleanup. An uninterruptible capability
    -- delays return until it cooperates; no confirmation worker escapes.
    let limit = fromMaybe defaultConfirmSeconds (wcTimeout wc) * 1_000_000
    seen <-
        timedTrace
            txs
            ( \ms end ->
                TxConfirmed step txid ms $ case end of
                    Right (Left e)
                        | Just (_ :: SomeAsyncException) <- fromException e ->
                            ConfirmThrew (errorClassOf e)
                        | otherwise -> ConfirmFailed (errorClassOf e)
                    Right (Right Nothing) -> ConfirmTimedOut
                    Right (Right (Just ())) -> Confirmed
                    Left c -> ConfirmThrew c
            )
            $ try (timeout limit (capConfirm caps signed))
    case seen of
        Left (e :: SomeException) -> do
            -- The node accepted the transaction; only the wait for its
            -- confirmation failed. It stays unresolved, named, and is
            -- never resubmitted.
            journal
                "unconfirmed"
                (Just ("the confirmation wait failed: " <> T.pack (show e)))
            preserveInfrastructure e
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
            since <- startTimer
            pure (signed, since)

{- | The node's tip slot at the moment of submission, for the submission's
event: one more acquisition, its reads traced like every other. A tip that
cannot be read is unreadable; it never stops the submission.
-}
tipAtSubmission
    :: Text -> Tracer IO Trace -> Capabilities Cage.NoWitness IO -> IO TipAt
tipAtSubmission source tracer caps =
    Wait.tryOutcome
        ( Cage.withLatest
            (readsIn source tracer caps)
            (fmap Cage.observedSlot . Cage.tip)
        )
        >>= \case
            Right (SlotNo s) -> pure (TipSlot s)
            Left (e :: SomeException)
                | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                | otherwise -> pure TipUnreadable

-- | The slots a transaction's validity interval names, each when it has one.
validityOf :: ConwayTx -> (Maybe Word64, Maybe Word64)
validityOf tx =
    let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
        slot = \case
            SJust (SlotNo s) -> Just s
            SNothing -> Nothing
    in  (slot lower, slot upper)

{- | Journal the fourth phase: the command read back what a confirmed
transaction made, and says what it read. Takes the confirmed submission
itself — its scopes and its confirmation-age action — never a
transaction-id lookup.
-}
journalObserved
    :: WriteContext -> Text -> ConfirmedSubmission -> Text -> IO ()
journalObserved wc step confirmed detail = case csStaged confirmed of
    Just record -> record detail
    Nothing -> do
        let txid = confirmedTxId confirmed
        appendJournal
            (wcDir wc)
            (blankEntry wc step txid "observed"){journalDetail = Just detail}
        readback <- confirmedElapsed confirmed
        let placed = confirmedScopes confirmed
        traceWith
            (txUnder (within (InTransaction step) (inScopes placed (wcTracer wc))))
            (TxObserved step txid readback)

{- | The same, for an already-live reference found before this command:
known by its original id, with no current-command confirmation, so zero
elapsed and empty scopes by construction (there is no map to consult). A
staged run records nothing here: it observes no chain fact of its own, and
the reference its view found may be one of its own staged outputs.
-}
journalObservedId :: WriteContext -> Text -> Text -> Text -> IO ()
journalObservedId wc step txid detail = unless (isJust (wcStaged wc)) $ do
    appendJournal
        (wcDir wc)
        (blankEntry wc step txid "observed"){journalDetail = Just detail}
    traceWith
        (txUnder (within (InTransaction step) (inScopes [] (wcTracer wc))))
        (TxObserved step txid 0)

hexT :: ByteString -> Text
hexT = T.pack . BC.unpack . B16.encode

providerNetwork :: Capabilities Cage.NoWitness IO -> Word32
providerNetwork caps = let Cage.Network magic = fst (capReads caps) in magic

-- | Never turn a bounded wait or cancellation into a client/ledger refusal.
preserveInfrastructure :: SomeException -> IO ()
preserveInfrastructure failure
    | Just (_ :: SomeAsyncException) <- fromException failure =
        throwIO failure
    | Just (_ :: WaitFailure) <- fromException failure = throwIO failure
    | otherwise = pure ()

{- | Open the read capabilities of the named provider and read through one
view, every read traced into this scope.
-}
readOnce
    :: Env
    -> ProviderSettings
    -> [Text]
    -> ( Capabilities Cage.NoWitness IO
         -> Cage.Session Cage.NoWitness IO
         -> IO a
       )
    -> IO a
readOnce env settings items body =
    envReads env settings $ \caps ->
        readStep (envTracer env) (envSource env) items caps (body caps)

-- ---------------------------------------------------------
-- The staged run's end: one bundle, waiting for signatures
-- ---------------------------------------------------------

{- | The bundle of a staged run: its transactions in build order, each with
its identity, envelope, deadline and the effect lines the command's
readbacks produced for it. The signer is the address as given. Pure.
-}
bundleOfRun
    :: Text
    -> Word32
    -> Maybe Text
    -> Text
    -> [(Text, StagedTransaction, [Text])]
    -> Bundle
bundleOfRun command magic token signer entries =
    Bundle
        { bundleCommand = command
        , bundleNetworkMagic = magic
        , bundleStateToken = token
        , bundleSigners = signer :| []
        , bundleTransactions = entryOf <$> ne
        }
  where
    ne = case entries of
        [] -> error "bundleOfRun: a staged run with no transaction"
        (e : es) -> e :| es
    entryOf (_step, staged, effects) =
        let body = stagedBody staged
        in  BundleTransaction
                { bundleTxIdentity = bodyIdentity body
                , bundleTxEnvelope = transactionEnvelope body
                , bundleTxDeadline = bodyDeadline body
                , bundleTxEffects = effects
                }

{- | End a staged run: assemble the bundle from what the run collected in
build order, save its bytes and every body beside the journal with one
waiting line per transaction, then end it as the signer says: create the
bundle file exclusively for a signer elsewhere, or sign every member from
the opened vault and send them through the submit core ('endFromVault').
For the bundle file, the receipt states the outcome and the bundle as
fact, the command's own fields as expectations — nothing derived from a
staged body is stated as observed.
-}
endStagedRun
    :: Env
    -> ProviderSettings
    -> Capabilities Cage.NoWitness IO
    -> Word32
    -> KeyMap.KeyMap Value
    -> StagedRun
    -> IO Value
endStagedRun env settings caps magic fields staged = do
    collected <- readIORef (srTxs staged)
    effects <- readIORef (srEffects staged)
    token <- readIORef (srToken staged)
    case collected of
        [] -> failWith ClientRefusal "the staged run built no transaction"
        (_ : _) -> pure ()
    let command = case KeyMap.lookup "command" fields of
            Just (String c) -> c
            _ -> ""
        inOrder = collected
        effectOf stagedTx =
            fromMaybe [] (lookup (txIdHex (stagedBody stagedTx)) effects)
        entries = [(step, stagedTx, effectOf stagedTx) | (step, stagedTx) <- inOrder]
        bundle = bundleOfRun command magic token (srSigner staged) entries
        bytes = encodeBundle bundle
        bundleHash = hexT (hashToBytes (hashWith @Blake2b_256 id bytes))
    journalWaitingForSignatures
        (srDir staged)
        magic
        bytes
        bundle
        [ (step, hexT (bodyIdentity (stagedBody stagedTx)))
        | (step, stagedTx) <- inOrder
        ]
    let saved =
            bodiesDir (srDir staged)
                </> ("bundle-" <> T.unpack bundleHash <> ".bundle")
        own =
            KeyMap.delete "command" $
                KeyMap.delete "outcome" $
                    KeyMap.delete "reconciled" fields
        summaryWith extra =
            object
                ( [ "hash" .= bundleHash
                  , "saved" .= T.pack saved
                  , "signers" .= [srSigner staged]
                  , "transactions"
                        .= [ object
                                ( [ "step" .= step
                                  , "identity" .= hexT (bodyIdentity (stagedBody stagedTx))
                                  ]
                                    <> [ "deadline" .= slot
                                       | Just slot <- [bodyDeadline (stagedBody stagedTx)]
                                       ]
                                    <> [ "effects" .= effectOf stagedTx
                                       | not (null (effectOf stagedTx))
                                       ]
                                )
                           | (step, stagedTx) <- inOrder
                           ]
                  ]
                    <> extra
                )
        reconciled = [("reconciled", r) | Just r <- [KeyMap.lookup "reconciled" fields]]
    case srEnd staged of
        WriteBundleFile bundlePath -> do
            created <- writeBundleExclusively bundlePath bytes
            unless created $
                failWith
                    ClientRefusal
                    ( "the bundle file "
                        <> bundlePath
                        <> " cannot be written: it already exists; the bundle "
                        <> T.unpack bundleHash
                        <> " is saved beside the journal and journalled waiting for signatures"
                    )
            pure . Object . KeyMap.fromList $
                [ ("command", String command)
                , ("outcome", String (outcomeName WaitingForSignatures))
                ]
                    <> reconciled
                    <> [ ("expected", Object own)
                       , ("bundle", summaryWith ["written" .= T.pack bundlePath])
                       ]
        SignFromVault wallet ->
            endFromVault
                env
                settings
                caps
                staged
                command
                bundle
                bytes
                bundleHash
                wallet
                (KeyMap.toList own)
                (summaryWith [])
                reconciled

{- | Sign every member of the bundle from the opened vault and send them in
order through the core of @singular submit@, then journal the outcome by
the journal phase's rules, in one view of the chain:

- the node refused a member: that member's dead line, "refused by the
  node" with its answer, then the reconciliation, which finds what went
  through by identity and gives every other member its dead line; the
  run ends as the submit core's refusal, naming the members that went
  through;
- the core sent everything: the reconciliation journals each member
  landed; once the bundle has landed, the command's fields are stated as
  fact and the readbacks' observations are narrated;
- any other answer: the bundle stays pending, and the next run settles it
  by identity.

The receipt carries the bundle and the core's per-transaction chain
facts; whenever the bundle has not landed, the command's own fields sit
under expected. A failure of the bookkeeping once the core has answered
keeps the core's outcome, its sends and the bundle, names that failure,
and leaves the bundle to the next run. No passphrase or key byte is
written or printed.
-}
endFromVault
    :: Env
    -> ProviderSettings
    -> Capabilities Cage.NoWitness IO
    -> StagedRun
    -> Text
    -> Bundle
    -> BS.ByteString
    -> Text
    -> Wallet
    -> [(Key.Key, Value)]
    -> Value
    -> [(Key.Key, Value)]
    -> IO Value
endFromVault env settings caps staged command bundle bytes bundleHash wallet own summary reconciled = do
    witnesses <-
        either
            (failWith ClientRefusal . renderSignRefusal)
            pure
            (bundleWitnesses bundle (walletSignKey wallet))
    sent <-
        try @CommandFailure
            (submitInMemory env settings bundle bytes witnesses)
    let dir = srDir staged
        settle
            :: (Cage.Session Cage.NoWitness IO -> IO ())
            -> IO [(Text, BundleState)]
        settle extra =
            Cage.withLatest (readsIn (envSource env) (envTracer env) caps) $ \v -> do
                extra v
                fst <$> reconcileBundles command dir v
        expected = [("expected", Object (KeyMap.fromList own))]
        bundleField = [("bundle", summary)]
        framing = [(Key.toText k, v) | (k, v) <- bundleField <> expected]
        submissionsOf' fields = [(k, v) | (k, v) <- fields, k `elem` ["bundleHash", "submissions"]]
        -- Once the core has answered, the transactions it sent are paid
        -- for: a failure of the journal's bookkeeping after it (a read, an
        -- append, the reconciliation) keeps the core's outcome, its sends
        -- and the bundle, names that failure on its own, and leaves the
        -- bundle for the next run to settle by identity.
        bookkept :: OutcomeClass -> String -> [(Text, Value)] -> IO a -> IO a
        bookkept outcome why fields act =
            try act >>= \case
                Right a -> pure a
                Left (failure :: SomeException)
                    | Just (_ :: SomeAsyncException) <- fromException failure ->
                        throwIO failure
                    | otherwise ->
                        throwIO $
                            CommandFailure
                                outcome
                                ( why
                                    <> "; journalling the outcome failed, and the next run settles bundle "
                                    <> T.unpack bundleHash
                                    <> " by identity: "
                                    <> show failure
                                )
                                (fields <> [("bookkeeping", toJSON (show failure))])
    case sent of
        Right core -> do
            let sentFields = submissionsOf' core <> framing
            states <-
                bookkept
                    Partial
                    ( "every member of bundle "
                        <> T.unpack bundleHash
                        <> " was sent and confirmed"
                    )
                    sentFields
                    (settle (const (pure ())))
            case lookup bundleHash states of
                Just BundleLanded -> do
                    sequence_ =<< readIORef (srSeen staged)
                    pure . Object . KeyMap.fromList $
                        [ ("command", String command)
                        , ("outcome", String (outcomeName Success))
                        ]
                            <> reconciled
                            <> own
                            <> bundleField
                            <> [(Key.fromText k, v) | (k, v) <- core, k == "submissions"]
                _ ->
                    failWithFields
                        Partial
                        ( "every member of bundle "
                            <> T.unpack bundleHash
                            <> " was sent, but not all are found on chain yet; the next run settles the bundle by identity"
                        )
                        sentFields
        Left (CommandFailure LedgerRefusal why coreFields)
            | Just refusedId <- refusedMember coreFields -> do
                let refusalFields =
                        coreFields
                            <> framing
                            <> [("wentThrough", toJSON (wentThrough coreFields))]
                _ <- bookkept LedgerRefusal why refusalFields $
                    settle $ \v -> do
                        point <- Cage.tip v
                        entries <- readJournal dir
                        forM_
                            [ e
                            | e <- entries
                            , journalTxId e == refusedId
                            , journalEvent e == "waiting-for-signatures"
                            ]
                            $ \waiting ->
                                appendJournal
                                    dir
                                    (deadLine waiting (renderPoint point) (refusalAnswer refusedId why))
                throwIO (CommandFailure LedgerRefusal why refusalFields)
        Left (CommandFailure c why coreFields) ->
            throwIO (CommandFailure c why (coreFields <> framing))
  where
    -- the members the core sent or found before the refusal: those went through
    wentThrough coreFields =
        [ identity
        | ("submissions", Array xs) <- coreFields
        , Object o <- toList xs
        , Just (String done) <- [KeyMap.lookup "how" o]
        , done `elem` ["sent", "found"]
        , Just (String identity) <- [KeyMap.lookup "identity" o]
        ]
    -- the member the node refused, as the submit core names it
    refusedMember coreFields =
        listToMaybe
            [ identity
            | ("submissions", Array xs) <- coreFields
            , Object o <- toList xs
            , Just (String "submission-refused") <- [KeyMap.lookup "how" o]
            , Just (String identity) <- [KeyMap.lookup "identity" o]
            ]
    -- the node's answer, as the submit core words it after the identity
    refusalAnswer refusedId why =
        let said = T.pack why
        in  fromMaybe said (T.stripPrefix (refusedId <> " ") said)

{- | A member's dead line, from its waiting line: the reason and the tip
observed, nothing of the body.
-}
deadLine :: JournalEntry -> Text -> Text -> JournalEntry
deadLine waiting tip reason =
    waiting
        { journalEvent = "dead"
        , journalDetail = Just reason
        , journalInputs = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalChainPoint = Nothing
        , journalSession = Nothing
        , journalObservedTip = Just tip
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTransitions = Nothing
        }

{- | Create the bundle file exclusively and make it durable: an existing
file wins, and its bytes stay untouched. Nothing else may hold the path.
-}
writeBundleExclusively :: FilePath -> BS.ByteString -> IO Bool
writeBundleExclusively path bytes = do
    opened <-
        try
            ( openFd
                path
                WriteOnly
                defaultFileFlags{exclusive = True, creat = Just 0o644}
            )
    case opened of
        Left (_ :: IOException) -> pure False
        Right fd -> do
            writeAllFd fd bytes
            fileSynchronise fd
            True <$ closeFd fd
  where
    writeAllFd fd b
        | BS.null b = pure ()
        | otherwise = do
            n <- fdWrite fd b
            writeAllFd fd (BS.drop (fromIntegral n) b)

{- | The caller a signer names: the key file loads as today and yields its
wallet; the external signer yields its address alone — no key file is
opened and no key value is constructed. The key-file refusal texts are
the loader's own.
-}
loadSignerWallet :: Word32 -> Signer -> IO (Addr, Maybe Wallet)
loadSignerWallet magic = \case
    SignerKeyFile keyPath -> do
        loaded <- loadWallet magic keyPath
        pure (walletAddr loaded, Just loaded)
    SignerExternal given _ ->
        either (failWith ClientRefusal) pure (signerAddress given)
            >>= \addr -> pure (addr, Nothing)
    SignerVaultOpened (OpenedVault wallet) -> pure (walletAddr wallet, Nothing)
    SignerVault vault _ -> unopenedVault vault
