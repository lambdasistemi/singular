{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PinGateSpec
Description : Every command that names a registry compares its pinned policies first
License     : Apache-2.0

Mallory creates a registry that is real in form: a state token minted from
its seed, a state datum, the references the registry runs. She then pins a
policy of her own in the datum. Bob runs a command that names the registry.
Each row here runs a packaged command over such a registry, on the chain
fixture the command-run suite uses, and says what Bob sees:

* the registry is refused naming the pinned field, nothing of the registry
  is shown and no transaction is built;
* an application that knows its own script, however it states it, compares
  the application pin too;
* an honest registry works as before and says whether the application pin
  was compared with an application's blueprint;
* the report of an interrupted create, submit and create's read-back are
  gated as well.

The forged registry is made by rewriting the pins of the state datum of a
registry the packaged create made; every expected value is read from the
chain fixture or derived by the producer's own functions, never typed.
-}
module Singular.CLI.PinGateSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.CLI.CommandRunSpec
    ( Rig (..)
    , Run (..)
    , capabilities
    , captured
    , envOf
    , externalArgs
    , outcomeOf
    , policyArgs
    , readWallet
    , receiptReason
    , run
    , runAt
    , runVia
    , runViaApp
    , scriptPinned
    , textAt
    , tokenArgs
    , valueAt
    , withRig
    )
import Singular.CLI.Registry (loadReleaseCodes)
import Singular.CLI.Root (runPackagedVia)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace (Event (..), How (..), Trace (..))
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
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , rawChainProvider
    )
import Singular.Registry.SessionIO qualified as SessionIO
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
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , walletAddr
    )

import Singular.CLI.SubmitSpec (selfPaymentFiles)

spec :: Spec
spec = describe "The pin gate" $ do
    describe "every pin form compares the application pin" formRows
    describe
        "every singular command refuses a registry whose active policy is forged"
        activeRows
    describe
        "an honest registry says whether its application pin was compared"
        standingRows
    describe
        "the report of an interrupted create is gated"
        interruptedRows
    describe "submit gates the registry its bundle names" submitRows
    describe "create reads back the pins it built" readBackRows

-- ---------------------------------------------------------------------------
-- The registries and the forgery
-- ---------------------------------------------------------------------------

-- | A seed the rig's wallet funds: the first six outputs of the chain.
seedAt :: Int -> String
seedAt n = replicate 64 'f' <> "#" <> show n

-- | The application policy a create gives as a hash.
givenPolicy :: BS.ByteString
givenPolicy = BS.replicate 28 7

-- | A policy no application derives.
foreignPolicy :: BS.ByteString
foreignPolicy = BS.replicate 28 0xee

{- | A registry created by the packaged create over the neutral value with
the application policy given as a hash. Its token, as a person passes it.
-}
createdByHash :: Rig -> String -> String -> IO String
createdByHash rig dir seed = do
    r <-
        runAt
            rig
            dir
            ("create " <> dir)
            (["registry", "create", "--seed", seed] <> policyArgs)
    expectCreated r
    tokenOfRun r

{- | A registry created by the packaged create under an application that
states its pin as a blueprint title applied to the registry identity.
-}
createdByScript :: Rig -> Application -> String -> String -> IO String
createdByScript rig app dir seed = do
    r <-
        runViaApp
            rig
            (envOf rig)
            app
            dir
            ("create " <> dir)
            ["registry", "create", "--seed", seed]
    expectCreated r
    tokenOfRun r

tokenOfRun :: Run -> IO String
tokenOfRun r = case textAt "stateToken" (runReceipt r) of
    Just t -> pure (T.unpack t)
    Nothing -> fail ("no state token in " <> runLabel r)

{- | Rewrite the pins of every state datum on the chain, as a creator who
pinned other policies at boot would have left them.
-}
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

forgeApplication :: OnChainTokenState -> OnChainTokenState
forgeApplication st = st{stateAppPolicy = BuiltinByteString foreignPolicy}

-- ---------------------------------------------------------------------------
-- The library: one forged application pin per pin form
-- ---------------------------------------------------------------------------

