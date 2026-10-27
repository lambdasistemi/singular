{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PinGateSpec
Description : Submit checks the registry named by a bundle before sending it
License     : Apache-2.0

Retained library pin-form checks and the submit command are exercised against a
chain fixture. A legacy registry is prepared through the shared create helper
still used by application commands; no retired Singular parser route is invoked. This
establishes submit's pin and pre-send refusals over the exercised fixtures,
not a new-line registry reader or ledger acceptance.
-}
module Singular.CLI.PinGateSpec (spec) where

import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
    ( ToJSON (toJSON)
    , Value (Array)
    , decodeStrict
    )
import Data.ByteString qualified as BS
    ( ByteString
    , readFile
    , replicate
    , writeFile
    )
import Data.ByteString.Short qualified as SBS (toShort)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map (map)
import Data.Text (Text)
import Data.Text qualified as T (isInfixOf, pack, unpack)
import Lens.Micro ((&), (.~))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.CLI.Command
    ( ApplicationPolicy (..)
    , CreateArgs (..)
    , EntryMode (..)
    , ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.CommandRunSpec
    ( Rig (rigBlueprint, rigChain, rigDir, rigKey, rigWallet)
    , capabilities
    , captured
    , envOf
    , outcomeOf
    , readWallet
    , scriptPinned
    , textAt
    , valueAt
    , withRig
    )
import Singular.CLI.Create (createApplication, runCreate)
import Singular.CLI.FlagGroup (Signer (..))
import Singular.CLI.Registry (economics, loadReleaseCodes)
import Singular.CLI.Root (runPackagedVia)
import Singular.CLI.Session (Env (..))
import Singular.CLI.SubmitSpec (selfPaymentFiles)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Bundle
    ( Bundle (..)
    , decodeBundle
    , encodeBundle
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider qualified as Cage
    ( LedgerProvider (acquire)
    , Session (inclusion)
    )
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , rawChainProvider
    )
import Singular.Registry.SessionIO qualified as SessionIO
    ( withLatest
    )
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , PinField (..)
    , parseStateToken
    , resolveRegistry
    )
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , mkInlineDatum
    , toPlcData
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    )
import Singular.Registry.Wallet (Wallet (walletSignKey))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = describe "retained pin library and submit" $ formRows >> submitRows

-- ---------------------------------------------------------------------------
-- The registries and the forgery
-- ---------------------------------------------------------------------------

-- | A seed the rig's wallet funds: the first six outputs of the chain.
seedAt :: Int -> String
seedAt n = replicate 64 'f' <> "#" <> show n

-- | The application policy a create gives as a hash.
foreignPolicy :: BS.ByteString
foreignPolicy = BS.replicate 28 0xee

{- | A registry created by the retained create helper over the neutral value with
the application policy given as a hash. Its token, as a person passes it.
-}
createdByHash :: Rig -> String -> String -> IO String
createdByHash rig dir seed = do
    let args =
            CreateArgs
                { createStateDir = Just (rigDir rig </> dir)
                , createBlueprint = rigBlueprint rig
                , createMode =
                    Submit
                        ( WriteSettings
                            (ProviderSettings "http://fixture.invalid" 42 Nothing Nothing)
                            (SignerKeyFile (rigKey rig))
                            Nothing
                        )
                , createSeed = Just seed
                , createPreview = False
                , createReceipt = Nothing
                , createSaveStateTokenTo = Nothing
                , createProcessTime = reProcessTime economics
                , createRetractTime = reRetractTime economics
                }
    effective <-
        createApplication
            neutralApplication
            (Just (ApplicationPolicy (SBS.toShort (BS.replicate 28 7))))
    receipt <- runCreate effective (envOf rig) args
    maybe
        (fail "create fixture has no token")
        (pure . T.unpack)
        (textAt "stateToken" receipt)

-- | Rewrite the registry state datum while preserving the fixture transaction history.
forgeState :: Rig -> (OnChainTokenState -> OnChainTokenState) -> IO ()
forgeState rig change = advanceChain (rigChain rig) $ \facts ->
    facts{csUTxO = Map.map forgeOutput (csUTxO facts)}
  where
    forgeOutput out = case extractCageDatum out of
        Just (StateDatum st) ->
            out
                & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum (change st)))
        _ -> out

