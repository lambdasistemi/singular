{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.CommandRunSpec
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

The commands run are the 'Command' constructors, read from the type, not
listed here; a constructor no run exercises fails the extent row.
-}
module Singular.CLI.CommandRunSpec (spec) where

import Control.Applicative ((<|>))
import Control.Exception (bracket, throwIO)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (forM_, toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , doesFileExist
    , listDirectory
    , removeFile
    , removePathForcibly
    )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
    ( IOMode (..)
    , hClose
    , hFlush
    , hPutStrLn
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
import System.Posix.Types (Fd)
import Test.Hspec

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Word (Word64)

import Singular.CLI (runCommand)
import Singular.CLI.Command (Command (..), parseCommand)
import Singular.CLI.Root (runPackagedVia)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.LedgerProvider qualified as Cage
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
import Singular.Registry.Signing (signedTx)
import Singular.Registry.SyntheticLedger
    ( errorProgram
    , unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trace
    ( Evaluation (..)
    , ReadEvent (Evaluated)
    )
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.Types
    ( edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = handlerRows >> setupRecut

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
                -- the extent: every step that acts on an edge was placed somewhere
                nub (sort [s | (_, s, _, True) <- placements, s `elem` edgeSteps])
                    `shouldBe` sort edgeSteps
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
                        , step `elem` ["book", "fold", "update", "reject", "reclaim"]
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
        it
            "closes a build read that fails before it decides, ahead of its refusal"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                case [r | r <- runs, runLabel r == "update an absent key"] of
                    [absent] -> do
                        let events = runEvents absent
                            fetches = [f | Trace _ (How (Fetched f)) <- events]
                            buildReads =
                                [ f
                                | f <- fetches
                                , fetchWhat f == ["state", "key outputs"]
                                ]
                            refusals = [k | Trace _ (What (Refused k _)) <- events]
                            posFetch = length (takeWhile (not . isBuildFetch) events)
                            isBuildFetch = \case
                                Trace _ (How (Fetched f)) ->
                                    fetchWhat f == ["state", "key outputs"]
                                _ -> False
                            posRefused = length (takeWhile (not . isRefused) events)
                            isRefused = \case
                                Trace _ (What (Refused{})) -> True
                                _ -> False
                        outcomeOf (runReceipt absent) `shouldBe` Just "client-refusal"
                        refusals `shouldBe` [ClientRefused]
                        length buildReads `shouldBe` 1
                        case buildReads of
                            [f] -> do
                                fetchSource f `shouldBe` "fixture"
                                fetchElapsed f `shouldSatisfy` (>= 0)
                                case fetchEnd f of
                                    FailedWith _ -> pure ()
                                    Done -> expectationFailure "a failed build read ends Done"
                            _ -> expectationFailure "one build read"
                        (posFetch < posRefused) `shouldBe` True
                        disagreements (runKey absent) (runReceipt absent) events `shouldBe` []
                    _ -> expectationFailure "one absent update run"
        it
            "reports a script that fails its local evaluation as refused there, from \
            \the build's own session"
            $ withRigOf failingOpenDatum pure
            $ \rig -> do
                seed <- fundSeed rig
                _ <- run rig "create" ["registry", "create", "--seed", seed]
                refused <-
                    run
                        rig
                        "insert alice-1"
                        [ "registry"
                        , "insert"
                        , "--key"
                        , "alice-1"
                        , "--payload"
                        , rigDir rig </> "payload.json"
                        ]
                let events = runEvents refused
                ( outcomeOf (runReceipt refused)
                    , [k | Trace _ (What (Refused k _)) <- events]
                    , or [evalFailed e > 0 | Trace _ (How (Read (Evaluated e))) <- events]
                    , disagreements (runKey refused) (runReceipt refused) events
                    )
                    `shouldBe` (Just "client-refusal", [EvaluationRefused], True, [])
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
    sort [n | n <- conNames (Proxy :: Proxy (Rep Command)), n /= "Help"]

-- | The constructor a parsed command is.
constructorOf :: Command -> String
constructorOf = \case
    Help -> "Help"
    Create _ -> "Create"
    Insert _ -> "Insert"
    Update _ -> "Update"
    Terminate _ -> "Terminate"
    Fold _ -> "Fold"
    Reject _ -> "Reject"
    Reclaim _ -> "Reclaim"
    Inspect _ -> "Inspect"

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

-- | What two packaged writes left: each run, the registry's files and its journal.
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
                ["registry", "create", "--seed", first]
        second <- fundSeed2 rig
        two <-
            packaged
                rig
                "registry-2"
                "create two"
                ["registry", "create", "--seed", second]
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
                ( runPackagedVia
                    (\tracer -> (envOf rig){envTracer = tracer})
                    (pure (Just h))
                    (commandLine rig registry args <> flags)
                    []
                )
        hClose h
        err <- BS.readFile errPath
        pure (name, code, out, err)
    registryFiles registry = do
        names <- sort <$> listDirectoryRecursive registry
        files <-
            mapM
                (\p -> (,) (registry </> p) <$> BS.readFile (registry </> p))
                (filter (/= "journal.jsonl") names)
        journal <-
            mapM
                (maybe (fail "a journal line is not JSON") pure . Aeson.decodeStrict)
                . BC.lines
                =<< BS.readFile (registry </> "journal.jsonl")
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
    , runKey :: Maybe Text
    -- ^ The key the command line names, base16
    }

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
        (Aeson.encode (Aeson.object ["int" .= (7 :: Int)]))
    BL.writeFile
        (dir </> "payload-2.json")
        (Aeson.encode (Aeson.object ["int" .= (8 :: Int)]))
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
    tracer <- compose (Tracer (\t -> modifyIORef' events (<> [t])))
    use (Rig dir chain wallet keyPath blueprint events answer tracer)

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
failingOpenDatum :: Aeson.Value
failingOpenDatum = blueprintOf $ \title arity ->
    if title == "open_datum.open_datum"
        then errorProgram arity
        else unitProgram arity

-- | The registry's validators, each program made from its title and arity.
blueprintOf :: (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintOf program =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= [ validator "state.state" 1
               , validator "request.request" 3
               , validator "open_datum.open_datum" 2
               , validator "witness.witness" 3
               ]
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
        , envReads = \_ k -> k (capabilities rig)
        , envWrites = \_ _ k -> k (capabilities rig)
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

-- ---------------------------------------------------------
-- The lifecycle
-- ---------------------------------------------------------

{- | Run the commands in the order a registry's life takes them, each over the
state the previous left, whatever outcome each reaches.
-}
lifecycle :: Rig -> IO [Run]
lifecycle rig = do
    seed <- fundSeed rig
    create <- run rig "create" ["registry", "create", "--seed", seed]
    insert <-
        run
            rig
            "insert alice-1"
            ["registry", "insert", "--key", "alice-1", "--payload", payload]
    fold1 <-
        run rig "fold alice-1" (["registry", "fold"] <> requestOf insert)
    inspect <-
        run rig "inspect alice-1" ["registry", "inspect", "--key", "alice-1"]
    update <-
        run
            rig
            "update alice-1"
            ["registry", "update", "--key", "alice-1", "--payload", payload2]
    terminate <-
        run
            rig
            "terminate alice-1"
            ["registry", "terminate", "--key", "alice-1"]
    fold2 <-
        run
            rig
            "fold alice-1 terminal"
            (["registry", "fold"] <> requestOf terminate)
    insert2 <-
        run
            rig
            "insert alice-2"
            ["registry", "insert", "--key", "alice-2", "--payload", payload]
    -- the chain moves past the processing deadline: the retract window opens
    jumpPast rig insert2 0
    reclaim <-
        run
            rig
            "reclaim alice-2"
            (["registry", "reclaim"] <> requestOrAny insert2)
    -- a second registry whose windows close at once: its request can only be rejected
    seed2 <- fundSeed2 rig
    create2 <-
        runAt
            rig
            "registry-2"
            "create short windows"
            [ "registry"
            , "create"
            , "--seed"
            , seed2
            , "--process-time"
            , "1"
            , "--retract-time"
            , "1"
            ]
    insert3 <-
        runAt
            rig
            "registry-2"
            "insert alice-3"
            ["registry", "insert", "--key", "alice-3", "--payload", payload]
    jumpPast rig insert3 2
    reject <- runAt rig "registry-2" "reject" ["registry", "reject"]
    -- refusals, each where it happens
    nothingPending <-
        runAt
            rig
            "registry-2"
            "fold with nothing pending"
            ["registry", "fold"]
    overAllowance <-
        run
            rig
            "insert over its allowance"
            [ "registry"
            , "insert"
            , "--key"
            , "alice-4"
            , "--payload"
            , payload
            , "--max-outlay"
            , "1"
            ]
    absent <-
        run
            rig
            "update an absent key"
            ["registry", "update", "--key", "nobody", "--payload", payload2]
    -- refused before any transaction is built
    existing <-
        run
            rig
            "create over an existing registry"
            ["registry", "create", "--seed", seed]
    missing <-
        runAt
            rig
            "no-registry"
            "inspect a registry that does not exist"
            ["registry", "inspect", "--key", "alice-1"]
    writeIORef
        (rigAnswer rig)
        (Just (Cage.SubmitRefused "the ledger said no"))
    rejected <-
        run
            rig
            "insert the ledger rejects"
            ["registry", "insert", "--key", "alice-5", "--payload", payload]
    writeIORef
        (rigAnswer rig)
        (Just (Cage.SubmitFailed "connection refused"))
    unanswered <-
        run
            rig
            "insert the provider drops"
            ["registry", "insert", "--key", "alice-6", "--payload", payload]
    pure
        [ create
        , insert
        , fold1
        , inspect
        , update
        , terminate
        , fold2
        , insert2
        , reclaim
        , create2
        , insert3
        , reject
        , nothingPending
        , overAllowance
        , absent
        , existing
        , missing
        , rejected
        , unanswered
        ]
  where
    payload = rigDir rig </> "payload.json"
    payload2 = rigDir rig </> "payload-2.json"
    requestOf r =
        maybe
            []
            (\q -> ["--request", T.unpack q])
            (textAt "request" (runReceipt r))
    requestOrAny r =
        [ "--request"
        , maybe
            (replicate 64 '0' <> "#0")
            T.unpack
            (textAt "request" (runReceipt r))
        ]

{- | Move the chain's tip past a booking's processing deadline, by this many
slots more, as its receipt names the deadline.
-}
jumpPast :: Rig -> Run -> Word64 -> IO ()
jumpPast rig booking more = case deadlineSlot (runReceipt booking) of
    Just slot -> jumpChainTo (rigChain rig) (SlotNo (slot + more + 1))
    Nothing ->
        fail
            ( "no deadline slot in "
                <> runLabel booking
                <> ": "
                <> show (runReceipt booking)
            )
  where
    -- the fixture's slots are seconds since 1970, so a deadline the view did not
    -- convert still names its slot
    deadlineSlot = \case
        Aeson.Object o
            | Just (Aeson.Object d) <- KeyMap.lookup "foldDeadline" o
            , Just (Aeson.Number n) <- KeyMap.lookup "posixMs" d ->
                Just (round n `div` 1000)
        _ -> Nothing

-- | A wallet output the create can consume as its seed.
fundSeed :: Rig -> IO String
fundSeed _ = pure (T.unpack (renderOutRef (fundOutput 1)))

-- | A wallet output still unspent, for the second registry.
fundSeed2 :: Rig -> IO String
fundSeed2 rig = do
    held <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \s ->
            SessionIO.outputsAt s (walletAddr (rigWallet rig))
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for a second registry"

-- | One command line, parsed as the packaged command parses it and run in process.
run :: Rig -> String -> [String] -> IO Run
run rig = runAt rig "registry"

-- | The same, against the registry in this directory of the rig.
runAt :: Rig -> FilePath -> String -> [String] -> IO Run
runAt rig registry label args = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseCommand (commandLine rig registry args))
    (code, out, _) <- captured (runCommand (envOf rig) command)
    receipt <-
        maybe
            (fail ("no receipt for " <> label <> ": " <> show out))
            pure
            (Aeson.decodeStrict out)
    events <- readIORef (rigEvents rig)
    pure
        Run
            { runName = constructorOf command
            , runLabel = label
            , runExit = code
            , runReceipt = receipt
            , runEvents = events
            , runKey =
                listToMaybe
                    [ hexText (TE.encodeUtf8 (T.pack k))
                    | ("--key", k) <- zip args (drop 1 args)
                    ]
            }

-- | A command line over the rig, as the packaged command is given it.
commandLine :: Rig -> FilePath -> [String] -> [String]
commandLine rig registry args =
    args
        <> [ "--registry"
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
    wantsKey = take 2 args /= ["registry", "inspect"]

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
objectsIn :: Aeson.Value -> [Aeson.Object]
objectsIn = \case
    Aeson.Object o -> o : concatMap objectsIn (KeyMap.elems o)
    Aeson.Array xs -> concatMap objectsIn (toList xs)
    _ -> []

{- | A request the receipt names: its key, edge and processing deadline, where
the object naming it states them.
-}
data RequestFact = RequestFact
    { factRequest :: Text
    , factKey :: Maybe Text
    , factEdge :: Maybe Text
    , factDeadline :: Maybe Integer
    }

{- | The receipt's request facts: each object naming a request, and the
request a booking left (its output 0).
-}
requestFacts :: Aeson.Value -> [RequestFact]
requestFacts receipt =
    [ RequestFact r (fieldOf "key" o) (fieldOf "edge" o) (deadlineIn o)
    | o <- objectsIn receipt
    , Just r <- [fieldOf "request" o]
    ]
        <> [ RequestFact r Nothing Nothing Nothing
           | o <- objectsIn receipt
           , Just r <- [fieldOf "pendingRequest" o]
           ]
        <> [ RequestFact (b <> "#0") (fieldOf "key" o) Nothing Nothing
           | Aeson.Object o <- [receipt]
           , Just b <- [fieldOf "booking" o]
           ]
  where
    deadlineIn o = case KeyMap.lookup "foldDeadline" o of
        Just d -> integerAt "posixMs" d
        Nothing -> integerAt "processingEnds" (Aeson.Object o)

fieldOf :: Aeson.Key -> Aeson.Object -> Maybe Text
fieldOf k o = case KeyMap.lookup k o of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

integerAt :: Aeson.Key -> Aeson.Value -> Maybe Integer
integerAt k = \case
    Aeson.Object o
        | Just v <- KeyMap.lookup k o
        , Aeson.Success i <- Aeson.fromJSON v ->
            Just i
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

-- | The receipt's submissions: step, transaction id, case and whether observed.
submissionsOf :: Aeson.Value -> [(Text, Text, Maybe Text, Bool)]
submissionsOf = \case
    Aeson.Object o
        | Just (Aeson.Array xs) <- KeyMap.lookup "submissions" o ->
            [ (s, t, c, observed)
            | Aeson.Object x <- toList xs
            , Just (Aeson.String s) <- [KeyMap.lookup "step" x]
            , Just (Aeson.String t) <- [KeyMap.lookup "tx" x]
            , let c = case KeyMap.lookup "case" x of
                    Just (Aeson.String v) -> Just v
                    _ -> Nothing
                  observed = KeyMap.lookup "observed" x == Just (Aeson.Bool True)
            ]
    _ -> []

{- | The edge actions a command performs, by its receipt's command: create
boots, insert and terminate book the edge their plan books (and fold it when
asked), update updates, reject rejects, fold and reclaim act on the edge
their receipt names. Inspect performs none.
-}
inRole :: Maybe Text -> Maybe Text -> EdgeAction -> Bool
inRole command receiptEdge action = case (command, action) of
    (Just "create", Booting) -> True
    (Just "insert", Booking e) -> e == booked edgeInsertActive
    (Just "insert", Folding e) -> e == booked edgeInsertActive
    (Just "terminate", Booking e) -> e == booked edgeUpdateTerminal
    (Just "terminate", Folding e) -> e == booked edgeUpdateTerminal
    (Just "update", Updating) -> True
    (Just "fold", Folding e) -> Just e == receiptEdge || receiptEdge == Nothing
    (Just "reject", Rejecting) -> True
    (Just "reclaim", Reclaiming e) -> Just e == receiptEdge || receiptEdge == Nothing
    _ -> False
  where
    booked = T.pack . edgeName

-- | Whether a refusal kind can stand under a receipt's outcome.
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
disagreements invokedKey receipt events =
    concat
        [ ends
        , ["key " <> show k | k <- eventKeys, Just k /= expectedKey]
        , [ "request " <> show r <> " not named by the receipt"
          | r <- eventRequests
          , r `notElem` map factRequest facts
          , not (null facts && outcome /= Just "success")
          ]
        , [ "request " <> show r <> " " <> what' <> " " <> v
          | Trace _ (What (RequestSeen r e k d _)) <- events
          , f <- facts
          , factRequest f == r
          , (what', v, fv) <-
                [ ("key", show (hexText k), show <$> factKey f)
                , ("edge", show e, show <$> factEdge f)
                ]
                    <> [ ("deadline", show d, show . Just <$> factDeadline f)
                       | isJust d
                       ]
          , Just w <- [fv]
          , w /= v
          ]
        , [ "booked " <> show r <> " deadline " <> show d
          | Trace _ (What (Booked r (Just d))) <- events
          , f <- facts
          , factRequest f == r
          , Just d' <- [factDeadline f]
          , d /= d'
          ]
        , [ "edge " <> show a <> " outside the command's role"
          | a <- eventEdges
          , not (inRole command receiptEdge a)
          ]
        , [ "leaf " <> show l
          | Trace _ (What (KeySeen _ l _)) <- events
          , Just l' <- [textAt "leaf" receipt]
          , l /= l'
          ]
        , [ "holding " <> show h
          | Trace _ (What (KeySeen _ _ h)) <- events
          , Just application <- [valueAt "applicationOutput" receipt]
          , h /= textAt "output" application
          ]
        , [ "pending " <> show n
          | Trace _ (What (RegistrySeen _ _ (Just n))) <- events
          , Just ps <- [elementsAt "pendingRequests" receipt]
          , n /= length ps
          ]
        , [ "registry root " <> show r
          | Trace _ (What (RegistrySeen _ r _)) <- events
          , Just expected <- [rootBefore]
          , r /= expected
          ]
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
        , [ "root " <> show a
          | Trace _ (What (RootSeen _ a)) <- events
          , Just a /= textAt "root" receipt
          ]
        , [ "token " <> show tok
          | Trace _ (What (Created tok _)) <- events
          , Just tok /= textAt "token" receipt
          ]
        , [ "created state " <> show st
          | Trace _ (What (Created _ st)) <- events
          , Just (T.takeWhile (/= '#') st) /= textAt "boot" receipt
          ]
        , [ "rejected " <> show rs
          | Trace _ (What (Rejected rs)) <- events
          , sort rs /= sort receiptRejected
          ]
        , [ "reclaimed " <> show v
          | Trace _ (What (Reclaimed _ v)) <- events
          , Just v /= (valueAt "returned" receipt >>= integerAt "lovelace")
          ]
        , [ "updated output " <> show o
          | Trace _ (What (Updated _ o)) <- events
          , Just o /= textAt "liveOutput" receipt
          ]
        , [ "folded output " <> show o
          | Trace _ (What (Folded _ _ o)) <- events
          , Just o /= (textAt "liveOutput" receipt <|> textAt "released" receipt)
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
    expectedKey = textAt "key" receipt <|> invokedKey
    receiptEdge = textAt "edge" receipt
    facts = requestFacts receipt
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
    receiptRejected =
        [ r
        | Just xs <- [elementsAt "rejected" receipt]
        , Aeson.Object o <- xs
        , Just r <- [fieldOf "request" o]
        ]
    rootBefore = case [b | Trace _ (What (RootSeen b _)) <- events] of
        b : _ -> Just b
        [] -> textAt "root" receipt
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
    eventKeys =
        [hexText k | Trace _ (What (KeySeen k _ _)) <- events]
            <> [hexText k | Trace _ (What (Folded _ k _)) <- events]
            <> [hexText k | Trace _ (What (Updated k _)) <- events]
            <> [hexText k | Trace scope _ <- events, InKey k <- scope]
    eventRequests =
        [r | Trace _ (What (RequestSeen r _ _ _ _)) <- events]
            <> [r | Trace _ (What (Booked r _)) <- events]
            <> [r | Trace _ (What (Reclaimed r _)) <- events]
            <> concat [rs | Trace _ (What (Rejected rs)) <- events]
            <> [r | Trace scope _ <- events, InRequest r <- scope]
    eventEdges =
        [a | Trace _ (What (EdgeStarted a)) <- events]
            <> [a | Trace scope _ <- events, InEdge a <- scope]
            <> [Folding e | Trace _ (What (Folded e _ _)) <- events]
    eventTxs =
        [ (s, t, observedOnly)
        | Trace _ (How (Tx e)) <- events
        , Just (s, t) <- [txOf e]
        , let observedOnly = case e of
                TxObserved{} -> True
                _ -> False
        ]
    txOf = \case
        TxBuilt{} -> Nothing
        TxSigned s t _ _ _ -> Just (s, t)
        TxSubmitted{submitStep = s, submitTx = t} -> Just (s, t)
        TxConfirmed s t _ _ -> Just (s, t)
        TxObserved s t _ -> Just (s, t)
    signed s t = \case
        Trace _ (How (Tx (TxSigned s' t' _ _ _))) -> (s', t') == (s, t)
        _ -> False
    submitted s t = \case
        Trace _ (How (Tx TxSubmitted{submitStep = s', submitTx = t'})) -> (s', t') == (s, t)
        _ -> False
    observedEvent s t = \case
        Trace _ (How (Tx (TxObserved s' t' _))) -> (s', t') == (s, t)
        _ -> False
    verdictsOf t =
        [ Left v
        | Trace _ (How (Tx TxSubmitted{submitTx = t', submitVerdict = v})) <-
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
    , (label, e') <- alter e <> scoped e
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
    bound k = isJust (valueAt k receipt)
    deadlineOf r =
        listToMaybe
            [ d
            | f <- requestFacts receipt
            , factRequest f == r
            , Just d <- [factDeadline f]
            ]
    flipText t = if T.take 1 t == "0" then "1" <> T.drop 1 t else "0" <> T.drop 1 t
    flipBytes b = "x" <> b
    otherEdge = \case
        Booking e -> Booking (e <> "x")
        Folding e -> Folding (e <> "x")
        Reclaiming e -> Reclaiming (e <> "x")
        Updating -> Rejecting
        _ -> Updating
    scoped (Trace scope event) =
        [ (label, Trace (outer <> [s'] <> inner) event)
        | (k, s) <- zip [0 :: Int ..] scope
        , let (outer, rest) = splitAt k scope
              inner = drop 1 rest
        , (label, s') <- case s of
            InKey key -> [("scope key", InKey (flipBytes key))]
            InRequest r -> [("scope request", InRequest (flipText r))]
            InEdge a -> [("scope edge", InEdge (otherEdge a))]
            _ -> []
        ]
    alter (Trace scope event) = case event of
        What (CommandEnded c o ms) ->
            [ ("outcome", Trace scope (What (CommandEnded c (o <> "-altered") ms)))
            , ("command", Trace scope (What (CommandEnded (c <> "-altered") o ms)))
            ]
        What (KeySeen k l h) ->
            [("key", Trace scope (What (KeySeen (flipBytes k) l h)))]
                <> [ ("leaf", Trace scope (What (KeySeen k (l <> "x") h)))
                   | bound "leaf"
                   ]
                <> [ ( "holding"
                     , Trace scope (What (KeySeen k l (maybe (Just "x") (const Nothing) h)))
                     )
                   | bound "applicationOutput"
                   ]
        What (RegistrySeen st r p) ->
            [ ("pending", Trace scope (What (RegistrySeen st r ((+ 1) <$> p))))
            | isJust p
            , bound "pendingRequests"
            ]
                <> [ ("registry root", Trace scope (What (RegistrySeen st (flipText r) p)))
                   | bound "root"
                   ]
        What (RequestSeen r e k d s) ->
            [ ("request", Trace scope (What (RequestSeen (flipText r) e k d s)))
            ,
                ( "request key"
                , Trace scope (What (RequestSeen r e (flipBytes k) d s))
                )
            , ("request edge", Trace scope (What (RequestSeen r (e <> "x") k d s)))
            ]
                <> [ ( "request deadline"
                     , Trace scope (What (RequestSeen r e k ((+ 1) <$> d) s))
                     )
                   | isJust d
                   , isJust (deadlineOf r)
                   ]
        What (EdgeStarted a) -> [("edge started", Trace scope (What (EdgeStarted (otherEdge a))))]
        What (Booked r d) ->
            [("booked request", Trace scope (What (Booked (flipText r) d)))]
                <> [ ("booked deadline", Trace scope (What (Booked r ((+ 1) <$> d))))
                   | isJust d
                   , isJust (deadlineOf r)
                   ]
        What (Folded e k o) ->
            [ ("fold edge", Trace scope (What (Folded (e <> "x") k o)))
            , ("fold key", Trace scope (What (Folded e (flipBytes k) o)))
            , ("fold output", Trace scope (What (Folded e k (flipText o))))
            ]
        What (Updated k o) ->
            [ ("update key", Trace scope (What (Updated (flipBytes k) o)))
            , ("update output", Trace scope (What (Updated k (flipText o))))
            ]
        What (Rejected rs) ->
            [ ("rejected request", Trace scope (What (Rejected (map flipText rs))))
            ]
                <> [ ("rejected dropped", Trace scope (What (Rejected (drop 1 rs))))
                   | not (null rs)
                   ]
        What (Reclaimed r v) ->
            [ ("reclaimed request", Trace scope (What (Reclaimed (flipText r) v)))
            , ("reclaimed amount", Trace scope (What (Reclaimed r (v + 1))))
            ]
        What (Created t s) ->
            [ ("token", Trace scope (What (Created (flipText t) s)))
            , ("created state", Trace scope (What (Created t (flipText s))))
            ]
        What (RootSeen b a) -> [("root", Trace scope (What (RootSeen b (flipText a))))]
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
    pure (Tracer (hPutStrLn h . show))

-- | Every fact 'alterations' plants a contradiction in.
plantedFacts :: [String]
plantedFacts =
    [ "outcome"
    , "command"
    , "key"
    , "leaf"
    , "holding"
    , "pending"
    , "registry root"
    , "request"
    , "request key"
    , "request edge"
    , "request deadline"
    , "edge started"
    , "booked request"
    , "booked deadline"
    , "fold edge"
    , "fold key"
    , "fold output"
    , "update key"
    , "update output"
    , "rejected request"
    , "rejected dropped"
    , "reclaimed request"
    , "reclaimed amount"
    , "token"
    , "created state"
    , "root"
    , "refusal kind"
    , "signed id"
    , "submitted verdict"
    , "confirmed verdict"
    , "observed step"
    , "observation removed"
    , "refusal removed"
    , "refusal repeated"
    , "scope key"
    , "scope request"
    , "scope edge"
    ]

-- | The journal steps that act on an edge: boot, book, fold, update, reject, reclaim.
edgeSteps :: [Text]
edgeSteps = ["boot", "book", "fold", "update", "reject", "reclaim"]

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
