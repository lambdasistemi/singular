{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.ClosedModeSpec
Description : The closed mode of the open-datum executable
License     : Apache-2.0

Create chooses a registry's mode with the closed switch and every later
command follows the registry's mode read from the chain, refusing an
update on a closed registry before anything is built or signed.
-}
module Singular.Application.OpenDatum.ClosedModeSpec (spec) where

import Control.Exception
    ( AsyncException (..)
    , SomeException
    , bracket
    , fromException
    , throwIO
    , try
    )
import Control.Tracer (nullTracer)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , dup
    , dupTo
    , openFd
    , stdOutput
    )
import System.Posix.Types (Fd)
import Test.Hspec

import Data.Aeson qualified as Aeson
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Out (addrTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )

import Singular.Application.OpenDatum.Command
    ( CLIError (..)
    , OpenDatumCommand (..)
    , ProviderSettings (..)
    , closedSwitch
    , openDatumHelp
    , parseOpenDatumCommand
    )
import Singular.Application.OpenDatum.Run
    ( ModeRefusal (..)
    , closedUpdateRefusal
    , modeOfRecordedPolicy
    , registryMode
    , runOpenDatum
    )
import Singular.Application.OpenDatum.StateTokenFixture qualified as Fixture
import Singular.Application.OpenDatum.Value
    ( Mode (..)
    , applicationIn
    , closedDatumApplication
    , modeTitle
    , openDatumApplication
    )
import Singular.CLI.Command qualified as RegistryCLI
import Singular.CLI.Session (Env (..))
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    )
import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StateToken (Release (..), resolveRegistry)
import Singular.Registry.StubSession (servingSession, stubSession)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture qualified as Booking
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , emptyRoot
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Types
    ( OnChainRoot (..)
    , OnChainTokenState
    , stateAppPolicyBytes
    )
import Singular.Registry.WaitTypes (WaitFailure (..), WaitStage (..))
import Singular.Registry.Wallet (bech32Address)

spec :: Spec
spec = do
    switchAtCreateOnly
    createPinsMode
    closedCreateRefusals
    modeReadFromChain
    cancellationPropagates
    unreadableNotGuessed
    laterCommandsFollow
    loaderDecidesCode
    updateRefusal

-- ---------------------------------------------------------
-- Shared pieces
-- ---------------------------------------------------------

providerArgs :: [String]
providerArgs =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

walletArgs :: [String]
walletArgs = ["--wallet-skey", "/keys/payment.skey"]

createBase :: [String]
createBase = ["--state-dir", "/srv/reg", "--blueprint", "/srv/plutus.json"]

fixtureTokenSpelling :: String
fixtureTokenSpelling =
    let (PolicyID policy, AssetName name) = Fixture.token
    in  T.unpack (TE.decodeUtf8 (B16.encode (scriptHashBytes policy)))
            <> "."
            <> T.unpack (TE.decodeUtf8 (B16.encode (SBS.fromShort name)))

regArgs :: [String]
regArgs = createBase <> ["--state-token", fixtureTokenSpelling]

seedText :: String
seedText = replicate 64 'b' <> "#1"

previewAddrOf :: ByteString -> String
previewAddrOf h = bech32Address (addrFromKeyHashBytes Testnet h)

-- ---------------------------------------------------------
-- L1
-- ---------------------------------------------------------