forgeActive :: OnChainTokenState -> OnChainTokenState
forgeActive st = st{stateActivePolicy = BuiltinByteString foreignPolicy}

standing :: Text
standing = "not-checked-against-any-blueprint"

-- | How many objects of a receipt carry the field: once, never zero or twice.
namingBundle
    :: Rig -> FilePath -> Maybe String -> Text -> IO (FilePath, FilePath)
namingBundle rig dir token command = do
    held <- readWallet rig
    output <- case held of
        o : _ -> pure o
        [] -> fail "the rig's wallet holds nothing to submit from"
    createDirectoryIfMissing True dir
    (path, witness) <-
        selfPaymentFiles dir (walletSignKey (rigWallet rig)) output
    bytes <- BS.readFile path
    bundle <- either (fail . show) pure (decodeBundle bytes)
    BS.writeFile
        path
        ( encodeBundle
            bundle
                { bundleStateToken = T.pack <$> token
                , bundleCommand = command
                }
        )
    pure (path, witness)

{- | What an instrumented run observed of the provider: how many transactions
it sent, how many views of the chain it acquired, and how many times it asked
where a transaction of the bundle sits.
-}
data Probe = Probe
    { probeSends :: IO Int
    , probeAcquisitions :: IO Int
    , probeInclusionReads :: IO Int
    }

{- | An environment over the rig's chain that counts every transaction it
sends, every view it acquires and every read of where a transaction sits, so
a refusal can show that nothing was sent and the bundle's transactions were
never looked for.
-}
probedEnv :: Rig -> IO (Env, Probe)
probedEnv rig = do
    sent <- newIORef (0 :: Int)
    acquired <- newIORef (0 :: Int)
    looked <- newIORef (0 :: Int)
    let base = capabilities rig
        (network, provider) = capReads base
        probed =
            provider
                { Cage.acquire = \requested action -> do
                    modifyIORef' acquired (+ 1)
                    Cage.acquire provider requested $ \session ->
                        action
                            session
                                { Cage.inclusion = \ids -> do
                                    modifyIORef' looked (+ 1)
                                    Cage.inclusion session ids
                                }
                }
        counting :: Capabilities NoWitness IO
        counting =
            base
                { capReads = (network, probed)
                , capSubmit = \tx -> do
                    modifyIORef' sent (+ 1)
                    capSubmit base tx
                }
    pure
        ( (envOf rig)
            { envReads = \_ k -> k counting
            , envWrites = \_ k -> k counting
            }
        , Probe (readIORef sent) (readIORef acquired) (readIORef looked)
        )

{- | One submit command run as the packaged command runs it: the settings the
environment gives, the command line, and the receipt it printed.
-}
submitWith
    :: Env -> [(String, String)] -> [String] -> IO (ExitCode, Aeson.Value)
submitWith env environment arguments = do
    (code, out, _) <-
        captured
            ( runPackagedVia
                (const env)
                neutralApplication
                (pure Nothing)
                ( arguments
                    <> ["--koios-url", "http://fixture.invalid", "--network-magic", "42"]
                )
                environment
            )
    receipt <-
        maybe
            (fail ("submit printed no receipt: " <> show out))
            pure
            (Aeson.decodeStrict out)
    pure (code, receipt)

-- | The release given the way a person gives it besides the flag: the variable.
releaseFrom :: Rig -> [(String, String)]
releaseFrom rig = [("SINGULAR_BLUEPRINT", rigBlueprint rig)]

{- | The refusal a bundle naming a registry whose pins differ is given: a client
refusal naming the pinned field, with no transaction sent, no view of the chain
acquired for the bundle's transactions, and none looked for.
-}
expectForgedBundleRefused
    :: Probe -> (ExitCode, Aeson.Value) -> Expectation
expectForgedBundleRefused probe (code, receipt) = do
    code `shouldBe` ExitFailure 10
    outcomeOf receipt `shouldBe` Just "client-refusal"
    textAt "cause" receipt `shouldBe` Just "registry-pin-mismatch"
    textAt "reason" receipt
        `shouldSatisfy` maybe False (T.isInfixOf "registry-pin-mismatch active")
    valueAt "submissions" receipt
        `shouldBe` Just (Aeson.toJSON ([] :: [Int]))
    probeSends probe `shouldReturn` 0
    probeInclusionReads probe `shouldReturn` 0

