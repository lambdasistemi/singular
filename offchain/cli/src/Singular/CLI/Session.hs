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
    , withWrite
    , withSession
    , readsIn
    , readOnce
    , submitBuilt
    , submitBuiltIn
    , Building (..)
    , readStep
    , timedRead
    , inScopes
    , Expectation (..)
    , expecting
    , journalObserved
    , journalObservedId
    , txIdHex

      -- * The target's lock
    , withTargetLockOr

      -- * Test harness points
    , harnessHoldAt
    ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
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
import Control.Monad (void, when)
import Control.Tracer (Tracer (..), traceWith)
import Data.Aeson (Value (..), object, toJSON, (.=))
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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (cast)
import Data.Word (Word32, Word64)
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
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , feeTxBodyL
    , inputsTxBodyL
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
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , bodiesDir
    , caseName
    , durableWrite
    , readJournal
    , submissionCase
    )
import Singular.CLI.Registry (Release, loadRelease)
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
import Singular.Provider.Koios.Runtime (koiosSource)
import Singular.Registry.Application (Application)
import Singular.Registry.Capabilities (sessionReceipt)
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Terminal
    ( Capabilities (..)
    , tracedReads
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
import Singular.Registry.Wallet (Wallet (..), loadWallet)

{- | Why a command stopped, in its outcome class, with any receipt fields
that name what it left behind.
-}
data CommandFailure = CommandFailure OutcomeClass String [(Text, Value)]
    deriving stock (Show)

-- | A failure is seen through the mark that its refusal was reported ('Reported').
instance Exception CommandFailure where
    fromException (SomeException inner) = case cast inner of
        Just failure -> Just failure
        Nothing -> case cast inner of
            Just (Reported failure) -> fromException failure
            Nothing -> Nothing

{- | A failure whose refusal was already reported where it happened, in the
scopes it happened in: a build that failed, a submission refused or
unanswered. The entry point ('Singular.CLI.Finish') reports a refusal for
any other refusal outcome, so a command's stream carries exactly one. The
failure inside is unchanged, and seen through the mark as itself.
-}
newtype Reported = Reported SomeException

instance Show Reported where
    showsPrec p (Reported e) = showsPrec p e

instance Exception Reported

-- | Whether a failure's refusal was reported, and the failure itself.
reportedOf :: SomeException -> (Bool, SomeException)
reportedOf e = case fromException e of
    Just (Reported inner) -> (True, inner)
    Nothing -> (False, e)

-- | The failure, marked as reported when the original was.
markedLike :: Bool -> SomeException -> SomeException
markedLike reported e
    | reported = toException (Reported e)
    | otherwise = e

failWith :: OutcomeClass -> String -> IO a
failWith c why = throwIO (CommandFailure c why [])

-- | Stop, naming in the receipt what the command left behind.
failWithFields :: OutcomeClass -> String -> [(Text, Value)] -> IO a
failWithFields c why fields = throwIO (CommandFailure c why fields)

{- | What a command runs with, composed by the entry point: where it traces, and
how it opens the provider its caller named, for reads and for writes. The
packaged command opens Koios ('koiosEnv'); a test opens its own.
-}
data Env = Env
    { envTracer :: Tracer IO Trace
    , envSource :: Text
    -- ^ The name the provider's reads report as
    , envLoadRelease
        :: Application -> FilePath -> IO (Either String Release)
    -- ^ Recognition is fixed by the shipping composition; tests supply code fixtures.
    , envReads
        :: forall a
         . ProviderSettings
        -> (Capabilities Cage.NoWitness IO -> IO a)
        -> IO a
    , envWrites
        :: forall a
         . ProviderSettings
        -> Wallet
        -> (Capabilities Cage.NoWitness IO -> IO a)
        -> IO a
    }

-- | The environment over Koios, its mechanics and reads traced into this tracer.
koiosEnv :: Tracer IO Trace -> Env
koiosEnv tracer =
    Env
        { envTracer = tracer
        , envSource = koiosSource
        , envLoadRelease = loadRelease
        , envReads = withReads (backendUnder tracer) (readsUnder tracer)
        , envWrites = withWrites (backendUnder tracer) (readsUnder tracer)
        }

-- | Everything a write's submissions need.
data WriteContext = WriteContext
    { wcDir :: FilePath
    , wcCommand :: Text
    , wcWallet :: Wallet
    , wcCapabilities :: Capabilities Cage.NoWitness IO
    , wcTimeout :: Maybe Int
    , wcTracer :: Tracer IO Trace
    -- ^ Where the write reports its transactions, in the scope that runs it
    , wcSource :: Text
    -- ^ The name the provider's reads report as
    , wcConfirmed :: IORef (Map Text (IO Double))
    {- ^ For each transaction confirmed so far, the milliseconds since its
    confirmation: how long its readback took when it is journalled observed
    -}
    , wcPlaced :: IORef (Map Text [Scope])
    -- ^ For each transaction built so far, the scopes its build placed it in
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
    :: Env
    -> FilePath
    -> Text
    -> WriteSettings
    -> (WriteContext -> IO Value)
    -> IO Value
withWrite env dir command ws body = do
    harnessHold
    withTargetLock dir (withSession env dir command ws body)

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
        Just path -> waitAt path

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
    wallet <- loadWallet magic (writeWalletKey ws)
    connected <- newIORef False
    confirmed <- newIORef Map.empty
    placements <- newIORef Map.empty
    before <- length <$> readJournal dir
    result <-
        try $
            envWrites env settings wallet $ \caps -> do
                writeIORef connected True
                ran <-
                    tryJust failureOf $
                        body
                            WriteContext
                                { wcDir = dir
                                , wcCommand = command
                                , wcWallet = wallet
                                , wcCapabilities = caps
                                , wcTimeout = writeConfirmTimeout ws
                                , wcTracer = envTracer env
                                , wcSource = envSource env
                                , wcConfirmed = confirmed
                                , wcPlaced = placements
                                }
                named <- submissionsOf dir before
                case ran of
                    Left (reported, CommandFailure c why fields) ->
                        throwIO . markedLike reported . toException $
                            CommandFailure c why (fields <> [("submissions", named)])
                    Right (Object o) ->
                        pure (Object (KeyMap.insert "submissions" named o))
                    Right v -> pure v
    case result of
        Right a -> pure a
        Left (e :: SomeException) -> do
            preserveInfrastructure e
            was <- readIORef connected
            if was
                then do
                    since <- drop before <$> readJournal dir
                    throwIO (admitSubmissions since e)
                else
                    failWith
                        NodeUnavailable
                        ("the provider at " <> url <> " could not be used: " <> show e)
  where
    failureOf e = case reportedOf e of
        (reported, inner) -> (,) reported <$> fromException inner

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

{- | __Test harness only__ (#299, #325). When the variable names a path —
and, for a submission step, @SINGULAR_HARNESS_HOLD_STEP@ names that step —
write @PATH.waiting@ and wait until @PATH@ exists, so a control can
inspect or kill the process at exactly that boundary. The points are
@SINGULAR_HARNESS_HOLD_AFTER_SEND@ (the send made, its answer not yet
journalled), @SINGULAR_HARNESS_HOLD_AFTER_SUBMIT@ (the node's acceptance
journalled), @SINGULAR_HARNESS_HOLD_BEFORE_COMMIT@ (the fold confirmed,
before fresh public replay), and @SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED@
(the public after-state read back, before journalling its observation). Unset in ordinary use, where it does
nothing.
-}
harnessHoldAt :: String -> Maybe Text -> IO ()
harnessHoldAt var step = do
    path <- lookupEnv var
    wanted <- lookupEnv "SINGULAR_HARNESS_HOLD_STEP"
    let here = maybe True (\s -> fmap T.pack wanted == Just s) step
    case path of
        Just p | here -> waitAt p
        _ -> pure ()

{- | __Test harness only__ (#325). Whether the variable names this step:
@SINGULAR_HARNESS_DROP_SEND@ makes the send not happen,
@SINGULAR_HARNESS_DROP_ANSWER@ discards the node's answer to a send that
happened; either way the command meets no answer. Unset in ordinary use.
-}
harnessDrops :: String -> Text -> IO Bool
harnessDrops var step = (== Just (T.unpack step)) <$> lookupEnv var

waitAt :: FilePath -> IO ()
waitAt path = do
    writeFile (path <> ".waiting") ""
    let waitFor = do
            there <- doesFileExist path
            if there then pure () else threadDelay 100_000 >> waitFor
    waitFor

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
        , journalTime = Nothing
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

{- | Build one transaction from one view of the node, then sign it and
submit it journalled under that view's chain point and the expectation
the build decided. The view is released before the transaction is signed
and sent. The only way a command writes: the journalled point is the
building view's by construction. Returns the signed transaction and
whatever else the build produced.
-}
submitBuilt
    :: WriteContext
    -> Text
    -> (r -> Expectation)
    -> (Cage.Session Cage.NoWitness IO -> IO (ConwayTx, r))
    -> IO (ConwayTx, r)
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
    -> IO (ConwayTx, r)
submitBuiltIn wc step items expect build = do
    placement <- newIORef []
    readOpen <- newIORef (null items)
    since <- startTimer
    let building = Tracer $ \(Trace path event) -> do
            placed <- readIORef placement
            traceWith
                (wcTracer wc)
                (Trace (placed <> (InTransaction step : path)) event)
        closeReadWith end = do
            open <- not <$> readIORef readOpen
            when open $ do
                writeIORef readOpen True
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
                    writeIORef placement scopes
                    report (wcTracer wc) scopes event
                }
    evaluationFailed <- newIORef False
    let provider = tracedReads (wcSource wc) (readsUnder building) (wcCapabilities wc)
        -- the build's own session records whether a script failed its local evaluation
        recording v =
            v
                { Cage.sessionEvaluated = \e -> do
                    when (evalFailed e > 0) (writeIORef evaluationFailed True)
                    Cage.sessionEvaluated v e
                }
    built <-
        try $ Cage.withLatest provider $ \v -> do
            made <-
                timedTrace
                    (txUnder building)
                    (\ms end -> TxBuilt step ms (ended end))
                    (build acting (recording v))
            scope <- sessionReceipt (wcCapabilities wc) v
            pure (scope, made)
    (scope, (unsigned, extra)) <- case built of
        Right made -> pure made
        Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise -> do
                failed <- readIORef evaluationFailed
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
    placed <- readIORef placement
    modifyIORef' (wcPlaced wc) (Map.insert (txIdHex unsigned) placed)
    let tracer = within (InTransaction step) (inScopes placed (wcTracer wc))
    signed <-
        journalledSubmit tracer wc step (expect extra) scope unsigned
    pure (signed, extra)

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
await the confirmation; journal it. Returns the signed transaction once
confirmed. The command journals @observed@ after its own readback.
-}
journalledSubmit
    :: Tracer IO Trace
    -> WriteContext
    -> Text
    -> Expectation
    -> Value
    -> ConwayTx
    -> IO ConwayTx
journalledSubmit tracer wc step ex scope unsigned = do
    let txid = txIdHex unsigned
        txs = txUnder tracer
        Coin fee = unsigned ^. bodyTxL . feeTxBodyL
    (sealed, bytes) <-
        timedTrace
            txs
            (\ms end -> TxSigned step txid (Just fee) ms (ended end))
            $ do
                let sealed' = signTx (walletSignKey (wcWallet wc)) unsigned
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
            , journalKey = hexT <$> exKey ex
            , journalExpect = Just (exAfter ex)
            , journalEdge = exEdge ex
            , journalRootBefore = hexT <$> exRootBefore ex
            , journalRootAfter = hexT <$> exRootAfter ex
            }
    dropSend <- harnessDrops "SINGULAR_HARNESS_DROP_SEND" step
    tip <- tipAtSubmission (wcSource wc) tracer caps
    let (lower, upper) = validityOf signed
    sentAnswer <-
        if dropSend
            then pure (Left (toException (ErrorCall "the send was not made")))
            else
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
    harnessHoldAt "SINGULAR_HARNESS_HOLD_AFTER_SEND" (Just step)
    dropAnswer <- harnessDrops "SINGULAR_HARNESS_DROP_ANSWER" step
    let answer
            | dropAnswer =
                Left (toException (ErrorCall "the node's answer was lost"))
            | otherwise = sentAnswer
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
            harnessHoldAt "SINGULAR_HARNESS_HOLD_AFTER_SUBMIT" (Just step)
    -- The wait runs on its own thread and this thread only waits for its
    -- result, bounded by the caller's --confirm-timeout or, when none is
    -- given, by the default bound. The bound therefore holds whatever
    -- the wait does inside — including when the node is gone and the
    -- wait never returns. A wait abandoned at the bound is cancelled
    -- without this thread waiting for that cancellation to finish.
    let limit = fromMaybe defaultConfirmSeconds (wcTimeout wc) * 1_000_000
    seen <-
        timedTrace
            txs
            ( \ms end ->
                TxConfirmed step txid ms $ case end of
                    Right (Left e) -> ConfirmFailed (errorClassOf e)
                    Right (Right Nothing) -> ConfirmTimedOut
                    Right (Right (Just ())) -> Confirmed
                    Left c -> ConfirmThrew c
            )
            $ do
                waiter <- async (capConfirm caps signed)
                outcome <- timeout limit (waitCatch waiter)
                when (isNothing outcome) $ void (forkIO (cancel waiter))
                pure $ case outcome of
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
            modifyIORef' (wcConfirmed wc) (Map.insert txid since)
            pure signed

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
transaction made, and says what it read.
-}
journalObserved :: WriteContext -> Text -> ConwayTx -> Text -> IO ()
journalObserved wc step tx = journalObservedId wc step (txIdHex tx)

-- | The same, for a transaction known by its id.
journalObservedId :: WriteContext -> Text -> Text -> Text -> IO ()
journalObservedId wc step txid detail = do
    appendJournal
        (wcDir wc)
        (blankEntry wc step txid "observed"){journalDetail = Just detail}
    readback <-
        readIORef (wcConfirmed wc) >>= fromMaybe (pure 0) . Map.lookup txid
    placed <- Map.findWithDefault [] txid <$> readIORef (wcPlaced wc)
    traceWith
        (txUnder (within (InTransaction step) (inScopes placed (wcTracer wc))))
        (TxObserved step txid readback)

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