switchAtCreateOnly :: Spec
switchAtCreateOnly = describe "the closed switch at create only" $ do
    it "parses create --closed as a closed create" $ do
        closedSwitch `shouldBe` "--closed"
        case parseOpenDatumCommand
            ( ["open-datum", "create", "--seed", seedText, "--closed"]
                <> createBase
                <> providerArgs
                <> walletArgs
            ) of
            Right (OpenCreate Closed _) -> pure ()
            other ->
                expectationFailure
                    ("create --closed did not parse closed: " <> show other)
    it "parses create --closed with --preview as closed" $ do
        let addrText = previewAddrOf (BS.replicate 28 0x5a)
        case parseOpenDatumCommand
            ( ["open-datum", "create", "--preview", "--closed"]
                <> createBase
                <> [ "--koios-url"
                   , "http://127.0.0.1:8080/api/v1"
                   , "--network-magic"
                   , "42"
                   ]
                <> ["--wallet-address", addrText]
            ) of
            Right (OpenCreate Closed _) -> pure ()
            other ->
                expectationFailure
                    ("create --closed --preview did not parse closed: " <> show other)
    it "parses create without the switch as open" $ do
        case parseOpenDatumCommand
            ( ["open-datum", "create", "--seed", seedText]
                <> createBase
                <> providerArgs
                <> walletArgs
            ) of
            Right (OpenCreate Open _) -> pure ()
            other ->
                expectationFailure ("plain create did not parse open: " <> show other)
    it "refuses --closed on every other command by name" $ do
        let cases =
                [ ["open-datum", "insert", "--key", "k", "--payload", "/p.json"]
                    <> regArgs
                    <> providerArgs
                    <> walletArgs
                , ["open-datum", "update", "--key", "k", "--payload", "/p.json"]
                    <> regArgs
                    <> providerArgs
                    <> walletArgs
                , ["open-datum", "terminate", "--key", "k"]
                    <> regArgs
                    <> providerArgs
                    <> walletArgs
                , ["open-datum", "fold"] <> regArgs <> providerArgs <> walletArgs
                , ["open-datum", "inspect", "--key", "k"] <> regArgs <> providerArgs
                ]
        mapM_
            ( \line -> case parseOpenDatumCommand (line <> ["--closed"]) of
                Left (BadValue "--closed" why) -> do
                    why `shouldSatisfy` isInfixOf "chosen at create"
                    why `shouldSatisfy` isInfixOf "read from the chain"
                other ->
                    expectationFailure
                        ("--closed off create was not refused by name: " <> show other)
            )
            cases
    it "reads a key whose text is --closed as a key" $ do
        case parseOpenDatumCommand
            ( ["open-datum", "insert", "--key", "--closed", "--payload", "/p.json"]
                <> regArgs
                <> providerArgs
                <> walletArgs
            ) of
            Right (OpenInsert _) -> pure ()
            other ->
                expectationFailure ("--key --closed was not a key: " <> show other)
    it "leaves singular's parser refusing --closed as unknown" $ do
        case RegistryCLI.parseCommand
            [ "registry"
            , "fold"
            , "--blueprint"
            , "b"
            , "--state-token"
            , fixtureTokenSpelling
            , "--koios-url"
            , "u"
            , "--network-magic"
            , "1"
            , "--wallet-skey"
            , "k"
            , "--closed"
            ] of
            Left (RegistryCLI.BadValue "--closed" why) ->
                why `shouldSatisfy` isInfixOf "is not a flag singular reads"
            other -> expectationFailure ("singular accepted --closed: " <> show other)
    it "names --closed on the create help only" $ do
        openDatumHelp ["create"] `shouldSatisfy` isInfixOf "--closed"
        mapM_
            ( \verb ->
                openDatumHelp [verb] `shouldNotSatisfy` isInfixOf "--closed"
            )
            ["insert", "update", "terminate", "fold", "inspect"]