{- | A bundle submitted and every transaction of it sent, once, and nothing
else: the receipt is a success listing one sent transaction.
-}
expectSubmitted :: Probe -> (ExitCode, Aeson.Value) -> Expectation
expectSubmitted probe (code, receipt) = do
    code `shouldBe` ExitSuccess
    outcomeOf receipt `shouldBe` Just "success"
    map (textAt "how") (submissionEntries receipt)
        `shouldBe` [Just "sent"]
    probeSends probe `shouldReturn` 1

-- | The transactions a submit receipt lists.
submissionEntries :: Aeson.Value -> [Aeson.Value]
submissionEntries receipt = case valueAt "submissions" receipt of
    Just (Aeson.Array entries) -> toList entries
    _ -> []

submitRows :: Spec
submitRows = do
    it
        "refuses a bundle naming a forged registry, the release given in the environment, before the first send"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            forgeState rig forgeActive
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "forged") (Just t) "registry fold"
            (env, probe) <- probedEnv rig
            ran <-
                submitWith
                    env
                    (releaseFrom rig)
                    ["submit", "--witnesses", witness, bundle]
            expectForgedBundleRefused probe ran
    it
        "refuses a bundle naming a forged registry, the release given with the blueprint flag, before the first send"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            forgeState rig forgeActive
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "forged") (Just t) "registry fold"
            (env, probe) <- probedEnv rig
            ran <-
                submitWith
                    env
                    []
                    [ "submit"
                    , "--witnesses"
                    , witness
                    , "--blueprint"
                    , rigBlueprint rig
                    , bundle
                    ]
            expectForgedBundleRefused probe ran
    it
        "submits a bundle naming an honest registry when the release is given in the environment"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "honest") (Just t) "registry fold"
            (env, probe) <- probedEnv rig
            ran <-
                submitWith
                    env
                    (releaseFrom rig)
                    ["submit", "--witnesses", witness, bundle]
            expectSubmitted probe ran
    it
        "submits a bundle naming an honest registry when the release is given with the blueprint flag, and says the application pin was not checked"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "honest") (Just t) "registry fold"
            (env, probe) <- probedEnv rig
            ran@(_, receipt) <-
                submitWith
                    env
                    []
                    [ "submit"
                    , "--witnesses"
                    , witness
                    , "--blueprint"
                    , rigBlueprint rig
                    , bundle
                    ]
            expectSubmitted probe ran
            textAt "applicationPin" receipt `shouldBe` Just standing
    it
        "refuses a bundle naming a registry when no release is given, before the chain is read"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "named") (Just t) "registry fold"
            (env, probe) <- probedEnv rig
            (code, receipt) <-
                submitWith env [] ["submit", "--witnesses", witness, bundle]
            code `shouldBe` ExitFailure 10
            outcomeOf receipt `shouldBe` Just "client-refusal"
            textAt "cause" receipt `shouldBe` Just "release-not-given"
            probeSends probe `shouldReturn` 0
            probeAcquisitions probe `shouldReturn` 0
    it
        "refuses a bundle that names no registry and is not a create bundle, before the chain is read"
        $ withRig
        $ \rig -> do
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "nameless") Nothing "registry fold"
            (env, probe) <- probedEnv rig
            (code, receipt) <-
                submitWith
                    env
                    (releaseFrom rig)
                    ["submit", "--witnesses", witness, bundle]
            code `shouldBe` ExitFailure 10
            outcomeOf receipt `shouldBe` Just "client-refusal"
            textAt "cause" receipt `shouldBe` Just "bundle-names-no-registry"
            probeSends probe `shouldReturn` 0
            probeAcquisitions probe `shouldReturn` 0
    it
        "submits a create bundle, which names no registry, without a release"
        $ withRig
        $ \rig -> do
            (bundle, witness) <-
                namingBundle rig (rigDir rig </> "create") Nothing "create"
            (env, probe) <- probedEnv rig
            ran <- submitWith env [] ["submit", "--witnesses", witness, bundle]
            expectSubmitted probe ran

gateRefusal
    :: Rig -> Application -> String -> IO (Maybe IdentityRefusal)
