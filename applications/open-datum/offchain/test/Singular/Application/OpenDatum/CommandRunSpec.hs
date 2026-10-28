{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.CommandRunSpec
Description : #416 — every command handler run in process, its typed events compared with its receipt
License     : Apache-2.0

Each command the command line can name is run through 'runCommand', the
same dispatch the packaged command runs, over an environment that serves a
chain fixture instead of Koios: the fixture applies every submitted
transaction to its own outputs, and the registry's scripts are accept-all
programs of the arities the builders apply, so the handlers build, sign,
submit and read back as they do on a network. The fixture is not a ledger:
nothing here claims a script or a ledger rule accepts these transactions.

Every receipt-bound fact a typed event carries must equal the receipt's: the
command and its outcome, the key, the edge and the request (in the receipt's
own fields and in every object it lists), each transaction's step and id
and what the journal says it met, the root, the token, the refusal's kind.
One contradicting event is a failure, whatever other events agree.

The public constructors are read from the command type; the three internal
preparation values are excluded. Every public writer is exercised. Folded-list
entries are bound to the actual submitted transaction's request redeemers.
The retained writers provide command and transaction events; protocol-fact
narration is outside these controls.
-}
module Singular.Application.OpenDatum.CommandRunSpec
    ( spec
    , Rig (..)
    , Run (..)
    , capabilities
    , envOf
    , fundOutput
    , magic
    , outcomeOf
    , runAt
    , runVia
    , runWithKey
    , submissionsOf
    , textAt
    , withRigOf
    ) where

