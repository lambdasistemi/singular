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
import Control.Exception (bracket)
import Control.Monad (forM_, replicateM)
import Control.Tracer (Tracer (..), traceWith)
import Data.Aeson qualified as Aeson
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
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hFlush, stderr, stdout)
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
    entryPoint

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
                            ( \c ->
                                ( c
                                , TraceRequest
                                    (Just level)
                                    [ToStderr, ToFile "/tmp/trace.jsonl"]
                                    (Just JsonFormat)
                                )
                            )
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
                        ( \c ->
                            (c, TraceRequest Nothing [ToFile "/a", ToFile "/b"] (Just TextFormat))
                        )
                        plain
                parseInvocation [] args
                    `shouldBe` fmap (\c -> (c, noTraceRequest)) plain
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
            let asked sinks format = TraceRequest (Just TraceHow) sinks format
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
    howEvent = Trace [] (How (Tx (TxObserved "fold" (T.replicate 64 "b"))))
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
        (How (Read (Evaluated (Evaluation 3 0 1_240_000 439_000_000))))
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
    , Trace tx (How (Tx (TxObserved "fold" foldTx)))
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
                       , "      how  evaluate 3 scripts ✓ (mem 1.24M, steps 439M)"
                       , "      how  build fold ................................................... 0.6s"
                       , "      how  sign 9a51d7e4…, fee 0.889465 tADA ............................ 0.1s"
                       , "      how  submit tx 9a51d7e4… at tip slot 135588101 .................... 0.4s"
                       , "      how  confirm tx 9a51d7e4… ........................................ 17.4s"
                       , "      how  observe tx 9a51d7e4…"
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
                , (Aeson.decodeStrict (BC.init line) :: Maybe Aeson.Object) /= Nothing
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
                [ pure TipNotRead
                , TipSlot . fromIntegral <$> genWord
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
            <*> elements [Confirmed, ConfirmTimedOut, ConfirmFailed]
        , TxObserved <$> genText <*> genHex
        ]

genRead :: Gen ReadEvent
genRead =
    oneof
        [ Queried <$> genQuery
        , ViewOpened <$> genOpening
        , ViewReleased <$> genRelease
        , Evaluated
            <$> ( Evaluation
                    <$> chooseInt (0, 9)
                    <*> chooseInt (0, 9)
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                )
        , SessionOpened <$> genMs
        , HorizonWaited
            <$> ( HorizonWait
                    <$> (fromIntegral <$> genWord)
                    <*> (fromIntegral <$> genWord)
                    <*> genMaybe (fromIntegral <$> genWord)
                    <*> (fromIntegral <$> genWord)
                    <*> chooseInteger (0, 999)
                    <*> chooseInteger (0, 2 ^ (40 :: Int))
                    <*> chooseInteger (0, 99_999)
                    <*> genMs
                    <*> oneof
                        [ HorizonMoved
                            <$> (fromIntegral <$> genWord)
                            <*> (fromIntegral <$> genWord)
                        , HorizonFailed <$> genClass
                        ]
                )
        , ValiditySelected
            <$> ( ValiditySelection
                    <$> (fromIntegral <$> genWord)
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
                    [outputSink TraceHow (Output (ToFile path) JsonFormat), collect]
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
                sink = outputSink TraceHow (Output (ToFile path) JsonFormat)
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
                        TraceHow
                        (Output (ToFile (dir </> "missing" </> "trace.jsonl")) JsonFormat)
                    , outputSink TraceHow (Output (ToFile dir) JsonFormat)
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
                withTracing False Nothing asked $ \tracer ->
                    finish
                        tracer
                        "fold"
                        (Just receiptPath)
                        (failWith ClientRefusal "no request is pending for this registry")
        saved <- BS.readFile receiptPath
        pure (name, code, out, err, saved)

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
