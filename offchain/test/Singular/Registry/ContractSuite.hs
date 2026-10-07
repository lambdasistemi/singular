{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Registry.ContractSuite
Description : The shipping raw-session contract and uncovered legacy requirements
License     : Apache-2.0

The eleven original node/indexer requirements keep their exact wording.
Their retired atomic-view and named-node promises are published as unsupported,
never passed under weaker session semantics. Separate cases exercise the
generic provider through this existing harness.

Outputs are compared in full against an independent source at run time.
Acquisition identities and raw no-witness facts do not establish a snapshot.
The computed result writer records actual execution, unsupported reasons and
the checked-out revision. A test-adapter is synthetic; a devnet is private.
Neither evidence class names a public-chain acceptance.
-}
module Singular.Registry.ContractSuite
    ( AdapterHarness (..)
    , Chain (..)
    , EvidenceClass (..)
    , renderEvidence
    , Case (..)
    , CaseKind (..)
    , caseKind
    , caseText
    , retiredCases
    , contractSuite
    , unsupportedControl
    ) where

import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , displayException
    , throwIO
    , try
    )
import Control.Monad (forM_, unless, void)
import Data.Aeson (encode, object, (.=))
import Data.Bits (xor)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isHexDigit, toLower)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.LedgerProvider
    ( AcquireFailure (..)
    , Acquisition (..)
    , ChainPoint (..)
    , HistoryFailure (..)
    , HistoryRange (..)
    , LedgerProvider (..)
    , Network (..)
    , OutputQuery (..)
    , Outputs
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.SessionIO qualified as Services

-- | Where the run was executed; neither constructor claims public-chain evidence.
data EvidenceClass = TestAdapter | DevNet
    deriving stock (Eq, Show, Enum, Bounded)

renderEvidence :: EvidenceClass -> String
renderEvidence = \case
    TestAdapter -> "test-adapter"
    DevNet -> "devnet"

data CaseKind = Success | Refusal | Consistency
    deriving stock (Eq, Show)

-- | Original cases retain their identifiers and wording; generic cases are distinct.
data Case
    = ViewNamesPoint
    | ReadsAnswer
    | OnePoint
    | ChangeUnseen
    | OutOfScope
    | ConnectionLost
    | AtOrigin
    | IndexLag
    | IndexFork
    | IndexRestoring
    | IndexDisconnected
    | SessionNamesNetwork
    | SessionReadsAnswer
    | SessionChangeObserved
    | SessionReleased
    | SessionWrongNetwork
    | SessionPointUnsupported
    deriving stock (Eq, Ord, Show, Enum, Bounded)

caseKind :: Case -> CaseKind
caseKind = \case
    ViewNamesPoint -> Success
    ReadsAnswer -> Success
    OnePoint -> Consistency
    ChangeUnseen -> Consistency
    SessionNamesNetwork -> Success
    SessionReadsAnswer -> Success
    SessionChangeObserved -> Consistency
    _ -> Refusal

caseText :: Case -> String
caseText = \case
    ViewNamesPoint ->
        "a view names the network, era, slot and block hash it was acquired at"
    ReadsAnswer ->
        "a view answers its reads: outputs at an address, script \
        \registration, time to slot"
    OnePoint ->
        "every read inside one view is answered at the view's chain point \
        \(slot and block hash) while the chain moves on"
    ChangeUnseen ->
        "a chain change between two reads is not observed inside the view; \
        \a fresh view sees it"
    OutOfScope -> "a view used after its scope fails as ViewOutOfScope"
    ConnectionLost ->
        "a connection lost inside a view fails its next read and the next \
        \acquisition as ViewConnectionLost"
    AtOrigin -> "acquiring at the chain origin fails as AcquiredAtOrigin"
    IndexLag -> "an index behind the node's point refuses the view as lag"
    IndexFork ->
        "an index holding another block at the node's slot refuses the view \
        \as fork"
    IndexRestoring -> "an index still restoring refuses the view as restoring"
    IndexDisconnected ->
        "an index whose upstream is disconnected refuses the view as \
        \disconnected"
    SessionNamesNetwork ->
        "a fresh session names its requested network and a distinct opaque identity, with Unbound evidence"
    SessionReadsAnswer ->
        "a session answers full outputs and exact references against an independent source, registration and time rounding without a witness"
    SessionChangeObserved ->
        "fresh acquisitions observe changed full outputs against an independent source, without claiming an atomic view"
    SessionReleased ->
        "every raw read and common time conversion after release refuses as ReleasedSession for that session"
    SessionWrongNetwork ->
        "acquisition on another network refuses as WrongNetwork before the session action"
    SessionPointUnsupported ->
        "an exact-point acquisition refuses as PointNotSupported before the session action"

-- | Mandatory uncovered rows for the removed API, independent of harness support.
retiredCases :: Map Case String
retiredCases =
    Map.fromList
        [ (requirement, reason requirement)
        | requirement <- [ViewNamesPoint .. IndexDisconnected]
        ]
  where
    reason = \case
        ViewNamesPoint -> unbound
        ReadsAnswer ->
            "The old view API is retired. Generic raw-session reads are exercised separately; no view or atomic-point promise is inherited."
        OnePoint -> unbound
        ChangeUnseen -> unbound
        OutOfScope ->
            "ViewOutOfScope is retired with the view API. ReleasedSession is a distinct generic requirement."
        ConnectionLost ->
            "ViewConnectionLost is retired with the node connection. HTTP and raw-read failures retain their own outcomes."
        AtOrigin ->
            "AcquiredAtOrigin is retired with the node adapter; the HTTP route makes no node-origin promise."
        _ ->
            "The node/indexer adapter and its named index admission outcomes are retired; there is no replacement index."
    unbound =
        "This provider supplies Unbound raw sessions, not an atomic network/era/slot/block-hash view."

-- | Fresh source and independent observation for each executable case.
data Chain = Chain
    { chProvider :: LedgerProvider NoWitness IO
    , chNetwork :: Network
    , chWatched :: Addr
    , chUnregistered :: ScriptHash
    , chChange :: IO ()
    -- ^ Change watched outputs and return once the independent source observes it.
    , chIndependentOutputs :: IO Outputs
    -- ^ Full source outputs read independently of chProvider.
    }

data AdapterHarness = AdapterHarness
    { ahAdapter :: String
    , ahEvidence :: EvidenceClass
    , ahNotSupported :: Map Case String
    , ahChain :: forall a. (Chain -> IO a) -> IO a
    }

unsupportedControl :: String -> IO a
unsupportedControl what =
    throwIO . ErrorCall $
        "contract suite: " <> what <> " is not supported by this harness"

-- | The existing case list computes every supported/unsupported/failed result.
contractSuite :: AdapterHarness -> Spec
contractSuite h =
    describe
        ( ahAdapter h
            <> " adapter [evidence: "
            <> renderEvidence (ahEvidence h)
            <> "]"
        )
        $ mapM_ one [minBound .. maxBound]
  where
    one c =
        it (show (caseKind c) <> ": " <> caseText c) $
            case Map.lookup c (Map.union retiredCases (ahNotSupported h)) of
                Just reason -> do
                    record h c "not-supported" (Just reason)
                    pendingWith
                        ("not supported by the " <> ahAdapter h <> " adapter: " <> reason)
                Nothing -> do
                    outcome <-
                        try $
                            timeout caseBound (ahChain h (run c))
                                >>= maybe
                                    (expectationFailure "the case did not end within five minutes")
                                    pure
                    case outcome of
                        Right () -> record h c "passed" Nothing
                        Left (e :: SomeException) -> do
                            record h c "failed" (Just (displayException e))
                            throwIO e

{- | Append one case's result on one adapter to the results file named by
@CONTRACT_RESULTS@, one JSON object per line, when the variable is set:
the adapter, its evidence class, the case, its kind and requirement, the
outcome and its reason, and the code revision the run checked out with
whether its tree was clean. The published evidence page is computed from
these lines. A revision or tree state that cannot be read fails the case
and writes nothing: it is never recorded as a value.
-}
record :: AdapterHarness -> Case -> String -> Maybe String -> IO ()
record h c outcome reason =
    lookupEnv "CONTRACT_RESULTS" >>= \case
        Nothing -> pure ()
        Just path -> do
            base <- git ["rev-parse", "HEAD"]
            unless (length base == 40 && all isHexDigit base) $
                unreadable ("git rev-parse HEAD printed " <> show base)
            status <- git ["status", "--porcelain"]
            BSL.appendFile path . (<> "\n") . encode . object $
                [ "base" .= base
                , "dirty" .= not (null status)
                , "adapter" .= ahAdapter h
                , "evidence" .= renderEvidence (ahEvidence h)
                , "case" .= show c
                , "kind" .= map toLower (show (caseKind c))
                , "requirement" .= caseText c
                , "outcome" .= outcome
                ]
                    <> maybe [] (\r -> ["reason" .= r]) reason
  where
    git args = do
        (code, out, err) <- readProcessWithExitCode "git" args ""
        case code of
            ExitSuccess -> pure (filter (/= '\n') out)
            ExitFailure n ->
                unreadable
                    ( unwords ("git" : args)
                        <> " failed with exit "
                        <> show n
                        <> ": "
                        <> err
                    )
    unreadable why =
        throwIO . ErrorCall $
            "contract results: the run's revision or tree state cannot be read, \
            \so no result is written: "
                <> why

run :: Case -> Chain -> Expectation
run c ch = case c of
    SessionNamesNetwork -> do
        first <- inScope ch $ \session -> do
            sessionNetwork session `shouldBe` chNetwork ch
            sessionBinding session `shouldBe` Unbound
            let SessionId identity = sessionId session
            T.null identity `shouldBe` False
            pure (sessionId session)
        second <- inScope ch (pure . sessionId)
        second `shouldNotBe` first
    SessionReadsAnswer -> do
        chChange ch
        expected <- chIndependentOutputs ch
        expected `shouldSatisfy` (not . null)
        ms <- nowMs
        inScope ch $ \session -> do
            fact <-
                outputs session (AtAddress (chWatched ch)) >>= either throwIO pure
            value fact `shouldBe` expected
            void (witness fact) `shouldBe` Nothing
            forM_ expected $ \pair@(reference, _) -> do
                found <- outputs session (AtTxIn reference) >>= either throwIO pure
                value found `shouldBe` [pair]
                void (witness found) `shouldBe` Nothing
            registered <-
                scriptRegistered session (chUnregistered ch) >>= either throwIO pure
            value registered `shouldBe` False
            void (witness registered) `shouldBe` Nothing
            time <- networkTime session >>= either throwIO pure
            void (witness time) `shouldBe` Nothing
            floorSlot <- Services.floorSlot session ms
            ceilSlot <- Services.ceilingSlot session ms
            floorSlot `shouldSatisfy` (<= ceilSlot)
            Services.slotStart session floorSlot >>= (`shouldSatisfy` (<= ms))
            Services.slotStart session ceilSlot >>= (`shouldSatisfy` (>= ms))
    SessionChangeObserved -> do
        chChange ch
        firstExpected <- chIndependentOutputs ch
        first <- inScope ch (`Services.outputsAt` chWatched ch)
        first `shouldBe` firstExpected
        chChange ch
        secondExpected <- chIndependentOutputs ch
        second <- inScope ch (`Services.outputsAt` chWatched ch)
        second `shouldBe` secondExpected
        second `shouldNotBe` first
    SessionReleased -> do
        chChange ch
        expected <- chIndependentOutputs ch
        reference <- case expected of
            (found, _) : _ -> pure found
            [] ->
                fail "the independent source has no output for the release control"
        escaped <- inScope ch pure
        let failure = ReleasedSession (sessionId escaped)
            refused action = fmap void action `shouldReturn` Left failure
            asset = (PolicyID (chUnregistered ch), AssetName mempty)
            address = AtAddress (chWatched ch)
        forM_
            [ address
            , AtTxIn reference
            , HoldingAsset asset
            , AnyOf (address :| [AtTxIn reference])
            , AllOf (address :| [AtTxIn reference])
            ]
            (refused . outputs escaped)
        refused (protocolParameters escaped)
        refused (tipObservation escaped)
        refused (networkTime escaped)
        refused (scriptRegistered escaped (chUnregistered ch))
        fmap
            void
            (history escaped asset (HistoryRange Nothing Nothing))
            `shouldReturn` Left (HistoryReadFailure failure)
        try @ReadFailure (Services.floorSlot escaped 5_000)
            `shouldReturn` Left failure
    SessionWrongNetwork -> do
        let configured@(Network magic) = chNetwork ch
            wanted = Network (magic `xor` 1)
        ran <- newIORef False
        result <-
            acquire (chProvider ch) (Latest wanted) (\_ -> writeIORef ran True)
        result `shouldBe` Left (WrongNetwork configured wanted)
        readIORef ran `shouldReturn` False
    SessionPointUnsupported -> do
        ran <- newIORef False
        result <-
            acquire
                (chProvider ch)
                (AtPoint (chNetwork ch) Genesis)
                (\_ -> writeIORef ran True)
        result `shouldBe` Left (PointNotSupported Genesis)
        readIORef ran `shouldReturn` False
    _ -> unsupportedControl (caseText c)

inScope :: Chain -> (Session NoWitness IO -> IO a) -> IO a
inScope ch = Services.withLatest (chNetwork ch, chProvider ch)

nowMs :: IO Integer
nowMs = floor . (* 1_000) <$> getPOSIXTime

-- | Original whole-case bound, generated actor startup included.
caseBound :: Int
caseBound = 300_000_000
