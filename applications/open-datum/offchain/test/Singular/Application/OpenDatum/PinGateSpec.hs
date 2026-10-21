{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.PinGateSpec
Description : open-datum answers nothing about a registry before its pinned policies are compared
License     : Apache-2.0

open-datum knows two derivations of the application pin, the open one and
the closed one, so it used to read the registry's mode from the state
datum before anything compared the datum with either. These rows run the
packaged commands over registries that are real in form and pin a forged
policy, on the stub chain the closed-mode suite uses, and state what Bob
sees: the pin that differs is named, the closed registry's own refusal is
not given before the comparison, and the first read of the state datum
comes after the registry's identity has been read.

The library rows give the gate the other two ways an application states
its pin, a hash and a compiled script, each over a registry whose
application pin it does not derive.
-}
module Singular.Application.OpenDatum.PinGateSpec (spec) where

import Control.Monad (forM_)
import Control.Tracer (Tracer (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Test.Hspec

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Application.OpenDatum.ClosedModeSpec
    ( capturedRun
    , chainWith
    , fixtureTokenSpelling
    , previewAddrOf
    , providerArgs
    , stateClosed
    , stateOpen
    , stateThird
    , testEnv
    , withTempDir
    , withTempPayload
    , withTempWallet
    )
import Singular.Application.OpenDatum.Command (parseOpenDatumCommand)
import Singular.Application.OpenDatum.StateTokenFixture qualified as Fixture
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace (Event (..), How (..), Trace (..))
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (bootStateFromCfg)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , PinField (..)
    , Release (..)
    , resolveRegistry
    )
import Singular.Registry.StubSession (servingSession)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.Internal (emptyRoot, txInToRef)
import Singular.Registry.Types
    ( OnChainRoot (..)
    , OnChainTokenState (..)
    )

spec :: Spec
spec = describe "The pin gate" $ do
    describe
        "the application pin is compared however the application states it"
        formRows
    describe
        "an open-datum command refuses a forged registry before it answers anything"
        commandRows
    describe
        "the state datum is read only after the registry's identity"
        readOrderRows

-- ---------------------------------------------------------------------------
-- Forged registries
-- ---------------------------------------------------------------------------

foreignPolicy :: BuiltinByteString
foreignPolicy = BuiltinByteString (BS.replicate 28 0xee)

forgeActive :: OnChainTokenState -> OnChainTokenState
forgeActive st = st{stateActivePolicy = foreignPolicy}

-- ---------------------------------------------------------------------------
-- The library: a hash and a compiled script
-- ---------------------------------------------------------------------------

economics :: RegistryEconomics
economics =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

{- | The datum a boot pinning the compiled script of the release (the
parameterless form) leaves.
-}
compiledState :: OnChainTokenState
compiledState =
    bootStateFromCfg
        ( fst
            ( configForApplication
                (PinAsCompiled "open_datum.open_datum")
                (releaseCodes Fixture.release)
                (releaseState Fixture.release)
                (releaseRequest Fixture.release)
                economics
                Testnet
                (txInToRef Fixture.seedIn)
            )
        )
        (OnChainRoot emptyRoot)

refusalOver
    :: Application -> OnChainTokenState -> IO (Maybe IdentityRefusal)
refusalOver app datum = do
    logRef <- newIORef []
    let chain =
            Fixture.honestChain
                { Fixture.chainOutputs =
                    Map.singleton Fixture.stateIn (Fixture.stateOutput datum)
                }
    resolved <-
        resolveRegistry
            app
            Fixture.release
            Fixture.token
            (Fixture.chainSession logRef chain)
    pure (either Just (const Nothing) resolved)

compiledApplication :: Application
compiledApplication =
    openDatumApplication{appPin = PinAsCompiled "open_datum.open_datum"}

formRows :: Spec
formRows = do
    it
        "accepts a registry whose application pin is the hash the application states"
        $ refusalOver
            (hashPinnedApplication (SBS.toShort (appBytes Fixture.bootState)))
            Fixture.bootState
            `shouldReturn` Nothing
    it
        "accepts a registry whose application pin is the compiled script the application states"
        $ refusalOver compiledApplication compiledState `shouldReturn` Nothing
    it
        "refuses, naming the application, a registry pinning another policy than the hash the application states"
        $ refusalOver
            (hashPinnedApplication (SBS.toShort (BS.replicate 28 0xdd)))
            Fixture.bootState
            `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses, naming the application, a registry pinning another policy than the compiled script the application states"
        $ refusalOver compiledApplication Fixture.bootState
            `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses, naming the application, a registry pinning another policy than the script applied to its identity"
        $ refusalOver openDatumApplication compiledState
            `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "does not compare the application pin of a program that cannot derive it"
        $ refusalOver neutralApplication Fixture.bootState
            `shouldReturn` Nothing
  where
    appBytes st = case stateAppPolicy st of
        BuiltinByteString b -> b

-- ---------------------------------------------------------------------------
-- Each command over a registry
-- ---------------------------------------------------------------------------

-- | The commands that name a registry, each as a person types it.
commandLines
    :: FilePath -> FilePath -> FilePath -> [(String, [String])]
commandLines wallet payload root =
    [
        ( "insert"
        , ["open-datum", "insert", "--key", "k", "--payload", payload]
            <> registry
            <> ["--wallet-skey", wallet]
        )
    ,
        ( "update"
        , ["open-datum", "update", "--key", "k", "--payload", payload]
            <> registry
            <> ["--wallet-skey", wallet]
        )
    ,
        ( "terminate"
        , ["open-datum", "terminate", "--key", "k"]
            <> registry
            <> ["--wallet-skey", wallet]
        )
    ,
        ( "fold"
        , ["open-datum", "fold"] <> registry <> ["--wallet-skey", wallet]
        )
    , ("inspect", ["open-datum", "inspect", "--key", "k"] <> registry)
    ,
        ( "update preview"
        , ["open-datum", "update", "--key", "k", "--payload", payload]
            <> registry
            <> [ "--preview"
               , "--wallet-address"
               , previewAddrOf (BS.replicate 28 0x5a)
               ]
        )
    ]
  where
    registry =
        ["--state-dir", root, "--blueprint", "/srv/plutus.json"]
            <> ["--state-token", fixtureTokenSpelling]
            <> providerArgs

{- | What a run of a command observed of the provider and of the command's own
trace: every read in order, every trace event, and how many transactions it
sent.
-}
data Observed = Observed
    { observedReads :: IO [Text]
    , observedEvents :: IO [Trace]
    , observedSends :: IO Int
    }

{- | A stub environment over a chain holding this datum, observed: the open and
closed titles resolve to the toy releases, every provider read is logged, every
trace event is kept and every submission is counted and refused.
-}
observedEnv :: OnChainTokenState -> IO (Env, Observed)
observedEnv datum = do
    reads' <- newIORef []
    events <- newIORef []
    sends <- newIORef (0 :: Int)
    let chain = chainWith datum
        session =
            (Fixture.chainSession reads' chain)
                { LP.networkTime = pure (Right (Evidenced syntheticTime Nothing))
                }
        (net, prov) = servingSession session
        caps :: Capabilities NoWitness IO
        caps =
            Capabilities
                { capReads = (net, prov)
                , capSubmit = \_ -> do
                    modifyIORef' sends (+ 1)
                    pure (LP.SubmitFailed "test has no submitter")
                , capConfirm = \_ -> pure ()
                , capFacts = pure []
                , capTrace = pure []
                }
        env =
            (testEnv (\_ -> pure ()) chain True)
                { envTracer = Tracer (\event -> modifyIORef' events (<> [event]))
                , envReads = \_ k -> k caps
                , envWrites = \_ k -> k caps
                }
    pure
        ( env
        , Observed (readIORef reads') (readIORef events) (readIORef sends)
        )

-- | What a command printed, how it ended and what it observed.
data Ran = Ran
    { ranCode :: ExitCode
    , ranReceipt :: Aeson.Value
    , ranObserved :: Observed
    }

-- | Run one command line over a chain holding this datum.
runOver :: OnChainTokenState -> String -> IO Ran
runOver datum label =
    withTempWallet $ \wallet -> withTempPayload $ \payload -> withTempDir $ \root -> do
        (env, observed) <- observedEnv datum
        args <-
            maybe
                (fail ("no such command " <> label))
                pure
                (lookup label (commandLines wallet payload root))
        command <- either (fail . show) pure (parseOpenDatumCommand args)
        (code, out) <- capturedRun env command
        receipt <-
            maybe
                (fail (label <> " printed no receipt: " <> BC.unpack out))
                pure
                (Aeson.decodeStrict out)
        pure (Ran code receipt observed)

-- | Fields only a resolved registry's content reaches a receipt through.
registryContent :: [Key.Key]
registryContent =
    [ "leaf"
    , "root"
    , "stateRoot"
    , "observedTip"
    , "applicationOutput"
    , "pendingRequests"
    , "registry"
    , "state"
    , "incompleteCreate"
    , "envelope"
    , "transactions"
    ]

receiptText :: Key.Key -> Aeson.Value -> Maybe Text
receiptText key = \case
    Aeson.Object o | Just (Aeson.String t) <- KeyMap.lookup key o -> Just t
    _ -> Nothing

-- | Whether a receipt carries this field at all.
receiptHas :: Key.Key -> Aeson.Value -> Bool
receiptHas key = \case
    Aeson.Object o -> KeyMap.member key o
    _ -> False

{- | The run was refused as a client refusal naming the pinned field, showed
nothing of the registry, built and sent no transaction, and gave no answer
about the registry's mode.
-}
expectRefusedNaming :: Text -> Ran -> Expectation
expectRefusedNaming field ran = do
    ranCode ran `shouldBe` ExitFailure 10
    receiptText "outcome" receipt `shouldBe` Just "client-refusal"
    receiptText "reason" receipt
        `shouldSatisfy` maybe False (T.isInfixOf ("registry-pin-mismatch " <> field))
    receiptText "reason" receipt
        `shouldSatisfy` maybe True (not . T.isInfixOf "is closed")
    forM_ registryContent $ \key ->
        receiptHas key receipt `shouldBe` False
    events <- observedEvents (ranObserved ran)
    [() | Trace _ (How (Tx _)) <- events] `shouldBe` []
    [() | Trace _ (How (Staged _ _)) <- events] `shouldBe` []
    observedSends (ranObserved ran) `shouldReturn` 0
  where
    receipt = ranReceipt ran

-- | Run each command over a chain holding this datum and hold it to this.
overDatum
    :: OnChainTokenState -> (String -> Ran -> Expectation) -> Spec
overDatum datum expectation =
    forM_ (map fst (commandLines "" "" "")) $ \label ->
        it ("for " <> label) $ runOver datum label >>= expectation label

commandRows :: Spec
commandRows = do
    describe "a closed registry whose active policy is forged" $
        overDatum (forgeActive stateClosed) $
            \_ -> expectRefusedNaming "active"
    describe "an open registry whose active policy is forged" $
        overDatum (forgeActive stateOpen) $
            \_ -> expectRefusedNaming "active"
    describe
        "a registry whose application pin is neither the open nor the closed derivation"
        $ overDatum stateThird
        $ \_ -> expectRefusedNaming "application"
    describe "an honest open registry goes on to the command's own work" $
        overDatum stateOpen $ \label ran -> do
            ranCode ran `shouldBe` ExitFailure 10
            receiptText "reason" (ranReceipt ran)
                `shouldSatisfy` maybe
                    False
                    (\reason -> not ("registry-pin-mismatch" `T.isInfixOf` reason))
            receiptText "reason" (ranReceipt ran)
                `shouldSatisfy` maybe False (T.isInfixOf (expectedOwnRefusal label))
    describe
        "an honest closed registry refuses an update with its own words"
        $ it "for update"
        $ do
            ran <- runOver stateClosed "update"
            ranCode ran `shouldBe` ExitFailure 10
            receiptText "reason" (ranReceipt ran)
                `shouldSatisfy` maybe False (T.isInfixOf "is closed")
            receiptText "reason" (ranReceipt ran)
                `shouldSatisfy` maybe True (not . T.isInfixOf "registry-pin-mismatch")
  where
    -- the first thing each command meets once the registry passed the gate:
    -- the stub chain publishes no reference scripts, so the writes name the
    -- missing one; a read goes on to the history, which the stub does not hold
    expectedOwnRefusal label
        | label == "inspect" = "TrieState"
        | otherwise = "reference-missing"

-- ---------------------------------------------------------------------------
-- The order of the reads
-- ---------------------------------------------------------------------------

-- | The read of the state output: who holds the token.
isStateRead :: Text -> Bool
isStateRead = T.isPrefixOf "HoldingAsset"

-- | The read of the registry's identity: the mint record of the token.
isIdentityRead :: Text -> Bool
isIdentityRead = T.isPrefixOf "mintRecord"

readOrderRows :: Spec
readOrderRows =
    forM_ (map fst (commandLines "" "" "")) $ \label ->
        it
            ("reads the registry's identity before the state output for " <> label)
            $ do
                ran <- runOver (forgeActive stateClosed) label
                reads' <- observedReads (ranObserved ran)
                let beforeState = takeWhile (not . isStateRead) reads'
                (any isStateRead reads', any isIdentityRead beforeState)
                    `shouldBe` (True, True)