{- | The refusal the gate gives, or nothing when it accepts: the application
is composed the way a program composes it and the release loaded from the
blueprint for it.
-}
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
tableCommands :: [(String, Rig -> String -> [String])]
tableCommands =
    [
        ( "inspect"
        , \_ t -> ["registry", "inspect", "--key", "alice"] <> tokenArgs t
        )
    ,
        ( "inspect with a wallet address"
        , \rig t ->
            ["registry", "inspect", "--key", "alice"]
                <> tokenArgs t
                <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
        )
    ,
        ( "describe"
        , \_ t -> ["registry", "describe", "--json"] <> tokenArgs t
        )
    , ("fold", \_ t -> ["registry", "fold"] <> tokenArgs t)
    , ("reject", \_ t -> ["registry", "reject"] <> tokenArgs t)
    ,
        ( "reclaim"
        , \_ t ->
            ["registry", "reclaim", "--request", replicate 64 'e' <> "#0"]
                <> tokenArgs t
        )
    ]

-- | Fields only a resolved registry's content reaches a receipt through.
registryContent :: [Key.Key]
registryContent =
    [ "leaf"
    , "root"
    , "observedTip"
    , "applicationOutput"
    , "pendingRequests"
    , "registry"
    , "state"
    , "incompleteCreate"
    ]

{- | The run was refused as a client refusal naming the pinned field, showed
nothing of the registry, and built no transaction.
-}
expectRefusedNaming :: Text -> Run -> Expectation
expectRefusedNaming field r = do
    outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
    receiptReason r
        `shouldSatisfy` maybe False (T.isInfixOf ("registry-pin-mismatch " <> field))
    forM_ registryContent $ \key ->
        valueAt key (runReceipt r) `shouldSatisfy` isNothing
    valueAt "transactions" (runReceipt r) `shouldSatisfy` isNothing
    [() | Trace _ (How (Tx _)) <- runEvents r] `shouldBe` []

activeRows :: Spec
activeRows = do
    forM_ tableCommands $ \(label, wordsOf) ->
        it ("refuses " <> label <> ", naming the active field") $ withRig $ \rig -> do
            writeVersion rig
            t <- createdByHash rig "registry" (seedAt 1)
            forgeState rig forgeActive
            (env, probe) <- probedEnv rig
            r <- runVia rig env "registry" label (wordsOf rig t)
            expectRefusedNaming "active" r
            probeSends probe `shouldReturn` 0
    forM_ tableCommands $ \(label, wordsOf) ->
        it
            ("gives " <> label <> " on an honest registry its own outcome")
            $ withRig
            $ \rig -> do
                writeVersion rig
                t <- createdByHash rig "registry" (seedAt 1)
                r <- run rig label (wordsOf rig t)
                expectHonest label t r

{- | What an honest registry gets from each command: a read succeeds and
shows the registry, a write with nothing to act on is refused for exactly
that, in the command's own words, never for any other reason.
-}
expectHonest :: String -> String -> Run -> Expectation
expectHonest label token r = case label of
    "inspect" -> read'
    "inspect with a wallet address" -> read'
    "describe" -> do
        outcomeOf rcpt `shouldBe` Just "success"
        (valueAt "registry" rcpt >>= textAt "stateToken")
            `shouldBe` Just (T.pack token)
        (valueAt "state" rcpt >>= valueAt "activeKeys")
            `shouldBe` Just (Aeson.toJSON (0 :: Int))
        (valueAt "state" rcpt >>= valueAt "terminalKeys")
            `shouldBe` Just (Aeson.toJSON (0 :: Int))
    "fold" -> refusedFor "nothing is pending: there is no request to fold"
    "reject" -> refusedFor "nothing is pending: there is no request to reject"
    "reclaim" -> do
        refusedFor "the named request is not pending in this registry"
        textAt "request" rcpt
            `shouldBe` Just (T.pack (replicate 64 'e' <> "#0"))
    _ -> expectationFailure ("no expectation for " <> label)
  where
    rcpt = runReceipt r
    read' = do
        outcomeOf rcpt `shouldBe` Just "success"
        textAt "leaf" rcpt `shouldBe` Just "unknown"
        valueAt "pendingRequests" rcpt
            `shouldBe` Just (Aeson.toJSON ([] :: [Int]))
    refusedFor reason = do
        runExit r `shouldBe` ExitFailure 10
        outcomeOf rcpt `shouldBe` Just "client-refusal"
        receiptReason r `shouldBe` Just reason