import Cardano.Ledger.Api.Tx (EraTx (bodyTxL), txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( EraTxBody (inputsTxBodyL, outputsTxBodyL)
    )
import Cardano.Ledger.Api.Tx.Out (EraTxOut (mkBasicTxOut))
import Cardano.Ledger.BaseTypes (TxIx (TxIx))
import Cardano.Ledger.Mary.Value (MaryValue (MaryValue))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (bracket, throwIO)
import Control.Tracer (Tracer (..))
import Data.Aeson (KeyValue ((.=)))
import Data.Aeson qualified as Aeson
    ( Key
    , Object
    , ToJSON (toJSON)
    , Value (Array, Bool, Number, Object, String)
    , decodeStrict
    , encode
    , object
    )
import Data.Aeson.Key qualified as AesonKey ()
import Data.Aeson.KeyMap qualified as KeyMap
    ( delete
    , insert
    , lookup
    )
import Data.ByteString qualified as BS
    ( ByteString
    , readFile
    , writeFile
    )
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (lines, replicate)
import Data.ByteString.Lazy qualified as BL (writeFile)
import Data.ByteString.Short qualified as SBS
    ( ShortByteString
    , fromShort
    )
import Data.Foldable (forM_, toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (nub, partition, sort)
import Data.Map.Strict qualified as Map (delete, fromList, union)
import Data.Maybe (isJust, listToMaybe)
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set (empty, toList)
import Data.Text (Text)
import Data.Text qualified as T
    ( drop
    , isInfixOf
    , pack
    , take
    , takeWhile
    , unpack
    )
import Data.Text.Encoding qualified as TE
    ( decodeUtf8
    , encodeUtf8
    )
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import GHC.Generics
    ( C1
    , Constructor
    , D1
    , Generic (..)
    , conName
    , (:+:)
    )
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PD ()
import PlutusLedgerApi.V3 qualified as PLC ()
import Singular.Application.OpenDatum.Command
    ( OpenDatumCommand (..)
    , parseOpenDatumCommand
    )
import Singular.Application.OpenDatum.Root
    ( runPackagedOpenDatumVia
    )
import Singular.Application.OpenDatum.Run (runOpenDatum)
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.Registry (loadRelease, loadReleaseCodes)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace
    ( ConfirmVerdict
        ( ConfirmFailed
        , ConfirmThrew
        , ConfirmTimedOut
        , Confirmed
        )
    , Event (How, What)
    , Fetch (fetchSource, fetchWhat)
    , How (Fetched, Read, Tx)
    , RefusalKind (..)
    , Scope (InEdge, InTransaction)
    , SubmitVerdict
        ( Accepted
        , LedgerRefusedIt
        , ProviderFailed
        , SubmitThrew
        , WrongNetwork
        )
    , Trace (Trace)
    , TxEvent
        ( TxBuilt
        , TxConfirmed
        , TxObserved
        , TxSigned
        , TxSubmitted
        , submitStep
        , submitTxId
        , submitVerdict
        )
    , What (CommandEnded, EdgeStarted, Refused, RequestSeen)
    , fanOut
    , renderText
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (Coin))
import Singular.Registry.LedgerProvider qualified as Cage
    ( SubmitResult (SubmitAccepted)
    )
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , jumpChainTo
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
    ( ceilingSlot
    , outputsAt
    , withLatest
    )
import Singular.Registry.Signing (signedTx)
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trace (ReadEvent (Evaluated))
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.Wallet (Wallet (walletAddr), loadWallet)
import Singular.State.Fold qualified as StateFold
    ( foldedRequests
    )
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , doesFileExist
    , listDirectory
    , removeFile
    , removePathForcibly
    )
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO
    ( IOMode (..)
    , hClose
    , hFlush
    , hPrint
    , openFile
    , openTempFile
    , stderr
    , stdout
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , dup
    , dupTo
    , openFd
    , stdError
    , stdOutput
    )
import System.Posix.Types (Fd (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )
import UntypedPlutusCore qualified as UPLC ()

spec :: Spec
spec = handlerRows >> setupRecut >> permanentRecognition

permanentRecognition :: Spec
permanentRecognition = describe "Permanent contract recognition"
    $ it
        "refuses a caller supplied blueprint whose script identities are unknown"
    $ withRig
    $ \rig -> do
        loaded <- loadRelease openDatumApplication (rigBlueprint rig)
        case loaded of
            Left _ -> pure ()
            Right _ ->
                expectationFailure "unknown scripts were recognized as permanent M1"

handlerRows :: Spec
handlerRows = describe
    "every command handler, run in process, against its receipt (#416)"
    $ do
        it
            "runs every command the command line names, and each stream agrees with its receipt"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let ran = nub (sort [name | Run{runName = name} <- runs])
                ran `shouldBe` sort commandNames
                [ (runLabel r, outcomeOf (runReceipt r), found)
                  | r <- runs
                  , let found = disagreements (runKey r) (runReceipt r) (runEvents r)
                  , not (null found)
                  ]
                    `shouldBe` []
        it
            "changes no command's outcome or exit when a sink throws or writes to a \
            \closed handle, and the live sink still sees every run"
            $ do
                plain <- withRig lifecycle
                traced <-
                    withRigVia
                        ( \collect -> do
                            closed <- closedHandleSink
                            fanOut
                                [Tracer (\_ -> throwIO (userError "the sink broke")), closed, collect]
                        )
                        lifecycle
                map summary traced `shouldBe` map summary plain
                [runLabel r | r <- traced, null (runEvents r)] `shouldBe` []
        it
            "places each transaction, from its evaluation to its readback, in one \
            \scope, under the edge its command acts on"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let placements =
                        [ (runLabel r, step, nub paths, started)
                        | r <- runs
                        , let started = not (null [() | Trace _ (What (EdgeStarted _)) <- runEvents r])
                        , step <-
                            nub [s | Trace scope _ <- runEvents r, InTransaction s <- scope]
                        , let paths =
                                [ takeWhile (/= InTransaction step) scope
                                | Trace scope (How h) <- runEvents r
                                , InTransaction step `elem` scope
                                , mechanicOfItsTransaction h
                                ]
                        , not (null paths)
                        ]
                    misplaced =
                        [ (label, step, paths)
                        | (label, step, paths, started) <- placements
                        , length paths /= 1
                            || ( step `elem` edgeSteps
                                    && started
                                    && not (or [True | InEdge _ <- concat paths])
                               )
                        ]
                misplaced `shouldBe` []
        it
            "reads in timed steps, each naming what it read, and a build reads before \
            \it reports what it found"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let fetches r = [f | Trace _ (How (Fetched f)) <- runEvents r]
                    succeeded = [r | r <- runs, outcomeOf (runReceipt r) == Just "success"]
                    unread = [runLabel r | r <- succeeded, null (fetches r)]
                    unnamed =
                        [ (runLabel r, f)
                        | r <- runs
                        , f <- fetches r
                        , null (fetchWhat f) || fetchSource f /= "fixture"
                        ]
                    -- in each build that reports a protocol fact, its read comes first
                    unordered =
                        [ (runLabel r, step)
                        | r <- runs
                        , step <-
                            nub [s | Trace scope _ <- runEvents r, InTransaction s <- scope]
                        , step `elem` ["book", "fold", "update"]
                        , let inStep = dropWhile (not . startsStep step) (runEvents r)
                              beforeFact = takeWhile (not . protocolFact) (drop 1 inStep)
                        , any protocolFact inStep
                        , null [() | Trace _ (How (Fetched _)) <- beforeFact]
                        ]
                    startsStep step (Trace scope _) = InTransaction step `elem` scope
                    protocolFact = \case
                        Trace _ (What (RequestSeen{})) -> True
                        Trace _ (What (EdgeStarted _)) -> True
                        _ -> False
                length succeeded `shouldSatisfy` (> 10)
                (unread, unnamed, unordered) `shouldBe` ([], [], [])
                [ l
                  | r <- runs
                  , Just l <- map renderText (runEvents r)
                  , "how  read " `T.isInfixOf` l
                  ]
                    `shouldSatisfy` (not . null)
        it "fails a stream that contradicts its receipt in any one fact" $
            withRig $ \rig -> do
                runs <- lifecycle rig
                -- the control is only a control over a stream that agrees
                [ runLabel r
                  | r <- runs
                  , not (null (disagreements (runKey r) (runReceipt r) (runEvents r)))
                  ]
                    `shouldBe` []
                let altered =
                        [ (runLabel r, what', disagreements (runKey r) (runReceipt r) events')
                        | r <- runs
                        , (what', events') <- alterations (runReceipt r) (runEvents r)
                        ]
                    kinds = nub [w | (_, w, _) <- altered]
                length altered `shouldSatisfy` (> 50)
                -- every fact the comparison binds is planted somewhere in the lifecycle
                sort kinds `shouldBe` sort plantedFacts
                [(l, w) | (l, w, []) <- altered] `shouldBe` []
        it "agrees with a fold receipt read from its folded list alone" $
            withRig $ \rig -> do
                runs <- lifecycle rig
                let folds = foldSuccesses runs
                [runLabel r | r <- folds] `shouldSatisfy` (not . null)
                length folds `shouldBe` 2
                -- the post-removal shape: no top-level single-request fields,
                -- the settled list carrying the same facts
                [ (runLabel r, found)
                  | r <- folds
                  , let found =
                            disagreements (runKey r) (runReceipt r) (runEvents r)
                                <> foldedDisagreements (runReceipt r) (runFolded r)
                  , not (null found)
                  ]
                    `shouldBe` []
        it
            "fails a fold receipt whose folded list contradicts its submitted transaction"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let folds = foldSuccesses runs
                [runLabel r | r <- folds] `shouldSatisfy` (not . null)
                length folds `shouldBe` 2
                -- every contradiction binds somewhere in the lifecycle's folds,
                -- planted on the post-removal shape so the earlier top-level
                -- duplicates cannot mask a contradicted settled fact
                nub
                    ( sort
                        [ w
                        | r <- folds
                        , (w, _) <-
                            foldedAlterations (runReceipt r)
                        ]
                    )
                    `shouldBe` foldedContradictions
                [ (runLabel r, what')
                  | r <- folds
                  , (what', receipt') <- foldedAlterations (runReceipt r)
                  , null
                        ( disagreements (runKey r) receipt' (runEvents r)
                            <> foldedDisagreements receipt' (runFolded r)
                        )
                  ]
                    `shouldBe` []

-- ---------------------------------------------------------
-- The commands, from the type
-- ---------------------------------------------------------

class ConNames f where
    conNames :: Proxy f -> [String]

instance (ConNames f) => ConNames (D1 c f) where
    conNames _ = conNames (Proxy :: Proxy f)

instance (ConNames f, ConNames g) => ConNames (f :+: g) where
    conNames _ = conNames (Proxy :: Proxy f) <> conNames (Proxy :: Proxy g)

instance (Constructor c) => ConNames (C1 c f) where
    conNames _ = [conName (undefined :: C1 c f p)]

-- | Every command the command line can name, by constructor; help runs nothing.
commandNames :: [String]
commandNames =
    sort
        [ n
        | n <- conNames (Proxy :: Proxy (Rep OpenDatumCommand))
        , n `notElem` ["OpenHelp", "OpenInsert", "OpenUpdate", "OpenTerminate"]
        ]

-- | The constructor a parsed command is.
constructorOf :: OpenDatumCommand -> String
constructorOf = \case
    OpenHelp _ -> "OpenHelp"
    OpenInsert _ -> "OpenInsert"
    OpenUpdate _ -> "OpenUpdate"
    OpenTerminate _ -> "OpenTerminate"
    OpenStateCreate _ _ -> "OpenStateCreate"
    OpenStateFold _ -> "OpenStateFold"
    OpenHoldingUpdate{} -> "OpenHoldingUpdate"
    OpenHoldingTerminate{} -> "OpenHoldingTerminate"
    OpenRegistrationBook _ -> "OpenRegistrationBook"
    OpenRegistrationReclaim _ -> "OpenRegistrationReclaim"
    OpenRegistrationCleanup _ -> "OpenRegistrationCleanup"

-- ---------------------------------------------------------
-- Tracing setup re-cut: a trace file that cannot be written
-- ---------------------------------------------------------

{- | Two writes, the creates of two registries, through the packaged composition
over the rig's chain, untraced and then under three tracing settings. Each run is
on a fresh rig in the same directory, so its receipts and its registry's
files compare byte for byte with the untraced run's. The only field set
aside is the journal's wall-clock stamp, 'journalStamp', which must be
present and an ISO-8601 time on every line of both runs.

The file sink reports no failure of its own, so the failed appends are shown
by a pair: with a writable file and standard error at the same setting, the
file receives exactly the lines standard error does; with only the file's
path made unwritable, standard error receives as many lines again and the
file does not exist.
-}
setupRecut :: Spec
setupRecut = describe "(#416) tracing setup re-cut"
    $ it
        "keeps a write's receipt, journal, outcome and exit when its trace file \
        \cannot be written, the same run with a writable file receiving every event"
    $ withSystemTempDirectory "trace-recut"
    $ \base -> do
        let at = base </> "rig"
            writable = base </> "trace.jsonl"
            unwritable = base </> "missing" </> "trace.jsonl"
            json = ["--trace", "what", "--trace-format", "json"]
            paired file = json <> ["--trace-to", "file:" <> file, "--trace-to", "stderr"]
        plain <- packagedWrites at []
        control <- packagedWrites at (paired writable)
        faulted <- packagedWrites at (paired unwritable)
        alone <-
            packagedWrites
                at
                ["--trace", "what", "--trace-to", "file:" <> unwritable]
        -- the baseline is a write: each command submitted and journalled
        map (\(n, code, _, _) -> (n, code)) (writtenRuns plain)
            `shouldBe` [("create", ExitSuccess), ("create two", ExitSuccess)]
        let prepared =
                [ ()
                | Just "prepared" <- map (textAt "journalEvent") (writtenJournal plain)
                ]
            submitted =
                [ ()
                | (_, _, out, _) <- writtenRuns plain
                , Just (Aeson.Object r) <- [Aeson.decodeStrict out]
                , Just (Aeson.Array s) <- [KeyMap.lookup "submissions" r]
                , _ <- toList s
                ]
        length prepared `shouldSatisfy` (>= 2)
        length prepared `shouldBe` length submitted
        -- the fault is reached: the writable twin receives every event
        controlFile <- BS.readFile writable
        let lineCount = length . BC.lines
            narrated w = [lineCount err | (_, _, _, err) <- writtenRuns w]
        sum (narrated control) `shouldSatisfy` (> 0)
        all (> 0) (narrated control) `shouldBe` True
        lineCount controlFile `shouldBe` sum (narrated control)
        narrated faulted `shouldBe` narrated control
        doesFileExist unwritable `shouldReturn` False
        doesDirectoryExist (base </> "missing") `shouldReturn` False
        narrated alone `shouldBe` [0, 0]
        -- and changes nothing a write leaves
        forM_
            [ ("writable" :: String, control)
            , ("unwritable", faulted)
            , ("unwritable alone", alone)
            ]
            $ \(name, w) -> do
                (name, [(n, code, out) | (n, code, out, _) <- writtenRuns w])
                    `shouldBe` (name, [(n, code, out) | (n, code, out, _) <- writtenRuns plain])
                (name, writtenFiles w) `shouldBe` (name, writtenFiles plain)
                (name, writtenJournal w) `shouldBe` (name, writtenJournal plain)
                (name, writtenStamps w)
                    `shouldBe` (name, map (const True) (writtenStamps plain))
        writtenStamps plain `shouldBe` map (const True) (writtenStamps plain)

{- | The reference read-back of a create (#437): a provider that cannot
answer it is a provider failure, attributed by the typed failure the
client holds — never a completed read step claiming the output absent —
while a read that established the output missing stays the distinct
not-live refusal it always was.
-}
data Written = Written
    { writtenRuns :: [(String, ExitCode, BS.ByteString, BS.ByteString)]
    -- ^ Each command: its name, exit, standard output and standard error
    , writtenFiles :: [(FilePath, BS.ByteString)]
    -- ^ Every file of the registry but its journal
    , writtenJournal :: [Aeson.Value]
    -- ^ Every journal line, its wall-clock stamp removed
    , writtenStamps :: [Bool]
    -- ^ Per journal line: its stamp is present and an ISO-8601 time
    }

-- | The journal's wall-clock field, the one field the comparison sets aside.
journalStamp :: Aeson.Key
journalStamp = "journalTime"

-- | Two creates, of two registries, through the packaged composition, on a fresh rig here.
packagedWrites :: FilePath -> [String] -> IO Written
packagedWrites at flags = do
    removePathForcibly at
    createDirectory at
    withRigIn at syntheticBlueprint pure $ \rig -> do
        first <- fundSeed rig
        one <-
            packaged
                rig
                "registry"
                "create"
                ["state", "create", "--seed", first]
        second <- fundSeed2 rig
        two <-
            packaged
                rig
                "registry-2"
                "create two"
                ["state", "create", "--seed", second]
        registries <-
            mapM (registryFiles . (rigDir rig </>)) ["registry", "registry-2"]
        let files = concatMap fst registries
            journal = concatMap snd registries
        pure
            Written
                { writtenRuns = [one, two]
                , writtenFiles = files
                , writtenJournal = map unstamped journal
                , writtenStamps = map stamped journal
                }
  where
    packaged rig registry name args = do
        let errPath = rigDir rig </> (registry <> ".stderr")
        h <- openFile errPath WriteMode
        (code, out, _) <-
            captured
                ( runPackagedOpenDatumVia
                    (\tracer -> (envOf rig){envTracer = tracer})
                    openDatumApplication
                    (pure (Just h))
                    (commandLine rig registry args <> flags)
                    []
                )
        hClose h
        err <- BS.readFile errPath
        pure (name, code, out, err)
    registryFiles registry = do
        names <- sort <$> listDirectoryRecursive registry
        -- The journal lives under the managed identity partition, never
        -- directly at the configured root: locate it instead of assuming it.
        let (journals, others) = partition ((== "journal.jsonl") . takeFileName) names
        journalRel <- case journals of
            [found] -> pure found
            _ ->
                fail
                    ( "expected exactly one managed journal under "
                        <> registry
                        <> ", found "
                        <> show (length journals)
                    )
        files <-
            mapM
                (\p -> (,) (registry </> p) <$> BS.readFile (registry </> p))
                others
        journal <-
            mapM
                (maybe (fail "a journal line is not JSON") pure . Aeson.decodeStrict)
                . BC.lines
                =<< BS.readFile (registry </> journalRel)
        pure (files, journal)
    unstamped = \case
        Aeson.Object o -> Aeson.Object (KeyMap.delete journalStamp o)
        other -> other
    stamped = \case
        Aeson.Object o
            | Just (Aeson.String t) <- KeyMap.lookup journalStamp o ->
                isJust (iso8601ParseM (T.unpack t) :: Maybe UTCTime)
        _ -> False

-- | Every file below a directory, as paths relative to it.
listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
    entries <- listDirectory dir
    concat
        <$> mapM
            ( \e -> do
                isDir <- doesDirectoryExist (dir </> e)
                if isDir
                    then map (e </>) <$> listDirectoryRecursive (dir </> e)
                    else pure [e]
            )
            entries

-- ---------------------------------------------------------
-- The rig
-- ---------------------------------------------------------

data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigWallet :: Wallet
    , rigKey :: FilePath
    , rigBlueprint :: FilePath
    , rigEvents :: IORef [Trace]
    , rigAnswer :: IORef (Maybe Cage.SubmitResult)
    -- ^ When set, what the provider answers the next submission instead of taking it
    , rigSubmitted :: IORef [ConwayTx]
    -- ^ Every transaction the provider took, as it was submitted, in order
    , rigTracer :: Tracer IO Trace
    -- ^ What the commands trace into: the collector, or a composition holding it
    }

-- | One command run: its constructor, a label, its exit, its receipt and its events.
data Run = Run
    { runName :: String
    , runLabel :: String
    , runExit :: ExitCode
    , runReceipt :: Aeson.Value
    , runEvents :: [Trace]
    , runFolded :: [(Text, Maybe Text)]
    , runKey :: Maybe Text
    -- ^ The key the command line names, base16
    }

-- | The @--request@ of a run's receipt, for the fold that follows it.
magic :: Integer
magic = 42

withRig :: (Rig -> IO a) -> IO a
withRig = withRigVia pure

-- | The rig, its commands tracing into a composition built around its collector.
withRigVia
    :: (Tracer IO Trace -> IO (Tracer IO Trace)) -> (Rig -> IO a) -> IO a
withRigVia = withRigOf syntheticBlueprint

-- | The rig over this blueprint.
withRigOf
    :: Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigOf blueprintJson compose use =
    withSystemTempDirectory "command-run" $ \dir ->
        withRigIn dir blueprintJson compose use

-- | The rig over this blueprint, in this directory.
withRigIn
    :: FilePath
    -> Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigIn dir blueprintJson compose use = do
    let keyPath = dir </> "payment.skey"
        blueprint = dir </> "plutus.json"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    BL.writeFile blueprint (Aeson.encode blueprintJson)
    BL.writeFile
        (dir </> "payload.json")
        (Aeson.encode (7 :: Int))
    BL.writeFile
        (dir </> "payload-2.json")
        (Aeson.encode (8 :: Int))
    wallet <- loadWallet (fromIntegral magic) keyPath
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = fromIntegral magic
                , csTip = Nothing
                , csPParams = withSyntheticCosts preprodParams
                , csUTxO =
                    Map.fromList
                        [ ( fundOutput n
                          , mkBasicTxOut
                                (walletAddr wallet)
                                (MaryValue (Coin 2_000_000_000) mempty)
                          )
                        | n <- [1 .. 6]
                        ]
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    advanceChain chain id
    events <- newIORef []
    answer <- newIORef Nothing
    submitted <- newIORef []
    tracer <- compose (Tracer (\t -> modifyIORef' events (<> [t])))
    use
        (Rig dir chain wallet keyPath blueprint events answer submitted tracer)

-- | A wallet output at the start of the chain.
fundOutput :: Int -> TxIn
fundOutput n =
    either
        (error . ("fundOutput: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'f' <> "#" <> show n)))

{- | The registry's validators as accept-all programs, each taking the
parameters the builders apply and then the script context.
-}
syntheticBlueprint :: Aeson.Value
syntheticBlueprint = blueprintOf (const unitProgram)

{- | The same validators, the open datum's failing whatever it is given: an
insertion's booking, which mints under it, fails its local evaluation.
-}
blueprintOf :: (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintOf = blueprintWith []

{- | The same, carrying these further validators (title and arity), each
program made as the others are.
-}
blueprintWith
    :: [(Text, Int)] -> (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintWith further program =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= ( [ validator "state.state" 1
                 , validator "request.request" 3
                 , validator "open_datum.open_datum" 2
                 , validator "witness.witness" 3
                 , validator "witness.witness" 3
                 , validator "singular_state.singular_state.spend" 2
                 , validator "open_datum_requests.open_datum_requests.spend" 1
                 ]
                    <> [validator title arity | (title, arity) <- further]
               )
        , "definitions" .= Aeson.object []
        ]
  where
    validator :: Text -> Int -> Aeson.Value
    validator title arity =
        let code = program title arity
        in  Aeson.object
                [ "title" .= title
                , "redeemer" .= Aeson.object ["schema" .= Aeson.object []]
                , "hash"
                    .= TE.decodeUtf8 (B16.encode (scriptHashBytes (computeScriptHash code)))
                , "compiledCode" .= TE.decodeUtf8 (B16.encode (SBS.fromShort code))
                ]

-- | The environment of a run over the rig: the fixture's capabilities.
envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = rigTracer rig
        , envSource = "fixture"
        , envLoadRelease = loadReleaseCodes
        , envReads = \_ k -> k (capabilities rig)
        , envWrites = \_ k -> k (capabilities rig)
        }

-- | Reads of the chain fixture, and a submission it applies to its outputs.
capabilities :: Rig -> Capabilities NoWitness IO
capabilities rig =
    Capabilities
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
            in  (network, observeProvider unverifiedVerifier (\_ -> pure ()) provider)
        , capSubmit = \signed ->
            readIORef (rigAnswer rig) >>= \case
                Just answer -> writeIORef (rigAnswer rig) Nothing >> pure answer
                Nothing -> do
                    let tx = signedTx signed
                        txid = txIdTx tx
                        spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
                        made = zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
                    recordTransaction (rigChain rig) tx
                    modifyIORef' (rigSubmitted rig) (<> [tx])
                    advanceChain (rigChain rig) $ \facts ->
                        facts
                            { csUTxO =
                                Map.union
                                    (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                                    (foldr Map.delete (csUTxO facts) spent)
                            }
                    pure (Cage.SubmitAccepted txid)
        , capConfirm = \_ -> pure ()
        , capFacts = pure []
        , capTrace = pure []
        }

{- | The rig's capabilities with every exact-input read answered by this —
a refused read as a typed failure, or a successful empty answer — every
other read served by the chain as it stands: a provider that cannot
make one read, or one that answers nothing there, not one that is down.
-}
tokenOf :: Run -> IO String
tokenOf r = case textAt "stateToken" (runReceipt r) of
    Just t -> pure (T.unpack t)
    Nothing ->
        fail
            ("no state token in " <> runLabel r <> ": " <> show (runReceipt r))

-- | A command line naming the registry by its state token.
lifecycle :: Rig -> IO [Run]
lifecycle rig = do
    runs <- registrationLifecycle rig
    extra <- runAt rig "second" "second state create" ["state", "create"]
    pure (runs <> [extra])

registrationLifecycle :: Rig -> IO [Run]
registrationLifecycle rig = do
    created <- runAt rig "proved" "state create" ["state", "create"]
    token <- tokenOf created
    booked <- runAt rig "proved" "registration book" (book token "fold")
    folded <-
        runAt
            rig
            "proved"
            "state fold"
            (["state", "fold", "--state-token", token] <> pendingOf booked)
    foldedTx <- last <$> readIORef (rigSubmitted rig)
    let holding = renderOutRef (TxIn (txIdTx foldedTx) (TxIx 1))
    updated <-
        runAt
            rig
            "proved"
            "holding update"
            [ "holding"
            , "update"
            , "--state-token"
            , token
            , "--holding"
            , T.unpack holding
            , "--payload"
            , rigDir rig </> "payload.json"
            ]
    nextHolding <-
        maybe
            (fail "the update prints no holding")
            pure
            (textAt "holding" (runReceipt updated))
    terminated <-
        runAt
            rig
            "proved"
            "holding terminate"
            [ "holding"
            , "terminate"
            , "--state-token"
            , token
            , "--holding"
            , T.unpack nextHolding
            ]
    terminationFold <-
        runAt
            rig
            "proved"
            "termination fold"
            (["state", "fold", "--state-token", token] <> pendingOf terminated)
    toReclaim <-
        runAt
            rig
            "proved"
            "registration book to reclaim"
            (book token "reclaim")
    reachMs (milliseconds "processDeadline" toReclaim)
    reclaimed <-
        runAt
            rig
            "proved"
            "registration reclaim"
            ( ["registration", "reclaim", "--state-token", token]
                <> pendingOf toReclaim
            )
    toClean <-
        runAt
            rig
            "proved"
            "registration book to clean up"
            (book token "cleanup")
    reachMs (milliseconds "reclaimEnd" toClean)
    cleaned <-
        runAt
            rig
            "proved"
            "registration cleanup"
            ( ["registration", "cleanup", "--state-token", token]
                <> pendingOf toClean
            )
    missing <-
        runAt
            rig
            "proved"
            "update a missing holding"
            [ "holding"
            , "update"
            , "--state-token"
            , token
            , "--holding"
            , replicate 64 'e' <> "#0"
            , "--payload"
            , rigDir rig </> "payload.json"
            ]
    pure
        [ created
        , booked
        , folded
        , updated
        , terminated
        , terminationFold
        , toReclaim
        , reclaimed
        , toClean
        , cleaned
        , missing
        ]
  where
    book token key =
        [ "registration"
        , "book"
        , "--state-token"
        , token
        , "--key"
        , key
        , "--payload"
        , rigDir rig </> "payload.json"
        ]
    pendingOf r =
        maybe
            []
            (\p -> ["--pending", T.unpack p])
            (textAt "pending" (runReceipt r))
    milliseconds field r = case valueAt field (runReceipt r) of
        Just (Aeson.Number n) -> truncate n :: Integer
        _ -> 0
    reachMs ms = do
        slot <-
            SessionIO.withLatest
                (rawChainProvider (rigChain rig))
                (`SessionIO.ceilingSlot` ms)
        jumpChainTo (rigChain rig) (SlotNo (unSlotNo slot + 1))

-- | A wallet output the create can consume as its seed.
fundSeed :: Rig -> IO String
fundSeed _ = pure (T.unpack (renderOutRef (fundOutput 1)))

-- | A wallet output still unspent, for the second registry.
runAt :: Rig -> FilePath -> String -> [String] -> IO Run
runAt rig = runVia rig (envOf rig)

{- | The same, over an environment of the caller's: the packaged one, or
one whose provider cannot answer a read.
-}
runVia :: Rig -> Env -> FilePath -> String -> [String] -> IO Run
runVia rig env registry label args = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseOpenDatumCommand (commandLine rig registry args))
    (code, out, _) <-
        captured (runOpenDatum env command)
    receipt <-
        maybe
            (fail ("no receipt for " <> label <> ": " <> show out))
            pure
            (Aeson.decodeStrict out)
    events <- readIORef (rigEvents rig)
    submitted <- readIORef (rigSubmitted rig)
    let folded = case (command, reverse submitted) of
            (OpenStateFold _, tx : _)
                | code == ExitSuccess ->
                    [ (renderOutRef pending, Just (hexText key))
                    | (pending, key) <- StateFold.foldedRequests tx
                    ]
            _ -> []
    pure
        Run
            { runName = constructorOf command
            , runLabel = label
            , runExit = code
            , runReceipt = receipt
            , runEvents = events
            , runFolded = folded
            , runKey =
                listToMaybe
                    [ hexText (TE.encodeUtf8 (T.pack k))
                    | ("--key", k) <- zip args (drop 1 args)
                    ]
            }

{- | A command line through the same dispatch and receipt plumbing, over
a provider that answers every exact-input read with this: a refused
read as a typed failure, or a successful empty answer — the read-back
a create must make of a reference it just published.
-}
commandLine :: Rig -> FilePath -> [String] -> [String]
commandLine rig registry args =
    args
        <> [ "--state-dir"
           , rigDir rig </> registry
           , "--blueprint"
           , rigBlueprint rig
           , "--koios-url"
           , "http://fixture.invalid"
           , "--network-magic"
           , show magic
           ]
        <> ["--wallet-skey" | wantsKey]
        <> [rigKey rig | wantsKey]
  where
    -- A preview holds no signing key: it names the caller by address.
    -- A line that already names one keeps it: the key-ordering control
    -- supplies an absent key file through the same dispatch.
    wantsKey =
        "--preview" `notElem` args
            && "--bundle" `notElem` args
            && "--vault" `notElem` args
            && "--wallet-skey" `notElem` args

-- | One command line with this signing-key path instead of the rig's.
runWithKey :: FilePath -> Rig -> String -> [String] -> IO Run
runWithKey keyPath rig label args =
    runAt rig "registry" label (args <> ["--wallet-skey", keyPath])

-- ---------------------------------------------------------
-- The comparison
-- ---------------------------------------------------------

-- | The receipt's outcome.
outcomeOf :: Aeson.Value -> Maybe Text
outcomeOf = textAt "outcome"

textAt :: Aeson.Key -> Aeson.Value -> Maybe Text
textAt k = \case
    Aeson.Object o | Just (Aeson.String t) <- KeyMap.lookup k o -> Just t
    _ -> Nothing

-- | Every object in a value, itself included.
fieldOf :: Aeson.Key -> Aeson.Object -> Maybe Text
fieldOf k o = case KeyMap.lookup k o of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

valueAt :: Aeson.Key -> Aeson.Value -> Maybe Aeson.Value
valueAt k = \case
    Aeson.Object o -> KeyMap.lookup k o
    _ -> Nothing

-- | The elements of an array field.
elementsAt :: Aeson.Key -> Aeson.Value -> Maybe [Aeson.Value]
elementsAt k v = case valueAt k v of
    Just (Aeson.Array xs) -> Just (toList xs)
    _ -> Nothing

{- | The runs whose receipt is a successful fold's: the receipt whose earlier
top-level single-request fields the next slice removes.
-}
foldSuccesses :: [Run] -> [Run]
foldSuccesses =
    filter
        ( \r ->
            textAt "command" (runReceipt r) == Just "state fold"
                && outcomeOf (runReceipt r) == Just "success"
        )

{- | A fold run's receipt without its earlier top-level single-request
fields: the post-removal shape, the settled list carrying the same facts.
-}
withoutFields :: [Aeson.Key] -> Aeson.Value -> Aeson.Value
withoutFields names = \case
    Aeson.Object o -> Aeson.Object (foldl (flip KeyMap.delete) o names)
    v -> v

{- | Every way a fold receipt's settled list can stop agreeing with its
events: removed, emptied, or contradicted in each fact the comparison
binds. An alteration whose path the receipt does not carry is absent, so
each delivery branch keeps the settlement field it prints.
-}
foldedAlterations :: Aeson.Value -> [(String, Aeson.Value)]
foldedAlterations receipt =
    [ ("folded removed", withoutFields ["folded"] receipt)
    , ("folded emptied", replaceFolded [] receipt)
    ]
        <> [ (label, replaceFolded (Aeson.Object edited : rest) receipt)
           | Just (Aeson.Object first : rest) <- [elementsAt "folded" receipt]
           , (label, field) <-
                [("folded pending", "pending"), ("folded key", "key")]
           , Just edited <- [withText field flipLeading first]
           ]

foldedContradictions :: [String]
foldedContradictions =
    sort
        ["folded removed", "folded emptied", "folded pending", "folded key"]

replaceFolded :: [Aeson.Value] -> Aeson.Value -> Aeson.Value
replaceFolded values = \case
    Aeson.Object o -> Aeson.Object (KeyMap.insert "folded" (Aeson.toJSON values) o)
    value -> value

foldedDisagreements :: Aeson.Value -> [(Text, Maybe Text)] -> [String]
foldedDisagreements receipt actual =
    [ "folded requests differ from the submitted transaction"
    | fmap
        (map (\entry -> (textAt "pending" entry, textAt "key" entry)))
        (elementsAt "folded" receipt)
        /= Just [(Just pending, key) | (pending, key) <- actual]
    ]

-- | The receipt with its settled list replaced by these entries.
withText
    :: Aeson.Key -> (Text -> Text) -> Aeson.Object -> Maybe Aeson.Object
withText name f o = case KeyMap.lookup name o of
    Just (Aeson.String t) -> Just (KeyMap.insert name (Aeson.String (f t)) o)
    _ -> Nothing

-- | Replace an integer field of an object; Nothing when it holds no number.
flipLeading :: Text -> Text
flipLeading t =
    if T.take 1 t == "0" then "1" <> T.drop 1 t else "0" <> T.drop 1 t

-- | The receipt's submissions: step, transaction id, case and whether observed.
submissionsOf :: Aeson.Value -> [(Text, Text, Maybe Text, Bool)]
submissionsOf = \case
    Aeson.Object o
        | Just (Aeson.Array xs) <- KeyMap.lookup "submissions" o ->
            [ (s, t, c, observed)
            | Aeson.Object x <- toList xs
            , let c = case KeyMap.lookup "case" x of
                    Just (Aeson.String v) -> Just v
                    _ -> Nothing
                  observed = KeyMap.lookup "observed" x == Just (Aeson.Bool True)
            , Just (Aeson.String s) <- [KeyMap.lookup "step" x]
            , Just (Aeson.String t) <- [KeyMap.lookup "tx" x]
            ]
    _ -> []

{- | The edge actions a command performs, by its receipt's command: create
boots, insert and terminate book the edge their plan books (and fold it when
asked), update updates, reject rejects, fold and reclaim act on the edge
their receipt names. OpenInspect performs none.
-}
refusalFits :: RefusalKind -> Maybe Text -> Bool
refusalFits k o = case k of
    LedgerRejected -> o == Just "ledger-refusal"
    TransportFailed -> o `elem` map Just ["partial", "node-unavailable", "timeout"]
    ClientRefused ->
        o
            `elem` map
                Just
                ["client-refusal", "partial", "concurrent-writer", "stale-state"]
    EvaluationRefused -> o `elem` map Just ["client-refusal", "partial"]

{- | Every way the typed events contradict the receipt; empty when every event
that carries a receipt-bound fact agrees with it. The key is the receipt's,
or the one the command line named when the receipt names none (a refusal's
receipt carries no key).
-}
disagreements :: Maybe Text -> Aeson.Value -> [Trace] -> [String]
disagreements _invokedKey receipt events =
    concat
        [ ends
        , [ "transaction "
                <> show (s, t)
                <> " not among the receipt's submissions"
          | (s, t, observedOnly) <- eventTxs
          , (s, t) `notElem` [(s', t') | (s', t', _, _) <- subs]
          , not (observedOnly && (s, t) `elem` reused)
          ]
        , [ "reference " <> show (s, t) <> " read back " <> show n <> " times"
          | (s, t) <- reused
          , let n =
                    length
                        [ ()
                        | Trace _ (How (Tx (TxObserved s' t' _))) <- events
                        , (s', t') == (s, t)
                        ]
          , n /= 1
          ]
        , [ "submission " <> show (s, t) <> " has no signing and submission event"
          | (s, t, _, _) <- subs
          , not (any (signed s t) events) || not (any (submitted s t) events)
          ]
        , [ "submission "
                <> show t
                <> " observed "
                <> show o
                <> " against its events"
          | (s, t, _, o) <- subs
          , o /= any (observedEvent s t) events
          ]
        , [ "submission "
                <> show t
                <> " met "
                <> show c
                <> " but its events say "
                <> show v
          | (_, t, c, _) <- subs
          , v <- verdictsOf t
          , not (consistent v c)
          ]
        , [ "refusal " <> show k <> " under outcome " <> show outcome
          | Trace _ (What (Refused k _)) <- events
          , not (refusalFits k outcome)
          ]
        , [ "refusal events " <> show n <> " under outcome " <> show outcome
          | let n = length [() | Trace _ (What (Refused _ _)) <- events]
          , if refusalOutcome outcome then n /= 1 else n > 1
          ]
        , [ "ledger refusal with no ledger rejection event"
          | outcome == Just "ledger-refusal"
          , null [() | Trace _ (What (Refused LedgerRejected _)) <- events]
          ]
        ]
  where
    outcome = textAt "outcome" receipt
    command = textAt "command" receipt
    subs = submissionsOf receipt
    -- a reference the command found already published: read back, not submitted
    reused =
        [ ("publish-" <> role, T.takeWhile (/= '#') out)
        | Just rs <- [elementsAt "references" receipt]
        , Aeson.Object o <- rs
        , Just role <- [fieldOf "role" o]
        , Just out <- [fieldOf "output" o]
        , T.takeWhile (/= '#') out `notElem` [t | (_, t, _, _) <- subs]
        ]
    ends = case [(c, o) | Trace [] (What (CommandEnded c o _)) <- events] of
        [(c, o)]
            | Just c == command
            , Just o == outcome
            , isEnd (lastMaybe events) ->
                []
        found ->
            [ "the stream's end "
                <> show found
                <> " against the receipt's command and outcome"
            ]
    isEnd = \case
        Just (Trace [] (What (CommandEnded{}))) -> True
        _ -> False
    lastMaybe xs = if null xs then Nothing else Just (last xs)
    eventTxs =
        [ (s, t, observedOnly)
        | Trace _ (How (Tx e)) <- events
        , let observedOnly = case e of
                TxObserved{} -> True
                _ -> False
        , Just (s, t) <- [txOf e]
        ]
    txOf = \case
        TxBuilt{} -> Nothing
        TxSigned s t _ _ _ -> Just (s, t)
        TxSubmitted{submitStep = s, submitTxId = t} -> Just (s, t)
        TxConfirmed s t _ _ -> Just (s, t)
        TxObserved s t _ -> Just (s, t)
    signed s t = \case
        Trace _ (How (Tx (TxSigned s' t' _ _ _))) -> (s', t') == (s, t)
        _ -> False
    submitted s t = \case
        Trace _ (How (Tx TxSubmitted{submitStep = s', submitTxId = t'})) -> (s', t') == (s, t)
        _ -> False
    observedEvent s t = \case
        Trace _ (How (Tx (TxObserved s' t' _))) -> (s', t') == (s, t)
        _ -> False
    verdictsOf t =
        [ Left v
        | Trace _ (How (Tx TxSubmitted{submitTxId = t', submitVerdict = v})) <-
            events
        , t' == t
        ]
            <> [ Right v | Trace _ (How (Tx (TxConfirmed _ t' _ v))) <- events, t' == t
               ]
    consistent v c = case (v, c) of
        (Left Accepted, Just x) ->
            x
                `elem` ["acknowledged", "timeout", "included", "rolled-back", "excluded"]
        (Left LedgerRefusedIt, Just x) -> x == "rejected"
        (Left WrongNetwork, Just x) -> x == "rejected"
        (Left ProviderFailed, Just x) -> x == "unknown"
        (Left (SubmitThrew _), Just x) -> x == "unknown"
        (Right Confirmed, Just x) -> x `elem` ["included", "rolled-back", "excluded"]
        (Right ConfirmTimedOut, Just x) -> x == "timeout"
        (Right (ConfirmFailed _), Just x) -> x == "timeout"
        (Right (ConfirmThrew _), Just x) -> x == "timeout"
        (_, Nothing) -> False

hexText :: BS.ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

{- | One contradiction planted per fact a stream carries, wherever the
receipt binds that fact: each altered stream must disagree with the
unaltered receipt. Every event is altered in each fact it carries, its
scopes included; an observation is also removed. A refusal is altered only to
kinds its outcome cannot stand under.
-}
alterations :: Aeson.Value -> [Trace] -> [(String, [Trace])]
alterations receipt events =
    [ ( label
      , [if i == n then e' else x | (i, x) <- zip [0 :: Int ..] events]
      )
    | (n, e) <- zip [0 ..] events
    , (label, e') <- alter e
    ]
        <> [ ( "observation removed"
             , [x | (i, x) <- zip [0 :: Int ..] events, i /= n]
             )
           | (n, Trace _ (How (Tx TxObserved{}))) <- zip [0 ..] events
           ]
        <> [ ( "refusal removed"
             , [x | (i, x) <- zip [0 :: Int ..] events, i /= n]
             )
           | refusalOutcome outcome
           , (n, Trace _ (What (Refused{}))) <- zip [0 ..] events
           ]
        <> [ ( "refusal repeated"
             , concat
                [if i == n then [x, x] else [x] | (i, x) <- zip [0 :: Int ..] events]
             )
           | (n, Trace _ (What (Refused{}))) <- zip [0 ..] events
           ]
  where
    outcome = textAt "outcome" receipt
    flipText t = if T.take 1 t == "0" then "1" <> T.drop 1 t else "0" <> T.drop 1 t
    alter (Trace scope event) = case event of
        What (CommandEnded c o ms) ->
            [ ("outcome", Trace scope (What (CommandEnded c (o <> "-altered") ms)))
            , ("command", Trace scope (What (CommandEnded (c <> "-altered") o ms)))
            ]
        What (Refused _ c) ->
            [ ("refusal kind", Trace scope (What (Refused k' c)))
            | k' <- [minBound .. maxBound]
            , not (refusalFits k' outcome)
            ]
        How (Tx (TxSigned s t f ms end)) ->
            [
                ( "signed id"
                , Trace scope (How (Tx (TxSigned s (flipText t) f ms end)))
                )
            ]
        How (Tx x@TxSubmitted{}) ->
            [ ("submitted verdict", Trace scope (How (Tx x{submitVerdict = v})))
            | v <- [Accepted, LedgerRefusedIt, ProviderFailed]
            , v /= submitVerdict x
            ]
        How (Tx (TxConfirmed s t ms v)) ->
            [ ("confirmed verdict", Trace scope (How (Tx (TxConfirmed s t ms v'))))
            | v' <- [Confirmed, ConfirmTimedOut]
            , v' /= v
            ]
        How (Tx (TxObserved s t ms)) ->
            [ ("observed step", Trace scope (How (Tx (TxObserved (s <> "x") t ms))))
            ]
        _ -> []

-- Standard streams
-- ---------------------------------------------------------

captured :: IO a -> IO (a, BS.ByteString, BS.ByteString)
captured act = withSystemTempDirectory "command-run-captured" $ \dir -> do
    let outPath = dir </> "stdout"
        errPath = dir </> "stderr"
    a <- redirecting stdOutput outPath (redirecting stdError errPath act)
    (,,) a <$> BS.readFile outPath <*> BS.readFile errPath

redirecting :: Fd -> FilePath -> IO a -> IO a
redirecting target path act =
    bracket
        ( do
            hFlush stdout >> hFlush stderr
            saved <- dup target
            f <-
                openFd
                    path
                    WriteOnly
                    defaultFileFlags{creat = Just 0o644, trunc = True}
            _ <- dupTo f target
            closeFd f
            pure saved
        )
        ( \saved -> do
            hFlush stdout >> hFlush stderr
            _ <- dupTo saved target
            closeFd saved
        )
        (const act)

-- | What a run ended with: its label, outcome class and exit status.
summary :: Run -> (String, Maybe Text, ExitCode)
summary r = (runLabel r, outcomeOf (runReceipt r), runExit r)

-- | A sink writing to a handle that is already closed.
closedHandleSink :: IO (Tracer IO Trace)
closedHandleSink = do
    (path, h) <- openTempFile "/tmp" "closed-sink"
    hClose h
    removeFile path
    pure (Tracer (hPrint h))

-- | Every fact 'alterations' plants a contradiction in.
plantedFacts :: [String]
plantedFacts =
    [ "outcome"
    , "command"
    , "refusal kind"
    , "signed id"
    , "submitted verdict"
    , "confirmed verdict"
    , "observed step"
    , "observation removed"
    , "refusal removed"
    , "refusal repeated"
    ]

-- | The journal steps that act on an edge: boot, book, fold, update.
edgeSteps :: [Text]
edgeSteps = ["boot", "book", "fold", "update"]

{- | A mechanic that belongs to its transaction once its build has decided
where it is placed: an evaluation, the build, the signing, submission,
confirmation and readback. Reads before the decision are not.
-}
mechanicOfItsTransaction :: How -> Bool
mechanicOfItsTransaction = \case
    Read (Evaluated _) -> True
    Tx _ -> True
    _ -> False

-- | Whether a receipt's outcome is a refusal: its stream carries exactly one refusal event.
refusalOutcome :: Maybe Text -> Bool
refusalOutcome = (`elem` map Just ["client-refusal", "ledger-refusal"])

-- | An unspent wallet output for another registry.
fundSeed2 :: Rig -> IO String
fundSeed2 rig = do
    held <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \s ->
            SessionIO.outputsAt s (walletAddr (rigWallet rig))
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for a second registry"
