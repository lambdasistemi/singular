{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.TraceSpec
Description : #416 — the tracing controls, the indented narration and the JSON lines of one typed stream
License     : Apache-2.0

The controls are read from the command line alone, on every command. The
renderers are pure functions of the typed events; the JSON lines decode back
to the events they render, for every constructor the event types declare (the
extent is read from the types, not listed here). The entry point's receipt and
exit status are compared under every tracing setting.
-}
module Singular.CLI.TraceSpec (spec) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, replicateM)
import Control.Tracer (Tracer (..), nullTracer, traceWith)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Data
    ( Data
    , dataTypeConstrs
    , dataTypeName
    , dataTypeOf
    , gmapQ
    , showConstr
    , toConstr
    )
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
    ( Handle
    , hClose
    , hFlush
    , hPrint
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
import Test.QuickCheck
    ( Gen
    , chooseInt
    , chooseInteger
    , elements
    , forAll
    , generate
    , listOf
    , oneof
    , vectorOf
    , (===)
    )

import Singular.CLI.Command
    ( CLIError (..)
    , Command (..)
    , parseCommand
    , parseInvocation
    )
import Singular.CLI.Finish (finish)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Root (runPackagedWith, runSingular, standardError)
import Singular.CLI.Session (failWith)
import Singular.CLI.Trace
import Singular.Registry.Trace

spec :: Spec
spec = describe "protocol narration (#416)" $ do
    controls
    defaults
    narration
    jsonLines
    fanOutRows
    phaseLogKeys
    entryPoint
    setupRecut

-- ---------------------------------------------------------
-- The controls, on every command
-- ---------------------------------------------------------

-- | Each of the eight commands, spelled with what it needs to parse.
commands :: [(String, [String])]
commands =
    [ ("create", ["registry", "create", "--seed", seed] <> base <> wallet)
    ,
        ( "insert"
        , ["registry", "insert", "--key", "alice-1", "--payload", "/p.json"]
            <> base
            <> wallet
        )
    ,
        ( "update"
        , ["registry", "update", "--key", "alice-1", "--payload", "/p.json"]
            <> base
            <> wallet
        )
    ,
        ( "terminate"
        , ["registry", "terminate", "--key", "alice-1"] <> base <> wallet
        )
    , ("fold", ["registry", "fold"] <> base <> wallet)
    , ("reject", ["registry", "reject"] <> base <> wallet)
    ,
        ( "reclaim"
        , ["registry", "reclaim", "--request", seed] <> base <> wallet
        )
    , ("inspect", ["registry", "inspect", "--key", "alice-1"] <> base)
    ]
  where
    seed = replicate 64 'a' <> "#0"
    base =
        [ "--registry"
        , "/srv/reg"
        , "--blueprint"
        , "/srv/plutus.json"
        , "--koios-url"
        , "http://127.0.0.1:8080/api/v1"
        , "--network-magic"
        , "42"
        ]
    wallet = ["--wallet-skey", "/keys/payment.skey"]

controls :: Spec
controls = describe "the tracing controls on every command" $ do
    forM_ commands $ \(name, args) -> do
        it
            ( name
                <> " takes --trace, a repeated --trace-to and --trace-format, and parses as without them"
            )
            $ do
                let plain = parseCommand args
                plain `shouldSatisfy` either (const False) (const True)
                forM_ [("off", TraceOff), ("what", TraceWhat), ("how", TraceHow)] $ \(spelled, level) ->
                    parseInvocation
                        []
                        ( args
                            <> [ "--trace"
                               , spelled
                               , "--trace-to"
                               , "stderr"
                               , "--trace-to"
                               , "file:/tmp/trace.jsonl"
                               , "--trace-format=json"
                               ]
                        )
                        `shouldBe` fmap
                            (,TraceRequest
                                (Just level)
                                [ToStderr, ToFile "/tmp/trace.jsonl"]
                                (Just JsonFormat))
                            plain
                parseInvocation
                    []
                    ( args
                        <> [ "--trace-format"
                           , "text"
                           , "--trace-to=file:/a"
                           , "--trace-to"
                           , "file:/b"
                           ]
                    )
                    `shouldBe` fmap
                        (,TraceRequest Nothing [ToFile "/a", ToFile "/b"] (Just TextFormat))
                        plain
                parseInvocation [] args
                    `shouldBe` fmap (,noTraceRequest) plain
        it (name <> " refuses an unknown level, sink or format at parse") $ do
            forM_ ["", "loud", "HOW", "1"] $ \level ->
                parseInvocation [] (args <> ["--trace", level])
                    `shouldBe` Left (BadValue "--trace" "is off, what or how")
            forM_ ["", "stdout", "socket", "tcp:127.0.0.1:9", "file:", "file"] $ \sink ->
                parseInvocation [] (args <> ["--trace-to", sink])
                    `shouldBe` Left (BadValue "--trace-to" "is stderr or file:PATH")
            forM_ ["", "xml", "JSON", "lines"] $ \format ->
                parseInvocation [] (args <> ["--trace-format", format])
                    `shouldBe` Left (BadValue "--trace-format" "is text or json")
    it "still answers help with tracing flags present" $
        fmap fst (parseInvocation [] ["registry", "--help", "--trace", "how"])
            `shouldBe` Right Help

defaults :: Spec
defaults = describe "the tracing defaults" $ do
    it
        "narrates what on a terminal and nothing otherwise, when nothing is asked"
        $ do
            resolveOutputs True noTraceRequest
                `shouldBe` (TraceWhat, [Output ToStderr TextFormat])
            resolveOutputs False noTraceRequest `shouldBe` (TraceOff, [])
    it
        "writes text to stderr and json to a file, unless a format is named"
        $ do
            let asked = TraceRequest (Just TraceHow)
            forM_ [True, False] $ \terminal -> do
                resolveOutputs terminal (asked [] Nothing)
                    `shouldBe` (TraceHow, [Output ToStderr TextFormat])
                resolveOutputs terminal (asked [ToFile "/t"] Nothing)
                    `shouldBe` (TraceHow, [Output (ToFile "/t") JsonFormat])
                resolveOutputs terminal (asked [ToStderr, ToFile "/t"] Nothing)
                    `shouldBe` ( TraceHow
                               , [Output ToStderr TextFormat, Output (ToFile "/t") JsonFormat]
                               )
                resolveOutputs terminal (asked [ToStderr] (Just JsonFormat))
                    `shouldBe` (TraceHow, [Output ToStderr JsonFormat])
                resolveOutputs terminal (asked [ToFile "/t"] (Just TextFormat))
                    `shouldBe` (TraceHow, [Output (ToFile "/t") TextFormat])
    it "opens nothing at --trace off" $
        forM_ [True, False] $ \terminal ->
            resolveOutputs
                terminal
                (TraceRequest (Just TraceOff) [ToStderr, ToFile "/t"] Nothing)
                `shouldBe` (TraceOff, [])
    it "takes the level from the terminal when only a sink is named" $ do
        resolveOutputs True (TraceRequest Nothing [ToFile "/t"] Nothing)
            `shouldBe` (TraceWhat, [Output (ToFile "/t") JsonFormat])
        resolveOutputs False (TraceRequest Nothing [ToFile "/t"] Nothing)
            `shouldBe` (TraceOff, [])
    it "classifies every event constructor as what or how, never off" $ do
        samples <- generate (vectorOf 4000 genTrace)
        forM_ samples $ \t ->
            levelOf t
                `shouldBe` case traceEvent t of
                    What _ -> TraceWhat
                    How _ -> TraceHow
    it "shows what at what, what and how at how, and nothing at off" $
        forM_ [whatEvent, howEvent] $ \e -> do
            atLevel TraceOff e `shouldBe` False
            atLevel TraceHow e `shouldBe` True
            atLevel TraceWhat e `shouldBe` isWhat e
  where
    whatEvent = Trace [] (What (CommandEnded "fold" "success" 1_500))
    howEvent = Trace [] (How (Tx (TxObserved "fold" (T.replicate 64 "b") 1)))
    isWhat t = case traceEvent t of What _ -> True; How _ -> False

-- ---------------------------------------------------------
-- The indented narration
-- ---------------------------------------------------------

token, state, root, rootAfter, request, foldTx :: Text
token = "7c58a200bfccfebd5e0f19c2"
state =
    "8c2392195e0f19c2a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718#0"
root = "583975870000000000000000000000000000000000000000000000000000aa01"
rootAfter = "4f2be0a10000000000000000000000000000000000000000000000000000aa02"
request =
    "5e0f19c2aa00000000000000000000000000000000000000000000000000bb01#0"
foldTx = "9a51d7e4cc00000000000000000000000000000000000000000000000000dd01"

-- | A fold of alice-3's insertion, as the command reports it.
foldStory :: [Trace]
foldStory =
    [ Trace [] (What (CommandStarted "fold"))
    , Trace reg (What (RegistrySeen state root (Just 1)))
    , Trace
        tx0
        ( How
            ( Backend
                ( Exchanged
                    ( Query
                        "address_utxos"
                        "Koios"
                        (Just "koios-1")
                        401.0
                        (Answered Nothing)
                    )
                )
            )
        )
    , Trace
        tx0
        ( How
            ( Read
                ( Queried
                    (Query "outputs" "Koios" (Just "koios-1") 402.5 (Answered (Just 3)))
                )
            )
        )
    , Trace
        tx0
        (How (Fetched (Fetch ["state", "requests"] "Koios" 812.5 Done)))
    , Trace
        req
        ( What
            ( RequestSeen
                request
                "insertActive"
                "alice-3"
                (Just 1_791_271_886_000)
                (Just 135_588_686)
            )
        )
    , Trace edge (What (EdgeStarted (Folding "insertActive")))
    , Trace
        tx
        (How (Read (Evaluated (Evaluation 410.0 3 0 1_240_000 439_000_000))))
    , Trace tx (How (Tx (TxBuilt "fold" 612.0 Done)))
    , Trace tx (How (Tx (TxSigned "fold" foldTx (Just 889_465) 104.0 Done)))
    , Trace
        tx
        ( How
            ( Tx
                ( TxSubmitted
                    "fold"
                    foldTx
                    (Just 135_588_100)
                    (Just 135_588_686)
                    (TipSlot 135_588_101)
                    401.0
                    Accepted
                )
            )
        )
    , Trace tx (How (Tx (TxConfirmed "fold" foldTx 17_400.0 Confirmed)))
    , Trace tx (How (Tx (TxObserved "fold" foldTx 2_000.0)))
    , Trace edge (What (Folded "insertActive" "alice-3" (foldTx <> "#1")))
    , Trace reg (What (RootSeen root rootAfter))
    , Trace [] (What (CommandEnded "fold" "success" 53_412.0))
    ]
  where
    reg = [InRegistry token]
    tx0 = reg <> [InTransaction "fold"]
    req = reg <> [InRequest request]
    edge = req <> [InEdge (Folding "insertActive")]
    tx = edge <> [InTransaction "fold"]

narration :: Spec
narration = describe "the indented narration" $ do
    it
        "nests registry, request, edge and transaction, each how under its what"
        $ mapMaybe renderText foldStory
            `shouldBe` [ "registry 7c58a200… (root 58397587…, 1 pending)"
                       , "  how  read state, requests via Koios ................................... 0.8s"
                       , "  request 5e0f19c2…#0 insertActive \"alice-3\" (deadline 2026-10-06 07:31:26Z, slot 135588686)"
                       , "    fold insertActive"
                       , "      how  evaluate 3 scripts ✓ (mem 1.24M, steps 439M) ................. 0.4s"
                       , "      how  build fold ................................................... 0.6s"
                       , "      how  sign 9a51d7e4…, fee 0.889465 tADA ............................ 0.1s"
                       , "      how  submit tx 9a51d7e4… at tip slot 135588101 .................... 0.4s"
                       , "      how  confirm tx 9a51d7e4… ........................................ 17.4s"
                       , "      how  observe tx 9a51d7e4… ......................................... 2.0s"
                       , "    result \"alice-3\" insertActive folded, output 9a51d7e4…#1"
                       , "  root 58397587… → 4f2be0a1…"
                       , "fold success ........................................................... 53.4s"
                       ]
    it
        "indents each event from its own scope path, whatever order they arrive in"
        $ reverse (map renderText (reverse foldStory))
            `shouldBe` map renderText foldStory
    it "leaves each provider call and backend mechanic to the JSON lines" $ do
        samples <- generate (vectorOf 4000 genTrace)
        let calls = [t | t@(Trace _ (How h)) <- samples, isCall h]
            isCall = \case
                Read (Queried _) -> True
                Read (ViewOpened _) -> True
                Read (ViewReleased _) -> True
                Backend _ -> True
                _ -> False
        length calls `shouldSatisfy` (> 100)
        map renderText calls `shouldSatisfy` all (== Nothing)
    it "says where each refusal happened, in four distinct lines" $ do
        let at kind = renderText (Trace [InRegistry token] (What (Refused kind Nothing)))
            rendered = map at [minBound .. maxBound]
        rendered
            `shouldBe` map
                Just
                [ "  refused by the client: nothing was submitted"
                , "  refused by local script evaluation: nothing was submitted"
                , "  rejected by the ledger"
                , "  refused by the provider, not the ledger: no ledger judged it"
                ]
        length (nub rendered) `shouldBe` 4

-- ---------------------------------------------------------
-- JSON lines
-- ---------------------------------------------------------

jsonLines :: Spec
jsonLines = describe "the JSON lines" $ do
    it
        "writes one complete object per line, newline-terminated, that decodes back to its event"
        $ forAll genTrace
        $ \t ->
            let line = renderJsonLine t
            in  ( BC.count '\n' line
                , BC.last <$> nonEmpty line
                , isJust (Aeson.decodeStrict (BC.init line) :: Maybe Aeson.Object)
                , decodeJsonLine line
                )
                    === (1, Just '\n', True, Just t)
    it "reaches every constructor the event types declare" $ do
        samples <- generate (vectorOf 4000 genTrace)
        let seen =
                Map.fromListWith
                    Set.union
                    [(ty, Set.singleton c) | s <- samples, (ty, c, _) <- constructorsIn s]
            declared =
                Map.fromList
                    [ (ty, Set.fromList cs) | s <- samples, (ty, _, cs) <- constructorsIn s
                    ]
        Map.size declared `shouldSatisfy` (> 10)
        Map.toList seen `shouldBe` Map.toList declared
  where
    nonEmpty b = if BS.null b then Nothing else Just b

{- | Every value of an event type inside a value: its type, its constructor and
every constructor its type declares.
-}
constructorsIn :: (Data d) => d -> [(String, String, [String])]
constructorsIn d =
    [ ( name
      , showConstr (toConstr d)
      , map showConstr (dataTypeConstrs (dataTypeOf d))
      )
    | let name = dataTypeName (dataTypeOf d)
    , any
        (`isPrefixOf` name)
        ["Singular.CLI.Trace.", "Singular.Registry.Trace."]
    ]
        <> concat (gmapQ constructorsIn d)

genTrace :: Gen Trace
genTrace =
    Trace <$> listOf genScope <*> oneof [What <$> genWhat, How <$> genHow]

genText :: Gen Text
genText =
    T.pack
        <$> listOf (elements (['a' .. 'f'] <> ['0' .. '9'] <> "#-é ✓\"\\"))

genHex :: Gen Text
genHex = T.pack <$> replicateM 16 (elements (['0' .. '9'] <> ['a' .. 'f']))

genBytes :: Gen BS.ByteString
genBytes = BS.pack . map fromIntegral <$> listOf (chooseInt (0, 255))

genMs :: Gen Double
genMs = (/ 1000) . fromIntegral <$> chooseInteger (0, 100_000_000)

genWord :: Gen Word
genWord = fromIntegral <$> chooseInteger (0, 2 ^ (40 :: Int))

genScope :: Gen Scope
genScope =
    oneof
        [ InRegistry <$> genHex
        , InKey <$> genBytes
        , InRequest <$> genHex
        , InEdge <$> genAction
        , InTransaction <$> genText
        ]

genAction :: Gen EdgeAction
genAction =
    oneof
        [ Booking <$> genText
        , Folding <$> genText
        , pure Updating
        , pure Rejecting
        , Reclaiming <$> genText
        , pure Booting
        , pure Inspecting
        ]

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [pure Nothing, Just <$> g]

genClass :: Gen ErrorClass
genClass = ErrorClass <$> genText

genWhat :: Gen What
genWhat =
    oneof
        [ CommandStarted <$> genText
        , CommandEnded <$> genText <*> genText <*> genMs
        , RegistrySeen <$> genHex <*> genHex <*> genMaybe (chooseInt (0, 9))
        , KeySeen <$> genBytes <*> genText <*> genMaybe genHex
        , RequestSeen
            <$> genHex
            <*> genText
            <*> genBytes
            <*> genMaybe (chooseInteger (0, 2 ^ (50 :: Int)))
            <*> genMaybe (fromIntegral <$> genWord)
        , EdgeStarted <$> genAction
        , Booked <$> genHex <*> genMaybe (chooseInteger (0, 2 ^ (50 :: Int)))
        , Folded <$> genText <*> genBytes <*> genHex
        , Updated <$> genBytes <*> genHex
        , Rejected <$> listOf genHex
        , Reclaimed <$> genHex <*> chooseInteger (0, 2 ^ (50 :: Int))
        , Created <$> genHex <*> genHex
        , RootSeen <$> genHex <*> genHex
        , Refused <$> elements [minBound .. maxBound] <*> genMaybe genClass
        ]

genHow :: Gen How
genHow =
    oneof
        [ Fetched
            <$> (Fetch <$> listOf genText <*> genText <*> genMs <*> genEnded)
        , Read <$> genRead
        , Backend <$> genBackend
        , Tx <$> genTx
        ]

genQuery :: Gen Query
genQuery =
    Query
        <$> genText
        <*> genText
        <*> genMaybe genText
        <*> genMs
        <*> oneof
            [ Answered <$> genMaybe (chooseInt (0, 99))
            , pure Lagged
            , QueryFailed <$> genClass
            ]

genOpening :: Gen ViewOpening
genOpening =
    oneof
        [ NodeViewOpened
            <$> genMs
            <*> (fromIntegral <$> genWord)
            <*> genHex
            <*> genText
        , NodeViewFailed <$> genMs <*> genClass
        , SessionViewOpened <$> genText <*> genText
        ]

genRelease :: Gen ViewRelease
genRelease = oneof [NodeViewHeld <$> genMs, SessionViewClosed <$> genText]

genBackend :: Gen BackendEvent
genBackend =
    oneof
        [ Exchanged <$> genQuery
        , BackendViewOpened <$> genOpening
        , BackendViewReleased <$> genRelease
        ]

genEnded :: Gen Ended
genEnded = oneof [pure Done, FailedWith <$> genClass]

genTx :: Gen TxEvent
genTx =
    oneof
        [ TxBuilt <$> genText <*> genMs <*> genEnded
        , TxSigned
            <$> genText
            <*> genHex
            <*> genMaybe (chooseInteger (0, 9_000_000))
            <*> genMs
            <*> genEnded
        , TxSubmitted
            <$> genText
            <*> genHex
            <*> genMaybe (fromIntegral <$> genWord)
            <*> genMaybe (fromIntegral <$> genWord)
            <*> oneof
                [ TipSlot . fromIntegral <$> genWord
                , pure TipUnreadable
                ]
            <*> genMs
            <*> oneof
                [ pure Accepted
                , pure LedgerRefusedIt
                , pure ProviderFailed
                , pure WrongNetwork
                , SubmitThrew <$> genClass
                ]
        , TxConfirmed
            <$> genText
            <*> genHex
            <*> genMs
            <*> oneof
                [ pure Confirmed
                , pure ConfirmTimedOut
                , ConfirmFailed <$> genClass
                , ConfirmThrew <$> genClass
                ]
        , TxObserved <$> genText <*> genHex <*> genMs
        ]

genRead :: Gen ReadEvent
genRead =
    oneof
        [ Queried <$> genQuery
        , ViewOpened <$> genOpening
        , ViewReleased <$> genRelease
        , Evaluated
            <$> ( Evaluation
                    <$> genMs
                    <*> chooseInt (0, 9)
                    <*> chooseInt (0, 9)
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                )
        , SessionOpened <$> genMs
        , HorizonWaited
            <$> ( HorizonWait . fromIntegral
                    <$> genWord
                    <*> (fromIntegral <$> genWord)
                    <*> genMaybe (fromIntegral <$> genWord)
                    <*> (fromIntegral <$> genWord)
                    <*> chooseInteger (0, 999)
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                    <*> chooseInteger (0, 99_999)
                    <*> genMs
                    <*> oneof
                        [ HorizonMoved . fromIntegral
                            <$> genWord
                            <*> (fromIntegral <$> genWord)
                        , HorizonFailed <$> genClass
                        ]
                )
        , ValiditySelected
            <$> ( ValiditySelection . fromIntegral
                    <$> genWord
                    <*> (fromIntegral <$> genWord)
                    <*> genMaybe (fromIntegral <$> genWord)
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                    <*> (fromIntegral <$> genWord)
                    <*> (fromIntegral <$> genWord)
                    <*> chooseInteger (0, 999)
                )
        , BodyBuilt
            <$> ( BodyBuild
                    <$> genText
                    <*> genMs
                    <*> oneof [pure BodyReady, pure BodyRefused, BodyFailed <$> genClass]
                )
        ]

-- ---------------------------------------------------------
-- One serialised fan-out
-- ---------------------------------------------------------

collector :: IO (IORef [Trace], Tracer IO Trace)
collector = do
    ref <- newIORef []
    pure
        (ref, Tracer (\t -> atomicModifyIORef' ref (\ts -> (ts <> [t], ()))))

fanOutRows :: Spec
fanOutRows = describe "one serialised fan-out to every sink" $ do
    it
        "loses no event and interleaves no line when eight threads trace at once"
        $ withSystemTempDirectory "trace-fan-out"
        $ \dir -> do
            let path = dir </> "trace.jsonl"
            events <- generate (vectorOf 400 genTrace)
            (seen, collect) <- collector
            tracer <-
                fanOut
                    [ outputSink (Just stderr) TraceHow (Output (ToFile path) JsonFormat)
                    , collect
                    ]
            mapConcurrently_
                (mapM_ (traceWith tracer))
                [ [e | (i, e) <- zip [0 :: Int ..] events, i `mod` 8 == thread]
                | thread <- [0 .. 7]
                ]
            doesFileExist path `shouldReturn` True
            raw <- BS.readFile path
            let decoded = map decodeJsonLine (BC.lines raw)
            collected <- readIORef seen
            length decoded `shouldBe` length events
            all isJust decoded `shouldBe` True
            -- every sink saw the same total order
            map Just collected `shouldBe` decoded
            sort (map show collected) `shouldBe` sort (map show events)
    it
        "writes each JSON line as its event happens, before the command ends"
        $ withSystemTempDirectory "trace-flush"
        $ \dir -> do
            let path = dir </> "trace.jsonl"
                sink = outputSink (Just stderr) TraceHow (Output (ToFile path) JsonFormat)
            forM_ (zip [1 :: Int ..] foldStory) $ \(n, t) -> do
                traceWith sink t
                there <- doesFileExist path
                count <-
                    if there then length . BC.lines <$> BS.readFile path else pure 0
                count `shouldBe` n
    it "keeps the other sinks when one cannot be written" $
        withSystemTempDirectory "trace-unwritable" $ \dir -> do
            (seen, collect) <- collector
            tracer <-
                fanOut
                    [ outputSink
                        (Just stderr)
                        TraceHow
                        (Output (ToFile (dir </> "missing" </> "trace.jsonl")) JsonFormat)
                    , outputSink (Just stderr) TraceHow (Output (ToFile dir) JsonFormat)
                    , collect
                    ]
            mapM_ (traceWith tracer) foldStory
            readIORef seen `shouldReturn` foldStory

-- ---------------------------------------------------------
-- The entry point
-- ---------------------------------------------------------

{- | Every tracing setting a command line can ask for, each with whether it
narrates on standard error.
-}
settings :: FilePath -> [(String, TraceRequest, Bool)]
settings dir =
    [ ("none", noTraceRequest, False)
    , ("off", TraceRequest (Just TraceOff) [ToStderr] Nothing, False)
    ,
        ( "what on stderr"
        , TraceRequest (Just TraceWhat) [ToStderr] Nothing
        , True
        )
    ,
        ( "how on stderr"
        , TraceRequest (Just TraceHow) [ToStderr] Nothing
        , True
        )
    ,
        ( "how as json on stderr"
        , TraceRequest (Just TraceHow) [ToStderr] (Just JsonFormat)
        , True
        )
    ,
        ( "how to a file"
        , TraceRequest (Just TraceHow) [ToFile (dir </> "a.jsonl")] Nothing
        , False
        )
    ,
        ( "how as text to a file and stderr"
        , TraceRequest
            (Just TraceHow)
            [ToFile (dir </> "b.txt"), ToStderr]
            (Just TextFormat)
        , True
        )
    ]

entryPoint :: Spec
entryPoint = describe "the receipt under every tracing setting" $ do
    it
        "keeps the packaged entry point's receipt and exit with a closed standard \
        \error and an unopenable file sink, whatever is asked"
        $ withSystemTempDirectory "trace-closed-stderr"
        $ \dir -> do
            let command =
                    [ "registry"
                    , "inspect"
                    , "--key"
                    , "alice-1"
                    , "--registry"
                    , dir </> "none"
                    , "--blueprint"
                    , dir </> "none.json"
                    , "--koios-url"
                    , "http://127.0.0.1:1/api/v1"
                    , "--network-magic"
                    , "1"
                    ]
                asked =
                    [ []
                    , ["--trace", "off"]
                    , ["--trace-to", "file:" <> (dir </> "missing" </> "t.jsonl")]
                    , ["--trace", "how", "--trace-to", "stderr"]
                    , ["--trace", "how", "--trace-to", "stderr", "--trace-format", "json"]
                    ]
            (_, open) <- openTempFile dir "stderr"
            (plainCode, plainOut, _) <-
                captured (runSingular (Just open) [] command)
            hClose open
            plainCode `shouldBe` ExitFailure 10
            closed <- closedHandle
            forM_ asked $ \flags -> do
                (code, out, _) <-
                    captured (runSingular (Just closed) [] (command <> flags))
                (flags, code, out) `shouldBe` (flags, plainCode, plainOut)
    it
        "keeps the packaged command's receipt and exit when every setup step fails in turn"
        $ withSystemTempDirectory "trace-packaged-setup"
        $ \dir -> do
            let refused =
                    [ "registry"
                    , "inspect"
                    , "--key"
                    , "alice-1"
                    , "--registry"
                    , dir </> "none"
                    , "--blueprint"
                    , dir </> "none.json"
                    , "--koios-url"
                    , "http://127.0.0.1:1/api/v1"
                    , "--network-magic"
                    , "1"
                    ]
                help = ["registry", "--help"]
                asked =
                    [ []
                    , ["--trace", "off"]
                    , ["--trace-to", "file:" <> (dir </> "missing" </> "t.jsonl")]
                    , ["--trace", "how", "--trace-to", "stderr"]
                    ]
            (_, open) <- openTempFile dir "stderr"
            -- baselines at the real composition: a local refusal and help, each
            -- writing no journal (the registry is missing; help prints usage).
            (refusedCode, refusedOut, _) <-
                captured (runPackagedWith (pure (Just open)) refused [])
            refusedCode `shouldBe` ExitFailure 10
            (helpCode, helpOut, _) <-
                captured (runPackagedWith (pure (Just open)) help [])
            helpCode `shouldBe` ExitSuccess
            hClose open
            closed <- closedHandle
            let broken :: IO (Maybe Handle)
                broken = throwIO (userError "the standard error is gone")
                faults :: [(String, IO (Maybe Handle))]
                faults =
                    [ ("probe", pure (Just closed))
                    , ("replacement", broken)
                    , ("both", broken)
                    ]
            forM_ asked $ \flags -> do
                forM_ faults $ \(name, getErrors) -> do
                    (code, out, _) <-
                        captured (runPackagedWith getErrors (refused <> flags) [])
                    (flags, name, code, out)
                        `shouldBe` (flags, name, refusedCode, refusedOut)
            forM_ faults $ \(name, getErrors) -> do
                (code, out, _) <- captured (runPackagedWith getErrors help [])
                (name, code, out) `shouldBe` (name, helpCode, helpOut)
    it "takes a standard error that is not a stream as closed" $
        withSystemTempDirectory "trace-not-a-stream" $ \dir -> do
            -- whether the entry point takes descriptor 2 as the process's standard error
            let probe = (== Just stderr) <$> standardError
            onFile <- redirecting stdError (dir </> "err") probe
            onDirectory <- bracket (openFd dir ReadOnly defaultFileFlags) closeFd $ \fd ->
                bracket
                    (dup stdError <* dupTo fd stdError)
                    (\saved -> dupTo saved stdError >> closeFd saved)
                    (const probe)
            (onFile, onDirectory) `shouldBe` (True, False)
    it
        "prints the same receipt and exits the same, and never writes the trace on stdout"
        $ withSystemTempDirectory "trace-entry"
        $ \dir -> do
            results <- mapM (run dir) (settings dir)
            let receipts = [(name, out, code) | (name, code, out, _, _) <- results]
            length (nub [(out, code) | (_, out, code) <- receipts]) `shouldBe` 1
            forM_ results $ \(name, code, out, err, saved) -> do
                code `shouldBe` ExitFailure 10
                saved `shouldBe` out
                (Aeson.decodeStrict out :: Maybe Aeson.Value) `shouldSatisfy` isJust
                (name, BS.null err)
                    `shouldBe` (name, not (narrates name))
    it
        "keeps its receipt and exit when a sink throws or writes to a closed handle"
        $ do
            (seen, collect) <- collector
            closed <- closedHandleSink
            let refusal = failWith ClientRefusal "no request is pending for this registry"
            plain <- captured (finish nullTracer "fold" Nothing refusal)
            tracer <-
                fanOut
                    [Tracer (\_ -> throwIO (userError "the sink broke")), closed, collect]
            traced <- captured (finish tracer "fold" Nothing refusal)
            traced `shouldBe` plain
            events <- readIORef seen
            [o | Trace [] (What (CommandEnded _ o _)) <- events]
                `shouldBe` ["client-refusal"]
    it "names the command and its outcome at the end of the stream" $ do
        (seen, collect) <- collector
        _ <-
            captured $
                finish
                    collect
                    "fold"
                    Nothing
                    (failWith ClientRefusal "nothing is pending")
        events <- readIORef seen
        [e | Trace [] (What e@(CommandEnded{})) <- events]
            `shouldSatisfy` \case
                [CommandEnded "fold" "client-refusal" ms] -> ms >= 0
                _ -> False
        fmap traceEvent (lastOf events) `shouldSatisfy` \case
            Just (What (CommandEnded{})) -> True
            _ -> False
  where
    narrates name = name `elem` [n | (n, _, True) <- settings ""]
    lastOf xs = if null xs then Nothing else Just (last xs)
    run dir (name, asked, _) = do
        let receiptPath = dir </> (name <> ".json")
        (code, out, err) <-
            captured $
                withTracing (Just stderr) False Nothing asked $ \tracer ->
                    finish
                        tracer
                        "fold"
                        (Just receiptPath)
                        (failWith ClientRefusal "no request is pending for this registry")
        saved <- BS.readFile receiptPath
        pure (name, code, out, err, saved)

-- ---------------------------------------------------------
-- Tracing setup re-cut: an enabled file sink at the packaged command
-- ---------------------------------------------------------

setupRecut :: Spec
setupRecut = describe "(#416) tracing setup re-cut" $ do
    it
        "opens no trace file for help, though a command at the same setting \
        \creates it"
        $ withSystemTempDirectory "trace-help-file"
        $ \dir -> do
            let target = dir </> "trace.jsonl"
                asked = ["--trace", "what", "--trace-to", "file:" <> target]
                help = ["registry", "--help"]
                refused =
                    [ "registry"
                    , "inspect"
                    , "--key"
                    , "alice-1"
                    , "--registry"
                    , dir </> "none"
                    , "--blueprint"
                    , dir </> "none.json"
                    , "--koios-url"
                    , "http://127.0.0.1:1/api/v1"
                    , "--network-magic"
                    , "1"
                    ]
            (_, open) <- openTempFile dir "stderr"
            (plainCode, plainOut, _) <-
                captured (runPackagedWith (pure (Just open)) help [])
            (code, out, _) <-
                captured (runPackagedWith (pure (Just open)) (help <> asked) [])
            (code, out) `shouldBe` (plainCode, plainOut)
            code `shouldBe` ExitSuccess
            BS.null out `shouldBe` False
            doesFileExist target `shouldReturn` False
            -- the same target is created by a command that reports anything
            (refusedCode, _, _) <-
                captured (runPackagedWith (pure (Just open)) (refused <> asked) [])
            hClose open
            refusedCode `shouldBe` ExitFailure 10
            doesFileExist target `shouldReturn` True

{- | Run an action with standard output and standard error redirected to
files, returning what it wrote to each.
-}
captured :: IO a -> IO (a, BS.ByteString, BS.ByteString)
captured act = withSystemTempDirectory "trace-captured" $ \dir -> do
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

-- ---------------------------------------------------------
-- The phase log's line kinds
-- ---------------------------------------------------------

{- | One event of every line kind the phase log has, with the key set of the
line its call site wrote at the base revision (#363): the expectation is the
pre-change log's, read from those call sites, not from the renderer. An event
that is not a phase-log line expects none.
-}
lineKinds :: [(Trace, Maybe [Text])]
lineKinds =
    [ query
        ( Read
            (Queried (Query "utxosAt" "node" Nothing 1.5 (Answered (Just 3))))
        )
        answered
    , query
        ( Read
            (Queried (Query "evaluateTx" "local" Nothing 1.5 (QueryFailed failure)))
        )
        failedQuery
    , query
        (Read (Queried (Query "indexAdmit" "node" Nothing 1.5 Lagged)))
        answered
    ,
        ( how'
            ( Read
                ( Queried
                    (Query "outputs" "Koios" (Just "koios-1") 1.5 (Answered (Just 2)))
                )
            )
        , Nothing
        )
    , query
        ( Backend
            ( Exchanged
                (Query "address_utxos" "Koios" (Just "koios-1") 1.5 (Answered Nothing))
            )
        )
        exchanged
    , query
        ( Backend
            ( Exchanged
                (Query "tx_info" "Koios" (Just "koios-1") 1.5 (QueryFailed failure))
            )
        )
        (exchanged <> ["error_class"])
    , line
        (Read (ViewOpened (NodeViewOpened 1.5 7 "ab" "Conway")))
        ["duration_ms", "era", "hash", "outcome", "phase", "slot", "ts"]
    , line
        (Read (ViewOpened (NodeViewFailed 1.5 failure)))
        ["duration_ms", "error_class", "outcome", "phase", "ts"]
    , line
        (Backend (BackendViewOpened (SessionViewOpened "koios-1" "Unbound")))
        ["binding", "phase", "session", "ts"]
    , line
        (Read (ViewReleased (NodeViewHeld 1.5)))
        ["held_ms", "phase", "ts"]
    , line
        (Backend (BackendViewReleased (SessionViewClosed "koios-1")))
        ["phase", "session", "ts"]
    , line
        (Read (Evaluated (Evaluation 1.5 2 0 10 20)))
        ["failed", "mem", "phase", "redeemers", "steps", "ts"]
    , line (Read (SessionOpened 1.5)) ["duration_ms", "phase", "ts"]
    , line
        (Read (HorizonWaited (wait (HorizonMoved 9 99))))
        (horizon <> ["observedHorizon", "observedTip"])
    , line
        (Read (HorizonWaited (wait (HorizonFailed failure))))
        (horizon <> ["error_class"])
    , line
        (Read (ValiditySelected (ValiditySelection 7 99 Nothing 8 50 50 2)))
        [ "effectiveLower"
        , "horizon"
        , "lower"
        , "minimumSlots"
        , "phase"
        , "tip"
        , "ts"
        , "upper"
        , "windowUpper"
        ]
    , line
        (Read (BodyBuilt (BodyBuild "bookEdgeMeasured" 1.5 BodyReady)))
        body
    , line
        (Read (BodyBuilt (BodyBuild "updatePayloadTx" 1.5 BodyRefused)))
        body
    , line
        ( Read
            (BodyBuilt (BodyBuild "updatePayloadTx" 1.5 (BodyFailed failure)))
        )
        (body <> ["error_class"])
    , line
        (Tx (TxBuilt "fold" 1.5 Done))
        ["duration_ms", "outcome", "phase", "step", "ts"]
    , line
        (Tx (TxBuilt "fold" 1.5 (FailedWith failure)))
        ["duration_ms", "error_class", "outcome", "phase", "step", "ts"]
    , line (Tx (TxSigned "fold" tx (Just 1) 1.5 Done)) signing
    , line
        (Tx (TxSigned "fold" tx Nothing 1.5 (FailedWith failure)))
        (signing <> ["error_class"])
    , line (Tx (submitted (TipSlot 7) Accepted)) submitting
    , line (Tx (submitted TipUnreadable LedgerRefusedIt)) submitting
    , line (Tx (submitted (TipSlot 7) ProviderFailed)) submitting
    , line (Tx (submitted (TipSlot 7) WrongNetwork)) submitting
    , line
        (Tx (submitted (TipSlot 7) (SubmitThrew failure)))
        (submitting <> ["error_class"])
    , line (Tx (TxConfirmed "fold" tx 1.5 Confirmed)) confirming
    , line (Tx (TxConfirmed "fold" tx 1.5 ConfirmTimedOut)) confirming
    , line
        (Tx (TxConfirmed "fold" tx 1.5 (ConfirmFailed failure)))
        confirming
    , line
        (Tx (TxConfirmed "fold" tx 1.5 (ConfirmThrew failure)))
        (confirming <> ["error_class"])
    , (how' (Tx (TxObserved "fold" tx 1.5)), Nothing)
    , (how' (Fetched (Fetch ["state"] "Koios" 1.5 Done)), Nothing)
    ]
  where
    how' = Trace [] . How
    line h keys = (how' h, Just keys)
    query = line
    failure = ErrorClass "IOException"
    tx = T.replicate 64 "a"
    answered = ["answer_size", "duration_ms", "outcome", "phase", "query", "ts"]
    failedQuery = ["duration_ms", "error_class", "outcome", "phase", "query", "ts"]
    exchanged = ["duration_ms", "outcome", "phase", "query", "session", "ts"]
    horizon =
        [ "duration_ms"
        , "horizon"
        , "lower"
        , "minimumSlots"
        , "outcome"
        , "phase"
        , "slotLimit"
        , "tip"
        , "ts"
        , "wallLimitMs"
        , "windowUpper"
        ]
    wait = HorizonWait 7 99 Nothing 50 2 60 20_000 1.5
    body = ["builder", "duration_ms", "outcome", "phase", "ts"]
    signing = ["duration_ms", "outcome", "phase", "step", "ts", "tx"]
    submitting =
        [ "duration_ms"
        , "outcome"
        , "phase"
        , "step"
        , "tip_slot"
        , "ts"
        , "tx"
        , "validity_lower"
        , "validity_upper"
        ]
    submitted tip = TxSubmitted "fold" tx (Just 1) (Just 9) tip 1.5
    confirming = ["duration_ms", "outcome", "phase", "step", "ts", "tx"]

phaseLogKeys :: Spec
phaseLogKeys = describe "the phase log's lines" $ do
    it
        "keeps every line kind's keys as the call sites before the typed stream wrote them"
        $ withSystemTempDirectory "phase-keys"
        $ \dir ->
            forM_ (zip [0 :: Int ..] lineKinds) $ \(n, (event, expected)) -> do
                let path = dir </> (show n <> ".jsonl")
                traceWith (phaseLogSink path) event
                there <- doesFileExist path
                keys <-
                    if there
                        then do
                            raw <- BS.readFile path
                            case Aeson.decodeStrict raw of
                                Just (Aeson.Object o) -> pure (Just (sort (map Key.toText (KeyMap.keys o))))
                                _ -> fail ("not one JSON object: " <> show raw)
                        else pure Nothing
                (event, keys) `shouldBe` (event, sort <$> expected)
    it
        "has a line kind for every constructor the provider and transaction events declare"
        $ do
            let covered =
                    Map.fromListWith
                        Set.union
                        [ (ty, Set.singleton c)
                        | (e, _) <- lineKinds
                        , (ty, c, _) <- constructorsIn e
                        ]
                declared =
                    Map.fromList
                        [ (ty, Set.fromList cs)
                        | (e, _) <- lineKinds
                        , (ty, _, cs) <- constructorsIn e
                        ]
                mechanics =
                    [ ty
                    | ty <- Map.keys declared
                    , ty
                        `notElem` [ "Singular.CLI.Trace.Trace"
                                  , "Singular.CLI.Trace.Event"
                                  , "Singular.CLI.Trace.Scope"
                                  ]
                    ]
            mechanics `shouldSatisfy` (> 10) . length
            [(ty, Map.lookup ty covered) | ty <- mechanics]
                `shouldBe` [(ty, Map.lookup ty declared) | ty <- mechanics]

-- | A sink writing to a handle that is already closed.
closedHandleSink :: IO (Tracer IO Trace)
closedHandleSink = do
    (path, h) <- openTempFile "/tmp" "closed-sink"
    hClose h
    removeFile path
    pure (Tracer (hPrint h))

-- | A handle that is already closed: every write to it throws.
closedHandle :: IO Handle
closedHandle = do
    (path, h) <- openTempFile "/tmp" "closed-stderr"
    hClose h
    removeFile path
    pure h