createPinsMode :: Spec
createPinsMode = describe "create pins the mode it names" $ do
    it "titles differ and the closed value differs in the pin alone" $ do
        modeTitle Open `shouldNotBe` modeTitle Closed
        modeTitle Closed `shouldBe` "open_datum.closed_datum"
        modeTitle Open `shouldBe` "open_datum.open_datum"
        appPin (applicationIn Closed)
            `shouldBe` PinByScript "open_datum.closed_datum"
        appPin (applicationIn Open)
            `shouldBe` PinByScript "open_datum.open_datum"
        appPin openDatumApplication
            `shouldBe` PinByScript "open_datum.open_datum"
        appPin closedDatumApplication
            `shouldBe` PinByScript "open_datum.closed_datum"
    it "create asks the loader for the mode's title" $ do
        asked <- newIORef []
        let env =
                testEnv
                    (\t -> modifyIORef' asked (<> [t]))
                    (chainWith stateClosed)
                    True
        case parseOpenDatumCommand
            ( ["open-datum", "create", "--seed", seedText, "--closed"]
                <> createBase
                <> providerArgs
                <> walletArgs
            ) of
            Right cmd@(OpenCreate Closed _) -> do
                _ <- capturedRun env cmd
                titles <- readIORef asked
                titles `shouldSatisfy` elem "open_datum.closed_datum"
            other -> expectationFailure ("closed create did not parse: " <> show other)
        asked2 <- newIORef []
        let env2 =
                testEnv
                    (\t -> modifyIORef' asked2 (<> [t]))
                    (chainWith stateOpen)
                    True
        case parseOpenDatumCommand
            ( ["open-datum", "create", "--seed", seedText]
                <> createBase
                <> providerArgs
                <> walletArgs
            ) of
            Right cmd@(OpenCreate Open _) -> do
                _ <- capturedRun env2 cmd
                titles <- readIORef asked2
                titles `shouldSatisfy` elem "open_datum.open_datum"
                titles `shouldSatisfy` notElem "open_datum.closed_datum"
            other -> expectationFailure ("open create did not parse: " <> show other)

closedCreateRefusals :: Spec
closedCreateRefusals = describe "a closed create passes every refusal an open create does" $ do
    it "gives the same refusal with --closed for every create misuse" $ do
        let addrText = previewAddrOf (BS.replicate 28 0x5a)
            base =
                ["open-datum", "create", "--seed", seedText]
                    <> createBase
                    <> providerArgs
                    <> walletArgs
            misuses =
                [ ["--fund-input", "abc#0"]
                , ["--max-outlay", "100"]
                , ["--request", "abc#0"]
                , ["--fold"]
                , ["--state-token", fixtureTokenSpelling]
                , ["--outputs-at", addrText]
                , ["--wallet-address", addrText]
                , ["--process-time", "0"]
                , ["--retract-time", "lots"]
                ]
        mapM_
            ( \extra -> do
                let openLine = base <> extra
                    closedLine = ["open-datum", "create", "--closed"] <> drop 2 base <> extra
                case (parseOpenDatumCommand openLine, parseOpenDatumCommand closedLine) of
                    (Left openErr, Left closedErr) -> closedErr `shouldBe` openErr
                    (openRes, closedRes) ->
                        expectationFailure
                            ( "create misuse was not refused on both paths: "
                                <> show extra
                                <> " open="
                                <> show openRes
                                <> " closed="
                                <> show closedRes
                            )
            )
            misuses

-- ---------------------------------------------------------
-- Toy releases whose application programs differ per title
-- ---------------------------------------------------------

openAppProg :: SBS.ShortByteString
openAppProg = applyBytesParam (BS.replicate 32 0x61) Booking.program

closedAppProg :: SBS.ShortByteString
closedAppProg = applyBytesParam (BS.replicate 32 0x62) Booking.program

thirdAppProg :: SBS.ShortByteString
thirdAppProg = applyBytesParam (BS.replicate 32 0x63) Booking.program

toyRelease :: SBS.ShortByteString -> Release
toyRelease appProg =
    Release
        { releaseState = releaseState Fixture.release
        , releaseRequest = releaseRequest Fixture.release
        , releaseCodes = (releaseCodes Fixture.release){ncApplication = appProg}
        }

releaseOpen :: Release
releaseOpen = toyRelease openAppProg

releaseClosed :: Release
releaseClosed = toyRelease closedAppProg

releaseThird :: Release
releaseThird = toyRelease thirdAppProg

econ :: RegistryEconomics
econ =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

cfgOpen :: CageConfig
cfgClosed :: CageConfig
cfgThird :: CageConfig
(cfgOpen, _) =
    configForApplication
        (appPin (applicationIn Open))
        (releaseCodes releaseOpen)
        (releaseState releaseOpen)
        (releaseRequest releaseOpen)
        econ
        Testnet
        (txInToRef Fixture.seedIn)
(cfgClosed, _) =
    configForApplication
        (appPin (applicationIn Closed))
        (releaseCodes releaseClosed)
        (releaseState releaseClosed)
        (releaseRequest releaseClosed)
        econ
        Testnet
        (txInToRef Fixture.seedIn)
(cfgThird, _) =
    configForApplication
        (appPin (applicationIn Open))
        (releaseCodes releaseThird)
        (releaseState releaseThird)
        (releaseRequest releaseThird)
        econ
        Testnet
        (txInToRef Fixture.seedIn)

stateOpen :: OnChainTokenState
stateClosed :: OnChainTokenState
stateThird :: OnChainTokenState
stateOpen = bootStateFromCfg cfgOpen (OnChainRoot emptyRoot)
stateClosed = bootStateFromCfg cfgClosed (OnChainRoot emptyRoot)
stateThird = bootStateFromCfg cfgThird (OnChainRoot emptyRoot)

openPolicy :: ByteString
closedPolicy :: ByteString
thirdPolicy :: ByteString
openPolicy = stateAppPolicyBytes stateOpen
closedPolicy = stateAppPolicyBytes stateClosed
thirdPolicy = stateAppPolicyBytes stateThird

-- ---------------------------------------------------------
-- Chains
-- ---------------------------------------------------------

chainWith :: OnChainTokenState -> Fixture.Chain
chainWith st =
    Fixture.honestChain
        { Fixture.chainOutputs =
            Map.singleton Fixture.stateIn (Fixture.stateOutput st)
        }

chainMissing :: Fixture.Chain
chainMissing =
    Fixture.honestChain
        { Fixture.chainOutputs = Map.empty
        }

-- ---------------------------------------------------------
-- L2 pure
-- ---------------------------------------------------------

modeReadFromChain :: Spec
modeReadFromChain = describe "the mode read from the chain" $ do
    it "reads a closed datum as closed" $ do
        openPolicy `shouldNotBe` closedPolicy
        modeOfRecordedPolicy closedPolicy openPolicy (Just closedPolicy)
            `shouldBe` Right Closed
    it "reads an open datum as open" $ do
        modeOfRecordedPolicy openPolicy openPolicy (Just closedPolicy)
            `shouldBe` Right Open
    it "reads an open registry with an older blueprint as open" $ do
        modeOfRecordedPolicy openPolicy openPolicy Nothing
            `shouldBe` Right Open

cancellationPropagates :: Spec
cancellationPropagates = describe "a cancelled closed load propagates" $ do
    it "propagates a user interrupt raised on the closed title only" $ do
        asked <- newIORef []
        let env =
                interruptEnv
                    (\t -> modifyIORef' asked (<> [t]))
                    (chainWith stateClosed)
        withTempWallet $ \wkey -> withTempPayload $ \payload -> withTempDir $ \root -> do
            let args =
                    ["open-datum", "insert", "--key", "k", "--payload", payload]
                        <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                        <> ["--state-token", fixtureTokenSpelling]
                        <> providerArgs
                        <> ["--wallet-skey", wkey]
            cmd <- either (fail . show) pure (parseOpenDatumCommand args)
            res <-
                try (capturedRun env cmd)
                    :: IO (Either SomeException (ExitCode, BS.ByteString))
            case res of
                Left e -> case (fromException e :: Maybe AsyncException) of
                    Just ThreadKilled -> pure ()
                    _ ->
                        expectationFailure
                            ("closed interrupt was not ThreadKilled: " <> show e)
                Right (code, _) ->
                    expectationFailure
                        ("interrupted dispatch returned instead of throwing: " <> show code)
            titles <- readIORef asked
            titles `shouldSatisfy` elem "open_datum.closed_datum"
            drop 2 titles `shouldBe` []
    it "propagates a bounded-wait failure raised on the closed title only" $ do
        asked <- newIORef []
        let env =
                waitFailEnv
                    (\t -> modifyIORef' asked (<> [t]))
                    (chainWith stateClosed)
        withTempWallet $ \wkey -> withTempPayload $ \payload -> withTempDir $ \root -> do
            let args =
                    ["open-datum", "insert", "--key", "k", "--payload", payload]
                        <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                        <> ["--state-token", fixtureTokenSpelling]
                        <> providerArgs
                        <> ["--wallet-skey", wkey]
            cmd <- either (fail . show) pure (parseOpenDatumCommand args)
            res <-
                try (capturedRun env cmd)
                    :: IO (Either SomeException (ExitCode, BS.ByteString))
            case res of
                Left e -> case fromException e of
                    Just (_ :: WaitFailure) -> pure ()
                    _ ->
                        expectationFailure
                            ("closed wait failure was not WaitFailure: " <> show e)
                Right (code, _) ->
                    expectationFailure
                        ("wait-failed dispatch returned instead of throwing: " <> show code)
            titles <- readIORef asked
            titles `shouldSatisfy` elem "open_datum.closed_datum"
            drop 2 titles `shouldBe` []

unreadableNotGuessed :: Spec
unreadableNotGuessed = describe "an unreadable mode is not guessed" $ do
    it "refuses a neither-hash as unrecognised" $ do
        thirdPolicy `shouldNotBe` openPolicy
        thirdPolicy `shouldNotBe` closedPolicy
        modeOfRecordedPolicy thirdPolicy openPolicy (Just closedPolicy)
            `shouldSatisfy` isUnrecognised
    it "reads the mode from the chain for closed and open" $ do
        let prov = ProviderSettings "http://127.0.0.1:8080/api/v1" 42 Nothing Nothing
        asked <- newIORef []
        let envC =
                testEnv
                    (\t -> modifyIORef' asked (<> [t]))
                    (chainWith stateClosed)
                    True
        registryMode envC prov "/srv/plutus.json" Fixture.token
            >>= (`shouldBe` Right Closed)
        asked2 <- newIORef []
        let envO =
                testEnv
                    (\t -> modifyIORef' asked2 (<> [t]))
                    (chainWith stateOpen)
                    True
        registryMode envO prov "/srv/plutus.json" Fixture.token
            >>= (`shouldBe` Right Open)
    it "reads an open registry with a blueprint without the closed title" $ do
        let prov = ProviderSettings "http://127.0.0.1:8080/api/v1" 42 Nothing Nothing
        asked <- newIORef []
        let envO =
                testEnv
                    (\t -> modifyIORef' asked (<> [t]))
                    (chainWith stateOpen)
                    False
        registryMode envO prov "/srv/plutus.json" Fixture.token
            >>= (`shouldBe` Right Open)
        titles <- readIORef asked
        titles `shouldSatisfy` elem "open_datum.open_datum"
    it
        "a neither-hash insert ends in its own refusal with no closed load after the read"
        $ do
            asked <- newIORef []
            let env =
                    testEnv
                        (\t -> modifyIORef' asked (<> [t]))
                        (chainWith stateThird)
                        True
            withTempPayload $ \payload -> withTempDir $ \root -> do
                let base =
                        ["open-datum", "insert", "--key", "k", "--payload", payload]
                            <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                            <> ["--state-token", fixtureTokenSpelling]
                            <> providerArgs
                -- submit with a missing key: the pin refusal comes first, not a key failure
                cmd <-
                    either
                        (fail . show)
                        pure
                        ( parseOpenDatumCommand
                            (base <> ["--wallet-skey", "/does/not/exist.skey"])
                        )
                (code, out) <- capturedRun env cmd
                code `shouldBe` ExitFailure 10
                out `shouldSatisfy` BC.isInfixOf "registry-pin-mismatch application"
                out `shouldSatisfy` (not . BC.isInfixOf "does/not/exist")
                titles <- readIORef asked
                drop 2 titles `shouldSatisfy` notElem "open_datum.closed_datum"
                -- preview names the same refusal and never asks for the closed code after the read
                askedP <- newIORef []
                let envP =
                        testEnv
                            (\t -> modifyIORef' askedP (<> [t]))
                            (chainWith stateThird)
                            True
                    addrText = previewAddrOf (BS.replicate 28 0x5a)
                cmdP <-
                    either
                        (fail . show)
                        pure
                        ( parseOpenDatumCommand
                            (base <> ["--preview", "--wallet-address", addrText])
                        )
                (codeP, outP) <- capturedRun envP cmdP
                codeP `shouldBe` ExitFailure 10
                outP `shouldSatisfy` BC.isInfixOf "registry-pin-mismatch application"
                titlesP <- readIORef askedP
                drop 2 titlesP `shouldSatisfy` notElem "open_datum.closed_datum"
    it
        "a missing-state insert ends in the state refusal with no closed load after the read"
        $ do
            asked <- newIORef []
            let env = testEnv (\t -> modifyIORef' asked (<> [t])) chainMissing True
            withTempPayload $ \payload -> withTempDir $ \root -> do
                let base =
                        ["open-datum", "insert", "--key", "k", "--payload", payload]
                            <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                            <> ["--state-token", fixtureTokenSpelling]
                            <> providerArgs
                cmd <-
                    either
                        (fail . show)
                        pure
                        ( parseOpenDatumCommand
                            (base <> ["--wallet-skey", "/does/not/exist.skey"])
                        )
                (code, out) <- capturedRun env cmd
                code `shouldBe` ExitFailure 10
                out `shouldSatisfy` BC.isInfixOf "state-output-missing"
                out `shouldSatisfy` (not . BC.isInfixOf "does/not/exist")
                out
                    `shouldSatisfy` (not . BC.isInfixOf "registry-pin-mismatch application")
                titles <- readIORef asked
                drop 2 titles `shouldSatisfy` notElem "open_datum.closed_datum"
                askedP <- newIORef []
                let envP = testEnv (\t -> modifyIORef' askedP (<> [t])) chainMissing True
                    addrText = previewAddrOf (BS.replicate 28 0x5a)
                cmdP <-
                    either
                        (fail . show)
                        pure
                        ( parseOpenDatumCommand
                            (base <> ["--preview", "--wallet-address", addrText])
                        )
                (codeP, outP) <- capturedRun envP cmdP
                codeP `shouldBe` ExitFailure 10
                outP `shouldSatisfy` BC.isInfixOf "state-output-missing"
                titlesP <- readIORef askedP
                drop 2 titlesP `shouldSatisfy` notElem "open_datum.closed_datum"

laterCommandsFollow :: Spec
laterCommandsFollow = describe "later commands follow the registry" $ do
    it
        "insert on a closed registry asks for the closed code only after the read"
        $ do
            asked <- newIORef []
            let env =
                    testEnv
                        (\t -> modifyIORef' asked (<> [t]))
                        (chainWith stateClosed)
                        True
            withTempWallet $ \wkey -> withTempPayload $ \payload -> withTempDir $ \root -> do
                let args =
                        ["open-datum", "insert", "--key", "k", "--payload", payload]
                            <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                            <> ["--state-token", fixtureTokenSpelling]
                            <> providerArgs
                            <> ["--wallet-skey", wkey]
                cmd <- either (fail . show) pure (parseOpenDatumCommand args)
                (code, out) <- capturedRun env cmd
                code `shouldBe` ExitFailure 10
                out `shouldSatisfy` BC.isInfixOf "reference-missing"
                out
                    `shouldSatisfy` (not . BC.isInfixOf "registry-pin-mismatch application")
                titles <- readIORef asked
                drop 2 titles `shouldSatisfy` (not . null)
                drop 2 titles `shouldSatisfy` all (== "open_datum.closed_datum")
    it
        "insert on an open registry asks for the open code only after the read"
        $ do
            asked <- newIORef []
            let env =
                    testEnv (\t -> modifyIORef' asked (<> [t])) (chainWith stateOpen) True
            withTempWallet $ \wkey -> withTempPayload $ \payload -> withTempDir $ \root -> do
                let args =
                        ["open-datum", "insert", "--key", "k", "--payload", payload]
                            <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                            <> ["--state-token", fixtureTokenSpelling]
                            <> providerArgs
                            <> ["--wallet-skey", wkey]
                cmd <- either (fail . show) pure (parseOpenDatumCommand args)
                (code, out) <- capturedRun env cmd
                code `shouldBe` ExitFailure 10
                out `shouldSatisfy` BC.isInfixOf "reference-missing"
                out
                    `shouldSatisfy` (not . BC.isInfixOf "registry-pin-mismatch application")
                titles <- readIORef asked
                drop 2 titles `shouldSatisfy` (not . null)
                drop 2 titles `shouldSatisfy` all (== "open_datum.open_datum")
    it "terminate, fold and inspect follow the mode's code after the read" $ do
        let followOnce chain expectedTitle argsFor expectedRefusal expectedCode = do
                asked <- newIORef []
                let env = testEnv (\t -> modifyIORef' asked (<> [t])) chain True
                withTempWallet $ \wkey -> withTempDir $ \root -> do
                    args <- argsFor wkey root
                    cmd <- either (fail . show) pure (parseOpenDatumCommand args)
                    (code, out) <- capturedRun env cmd
                    code `shouldBe` expectedCode
                    out `shouldSatisfy` BC.isInfixOf expectedRefusal
                    out
                        `shouldSatisfy` (not . BC.isInfixOf "registry-pin-mismatch application")
                    titles <- readIORef asked
                    drop 2 titles `shouldSatisfy` (not . null)
                    drop 2 titles `shouldSatisfy` all (== expectedTitle)
            termArgs wkey root =
                pure
                    ( ["open-datum", "terminate", "--key", "k"]
                        <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                        <> ["--state-token", fixtureTokenSpelling]
                        <> providerArgs
                        <> ["--wallet-skey", wkey]
                    )
            foldArgs wkey root =
                pure
                    ( ["open-datum", "fold"]
                        <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                        <> ["--state-token", fixtureTokenSpelling]
                        <> providerArgs
                        <> ["--wallet-skey", wkey]
                    )
            inspectArgs _wkey root =
                pure
                    ( ["open-datum", "inspect", "--key", "k"]
                        <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                        <> ["--state-token", fixtureTokenSpelling]
                        <> providerArgs
                    )
        followOnce
            (chainWith stateClosed)
            "open_datum.closed_datum"
            termArgs
            "reference-missing"
            (ExitFailure 10)
        followOnce
            (chainWith stateOpen)
            "open_datum.open_datum"
            termArgs
            "reference-missing"
            (ExitFailure 10)
        followOnce
            (chainWith stateClosed)
            "open_datum.closed_datum"
            foldArgs
            "reference-missing"
            (ExitFailure 10)
        followOnce
            (chainWith stateOpen)
            "open_datum.open_datum"
            foldArgs
            "reference-missing"
            (ExitFailure 10)
        followOnce
            (chainWith stateClosed)
            "open_datum.closed_datum"
            inspectArgs
            "TrieState"
            (ExitFailure 10)
        followOnce
            (chainWith stateOpen)
            "open_datum.open_datum"
            inspectArgs
            "TrieState"
            (ExitFailure 10)

loaderDecidesCode :: Spec
loaderDecidesCode = describe "the loader decides the code" $ do
    it "resolves a closed registry through the open-titled value" $ do
        let sess = sessionFor (chainWith stateClosed)
        res <-
            resolveRegistry openDatumApplication releaseClosed Fixture.token sess
        case res of
            Right _ -> pure ()
            Left err ->
                expectationFailure
                    ("closed resolve through open value refused: " <> show err)

updateRefusal :: Spec
updateRefusal = describe "an update on a closed registry stops before building" $ do
    it "refuses update on closed with exit 10 and no key read" $ do
        asked <- newIORef []
        let env =
                testEnv
                    (\t -> modifyIORef' asked (<> [t]))
                    (chainWith stateClosed)
                    True
        withTempPayload $ \payload -> withTempDir $ \root -> do
            let base =
                    ["open-datum", "update", "--key", "k", "--payload", payload]
                        <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                        <> ["--state-token", fixtureTokenSpelling]
                        <> providerArgs
            -- submit with a missing key: the closed refusal comes first, not a key failure
            cmd <-
                either
                    (fail . show)
                    pure
                    ( parseOpenDatumCommand
                        (base <> ["--wallet-skey", "/does/not/exist.skey"])
                    )
            (code, out) <- capturedRun env cmd
            code `shouldBe` ExitFailure 10
            out `shouldSatisfy` BC.isInfixOf "closed"
            out `shouldSatisfy` BC.isInfixOf (BC.pack fixtureTokenSpelling)
            out `shouldSatisfy` (not . BC.isInfixOf "does/not/exist")
            let msg = closedUpdateRefusal Fixture.token
            msg `shouldSatisfy` isInfixOf "closed"
            msg `shouldSatisfy` isInfixOf fixtureTokenSpelling
            -- preview names the same refusal with the same exit
            askedP <- newIORef []
            let envP =
                    testEnv
                        (\t -> modifyIORef' askedP (<> [t]))
                        (chainWith stateClosed)
                        True
                addrText = previewAddrOf (BS.replicate 28 0x5a)
            cmdP <-
                either
                    (fail . show)
                    pure
                    ( parseOpenDatumCommand
                        (base <> ["--preview", "--wallet-address", addrText])
                    )
            (codeP, outP) <- capturedRun envP cmdP
            codeP `shouldBe` ExitFailure 10
            outP `shouldSatisfy` BC.isInfixOf "closed"
            outP `shouldSatisfy` BC.isInfixOf (BC.pack fixtureTokenSpelling)
    it
        "does not refuse an update on an open registry with the closed message"
        $ do
            let env = testEnv (\_ -> pure ()) (chainWith stateOpen) True
            withTempPayload $ \payload -> withTempDir $ \root -> do
                let args =
                        ["open-datum", "update", "--key", "k", "--payload", payload]
                            <> ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
                            <> ["--state-token", fixtureTokenSpelling]
                            <> providerArgs
                            <> ["--wallet-skey", "/does/not/exist.skey"]
                cmd <- either (fail . show) pure (parseOpenDatumCommand args)
                (_, out) <- capturedRun env cmd
                out
                    `shouldSatisfy` (not . BC.isInfixOf (BC.pack (closedUpdateRefusal Fixture.token)))

isUnrecognised :: Either ModeRefusal Mode -> Bool
isUnrecognised = \case
    Left (UnrecognisedPolicy _) -> True
    _ -> False

-- ---------------------------------------------------------
-- Helpers (one recording cell only)
-- ---------------------------------------------------------

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "closed-mode"

withTempWallet :: (FilePath -> IO a) -> IO a
withTempWallet use = withSystemTempDirectory "closed-wallet" $ \dir -> do
    let path = dir </> "payment.skey"
    BS.writeFile path (B16.encode (BS.replicate 32 0x77))
    use path

withTempPayload :: (FilePath -> IO a) -> IO a
withTempPayload use = withSystemTempDirectory "closed-payload" $ \dir -> do
    let path = dir </> "payload.json"
    Aeson.encodeFile path (7 :: Int)
    use path

sessionFor :: Fixture.Chain -> LP.Session NoWitness IO
sessionFor chain =
    (stubSessionFor chain)
        { LP.sessionNetwork = Fixture.chainNetwork chain
        }

stubSessionFor :: Fixture.Chain -> LP.Session NoWitness IO
stubSessionFor chain =
    stubSession
        { LP.sessionNetwork = Fixture.chainNetwork chain
        , LP.outputs = pure . fmap (`Evidenced` Nothing) . select
        , LP.mintRecord = \a ->
            pure
                (Right (Evidenced (Map.lookup a (Fixture.chainMints chain)) Nothing))
        , LP.networkTime = pure (Right (Evidenced syntheticTime Nothing))
        }
  where
    live = Fixture.chainOutputs chain
    select = \case
        LP.AtAddress addr ->
            Right [u | u@(_, o) <- Map.toAscList live, o ^. addrTxOutL == addr]
        LP.HoldingAsset (pol, nm) ->
            Right [u | u@(_, o) <- Map.toAscList live, holds pol nm o]
        LP.AtTxIn ref -> case Map.lookup ref live of
            Nothing -> Left (LP.MissingOutput ref)
            Just o -> Right [(ref, o)]
        LP.CarryingReferenceScript _ -> Right []
        LP.AnyOf _ -> Right (Map.toAscList live)
        LP.AllOf _ -> Right (Map.toAscList live)
    holds pol nm o =
        let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
        in  maybe False ((/= 0) . Map.findWithDefault 0 nm) (Map.lookup pol m)

testEnv :: (Text -> IO ()) -> Fixture.Chain -> Bool -> Env
testEnv record chain hasClosed =
    Env
        { envTracer = nullTracer
        , envSource = "test"
        , envLoadRelease = \app _ -> do
            let title = case appPin app of
                    PinByScript t -> t
                    PinAsCompiled t -> t
                    PinByHash h -> TE.decodeUtf8 (B16.encode (SBS.fromShort h))
                    PinFromState -> "from-state"
            record title
            case title of
                "open_datum.open_datum" -> pure (Right releaseOpen)
                "open_datum.closed_datum"
                    | hasClosed -> pure (Right releaseClosed)
                    | otherwise ->
                        pure (Left "the blueprint carries no open_datum.closed_datum")
                _ -> pure (Left ("the blueprint carries no " <> T.unpack title))
        , envReads = \_ k -> k caps
        , envWrites = \_ k -> k caps
        }
  where
    sess = sessionFor chain
    (net, prov) = servingSession sess
    caps =
        Capabilities
            { capReads = (net, prov)
            , capSubmit = \_ -> pure (LP.SubmitFailed "test has no submitter")
            , capConfirm = \_ -> pure ()
            , capFacts = pure []
            , capTrace = pure []
            }

-- | A loader that raises `ThreadKilled` on the closed title only.
interruptEnv :: (Text -> IO ()) -> Fixture.Chain -> Env
interruptEnv record chain =
    (testEnv record chain True)
        { envLoadRelease = \app _ -> do
            let title = case appPin app of
                    PinByScript t -> t
                    _ -> "other"
            record title
            case title of
                "open_datum.closed_datum" -> throwIO ThreadKilled
                "open_datum.open_datum" -> pure (Right releaseOpen)
                _ -> pure (Left ("the blueprint carries no " <> T.unpack title))
        }

-- | A loader that raises a bounded-wait failure on the closed title only.
waitFailEnv :: (Text -> IO ()) -> Fixture.Chain -> Env
waitFailEnv record chain =
    (testEnv record chain True)
        { envLoadRelease = \app _ -> do
            let title = case appPin app of
                    PinByScript t -> t
                    _ -> "other"
            record title
            case title of
                "open_datum.closed_datum" ->
                    throwIO
                        ( WaitFailure
                            { waitStage = SubmissionWait
                            , waitTxId = Fixture.creationTx
                            , waitElapsed = 0
                            , waitBound = 1
                            , waitClosedAt = Nothing
                            }
                        )
                "open_datum.open_datum" -> pure (Right releaseOpen)
                _ -> pure (Left ("the blueprint carries no " <> T.unpack title))
        }

capturedRun :: Env -> OpenDatumCommand -> IO (ExitCode, BS.ByteString)
capturedRun env cmd = withSystemTempDirectory "closed-captured" $ \dir -> do
    let outPath = dir </> "stdout"
    code <- redirecting stdOutput outPath (runOpenDatum env cmd)
    (,) code <$> BS.readFile outPath

redirecting :: Fd -> FilePath -> IO a -> IO a
redirecting target path act =
    bracket
        ( do
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
            _ <- dupTo saved target
            closeFd saved
        )
        (const act)