gateRefusal rig app tokenText = do
    release <-
        loadReleaseCodes app (rigBlueprint rig) >>= either fail pure
    asset <-
        either (fail . T.unpack) pure (parseStateToken (T.pack tokenText))
    resolved <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \view ->
            resolveRegistry app release asset view
    pure (either Just (const Nothing) resolved)

compiledPinned :: Application
compiledPinned = scriptPinned{appPin = PinAsCompiled "script-app.script-app"}

formRows :: Spec
formRows = do
    it "accepts each form's own registry" $ withRig $ \rig -> do
        byHash <- createdByHash rig "by-hash" (seedAt 1)
        seed2 <- freshSeed rig
        byScript <- createdByScript rig scriptPinned "by-script" seed2
        seed3 <- freshSeed rig
        byCompiled <- createdByScript rig compiledPinned "by-compiled" seed3
        gateRefusal
            rig
            (hashPinnedApplication (SBS.toShort givenPolicy))
            byHash
            `shouldReturn` Nothing
        gateRefusal rig scriptPinned byScript `shouldReturn` Nothing
        gateRefusal rig compiledPinned byCompiled `shouldReturn` Nothing
    it
        "refuses a registry pinning another policy, naming the application, in the script form"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            gateRefusal rig scriptPinned byHash
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses a registry pinning another policy, naming the application, in the hash form"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            gateRefusal
                rig
                (hashPinnedApplication (SBS.toShort foreignPolicy))
                byHash
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses a registry pinning another policy, naming the application, in the compiled form"
        $ withRig
        $ \rig -> do
            byScript <- createdByScript rig scriptPinned "by-script" (seedAt 1)
            gateRefusal rig compiledPinned byScript
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses a forged application pin in the hash form after the datum is rewritten"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            forgeState rig forgeApplication
            gateRefusal
                rig
                (hashPinnedApplication (SBS.toShort givenPolicy))
                byHash
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "still refuses a forged active policy whichever way the application is stated"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            forgeState rig forgeActive
            forM_
                [ hashPinnedApplication (SBS.toShort givenPolicy)
                , neutralApplication
                ]
                $ \app ->
                    gateRefusal rig app byHash
                        `shouldReturn` Just (RegistryPinMismatch PinActive)

-- ---------------------------------------------------------------------------
-- Each command over a registry whose active policy is forged
-- ---------------------------------------------------------------------------

{- | The commands of the table that name a registry and run with the neutral
value, each as a person types it after the registry's state token: the
label, and the words the command line is made of given the rig and the
token.
-}
forgeApplication :: OnChainTokenState -> OnChainTokenState
forgeApplication st = st{stateAppPolicy = BuiltinByteString foreignPolicy}

-- ---------------------------------------------------------------------------
-- The library: one forged application pin per pin form
-- ---------------------------------------------------------------------------

{- | The refusal the gate gives, or nothing when it accepts: the application
is composed the way a program composes it and the release loaded from the
blueprint for it.
-}
freshSeed :: Rig -> IO String
freshSeed rig = do
    held <- readWallet rig
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for another registry"

givenPolicy :: BS.ByteString
givenPolicy = BS.replicate 28 7

-- | A policy no application derives.

-- | The script-pinned library fixture uses the retained builder directly.
createdByScript :: Rig -> Application -> String -> String -> IO String
createdByScript rig app dir seed = do
    effective <- createApplication app Nothing
    receipt <-
        runCreate
            effective
            (envOf rig)
            CreateArgs
                { createStateDir = Just (rigDir rig </> dir)
                , createBlueprint = rigBlueprint rig
                , createMode =
                    Submit
                        ( WriteSettings
                            (ProviderSettings "http://fixture.invalid" 42 Nothing Nothing)
                            (SignerKeyFile (rigKey rig))
                            Nothing
                        )
                , createSeed = Just seed
                , createPreview = False
                , createReceipt = Nothing
                , createSaveStateTokenTo = Nothing
                , createProcessTime = reProcessTime economics
                , createRetractTime = reRetractTime economics
                }
    outcomeOf receipt `shouldBe` Just "success"
    maybe
        (fail "script fixture has no token")
        (pure . T.unpack)
        (textAt "stateToken" receipt)