writeVersion :: Rig -> IO ()
writeVersion rig =
    writeFile
        (takeDirectory (rigBlueprint rig) </> "version.txt")
        "0.10.1\n"

-- ---------------------------------------------------------------------------
-- The standing of the application pin
-- ---------------------------------------------------------------------------

standing :: Text
standing = "not-checked-against-any-blueprint"

-- | How many objects of a receipt carry the field: once, never zero or twice.
standingCount :: Aeson.Value -> Int
standingCount = length . filter (KeyMap.member "applicationPin") . objectsIn

objectsIn :: Aeson.Value -> [Aeson.Object]
objectsIn = \case
    Aeson.Object o -> o : concatMap objectsIn (KeyMap.elems o)
    Aeson.Array xs -> concatMap objectsIn xs
    _ -> []

standingRows :: Spec
standingRows = do
    it
        "says in an inspect receipt, once, that the application pin was not checked"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            r <-
                run
                    rig
                    "inspect"
                    (["registry", "inspect", "--key", "alice"] <> tokenArgs t)
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "applicationPin" (runReceipt r) `shouldBe` Just standing
            standingCount (runReceipt r) `shouldBe` 1
    it
        "says it in a registry whose application pin is forged, which singular cannot check"
        $ withRig
        $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            forgeState rig forgeApplication
            r <-
                run
                    rig
                    "inspect"
                    (["registry", "inspect", "--key", "alice"] <> tokenArgs t)
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "applicationPin" (runReceipt r) `shouldBe` Just standing
    it
        "says it in the describe page beside the application policy, not in the release block"
        $ withRig
        $ \rig -> do
            writeVersion rig
            t <- createdByHash rig "registry" (seedAt 1)
            r <-
                run rig "describe" (["registry", "describe", "--json"] <> tokenArgs t)
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            fmap (textAt "applicationPin") (valueAt "registry" (runReceipt r))
                `shouldBe` Just (Just standing)
            fmap (valueAt "applicationHash") (valueAt "release" (runReceipt r))
                `shouldBe` Just Nothing
    it "says it in the receipt of a fold that stops with nothing pending" $
        withRig $ \rig -> do
            t <- createdByHash rig "registry" (seedAt 1)
            r <- run rig "fold" (["registry", "fold"] <> tokenArgs t)
            textAt "applicationPin" (runReceipt r) `shouldBe` Just standing
            standingCount (runReceipt r) `shouldBe` 1
    it
        "says it in the receipt of a create whose creator gave the policy as a hash"
        $ withRig
        $ \rig -> do
            r <-
                runAt
                    rig
                    "registry"
                    "create by hash"
                    (["registry", "create", "--seed", seedAt 1] <> policyArgs)
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "applicationPin" (runReceipt r) `shouldBe` Just standing
            standingCount (runReceipt r) `shouldBe` 1
    it
        "says in a create over a script pin that the application pin was compared"
        $ withRig
        $ \rig -> do
            r <-
                runViaApp
                    rig
                    (envOf rig)
                    scriptPinned
                    "registry"
                    "create by script"
                    ["registry", "create", "--seed", seedAt 1]
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "applicationPin" (runReceipt r) `shouldBe` Just "compared"
            standingCount (runReceipt r) `shouldBe` 1

-- ---------------------------------------------------------------------------
-- The report of an interrupted create
-- ---------------------------------------------------------------------------

{- | An interrupted create: the staged create of a seed, whose bundle waits
for signatures, so a pending identity is recorded and no registry exists.
-}
withInterruptedCreate :: (Rig -> String -> FilePath -> IO a) -> IO a
withInterruptedCreate use = withRig $ \rig -> do
    let bundlePath = rigDir rig </> "staged.bundle"
    staged <-
        runVia
            rig
            (envOf rig)
            "staged"
            "staged create"
            ( ["registry", "create", "--seed", seedAt 1]
                <> policyArgs
                <> externalArgs rig bundlePath
            )
    runExit staged `shouldBe` ExitFailure 19
    t <- case valueAt "expected" (runReceipt staged) >>= textAt "stateToken" of
        Just tok -> pure (T.unpack tok)
        Nothing -> fail "the staged create names no expected state token"
    use rig t bundlePath

inspectPending :: Rig -> String -> IO Run
inspectPending rig t =
    runAt
        rig
        "staged"
        "inspect of the pending create"
        ( ["registry", "inspect", "--key", "any"]
            <> tokenArgs t
            <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
        )

interruptedRows :: Spec
interruptedRows = do
    it "goes on with the report when the token is not on the chain" $
        withInterruptedCreate $ \rig t _ -> do
            r <- inspectPending rig t
            outcomeOf (runReceipt r) `shouldBe` Just "partial"
            valueAt "incompleteCreate" (runReceipt r) `shouldSatisfy` isJust
    it
        "goes on with the report when the token is on the chain with honest pins"
        $ withInterruptedCreate
        $ \rig t _ -> do
            _ <- createdByHash rig "keyed" (seedAt 1)
            r <- inspectPending rig t
            outcomeOf (runReceipt r) `shouldBe` Just "partial"
            valueAt "incompleteCreate" (runReceipt r) `shouldSatisfy` isJust
    it
        "refuses a token on the chain whose active policy is forged, before any of the report"
        $ withInterruptedCreate
        $ \rig t _ -> do
            _ <- createdByHash rig "keyed" (seedAt 1)
            forgeState rig forgeActive
            r <- inspectPending rig t
            expectRefusedNaming "active" r

-- ---------------------------------------------------------------------------
-- Submit
-- ---------------------------------------------------------------------------

{- | A signed bundle of one self-payment, naming the state token the way a
registry command's bundle does, and the witness for it.
-}
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

-- ---------------------------------------------------------------------------
-- Create reads back its pins
-- ---------------------------------------------------------------------------

{- | The rig's capabilities with every state datum the provider lists
rewritten as the chain would hold it had the boot pinned other policies:
what a create reads back after its boot.
-}
forgedReadBack
    :: Rig
    -> (OnChainTokenState -> OnChainTokenState)
    -> Capabilities NoWitness IO
forgedReadBack rig change =
    (capabilities rig)
        { capReads =
            let (network, provider) = capReads (capabilities rig)
                forging =
                    provider
                        { Cage.acquire =
                            \requested action ->
                                Cage.acquire provider requested (forgingReads action)
                        }
            in  (network, forging)
        }
  where
    forgingReads action session =
        action
            session
                { Cage.outputs =
                    fmap
                        (fmap (\(Evidenced listed w) -> Evidenced (map forgeListed listed) w))
                        . Cage.outputs session
                }
    forgeListed (i, out) = case extractCageDatum out of
        Just (StateDatum st) ->
            ( i
            , out
                & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum (change st)))
            )
        _ -> (i, out)

readBackRows :: Spec
readBackRows = forM_ cases $ \(field, change) ->
    it
        ( "reports a partial outcome naming the "
            <> T.unpack field
            <> " field when the boot's datum differs"
        )
        $ withRig
        $ \rig -> do
            let forging = forgedReadBack rig change
                env =
                    (envOf rig)
                        { envReads = \_ k -> k forging
                        , envWrites = \_ k -> k forging
                        }
            r <-
                runVia
                    rig
                    env
                    "registry"
                    "create over a forged read-back"
                    (["registry", "create", "--seed", seedAt 1] <> policyArgs)
            outcomeOf (runReceipt r) `shouldBe` Just "partial"
            receiptReason r
                `shouldSatisfy` maybe False (T.isInfixOf ("registry-pin-mismatch " <> field))
  where
    cases =
        [ ("active" :: Text, forgeActive)
        , ("application", forgeApplication)
        ]

-- | A create that succeeded, or its refusal's own words as the failure.
expectCreated :: Run -> Expectation
expectCreated r =
    case outcomeOf (runReceipt r) of
        Just "success" -> pure ()
        other ->
            expectationFailure
                ( runLabel r
                    <> " ended "
                    <> show other
                    <> ": "
                    <> show (receiptReason r)
                )

{- | A wallet output still unspent, for the next registry: the creates before
it have spent the funding outputs the first seeds named.
-}
freshSeed :: Rig -> IO String
freshSeed rig = do
    held <- readWallet rig
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for another registry"
