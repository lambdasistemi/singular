{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestCommandSpec
Description : The registration commands of open datum, from the creation of a registry to a cleanup
License     : Apache-2.0

As an open-datum user I create a registry, book the registration of a key with
a payload and a deposit, and see a second wallet fold it from the chain alone:
the key's token lands in a holding that carries my payload and my deposit. If
nobody folds it I reclaim everything inside my window, and after the window
anyone cleans it up and my deposit comes back to me.

The rows run the packaged command lines in process, over the chain fixture and
the compiled validators of the release: the builders run the validators when
they build, so a transaction a command builds is one the validators accept.
Each command that sends keeps its transaction when the node's answer is lost
or the command is cancelled, and nothing is sent again on its own.
-}
module Singular.Application.OpenDatum.RequestCommandSpec (spec) where

import Control.Concurrent
    ( newEmptyMVar
    , putMVar
    , takeMVar
    , threadDelay
    )
import Control.Concurrent.Async (async, cancel, race, waitCatch)
import Control.Monad (forM, forM_, void, when, (>=>))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Either (fromLeft)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text qualified as T
import Lens.Micro ((^.))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Command (parseOpenDatumCommand)
import Singular.Application.OpenDatum.CommandRunSpec
    ( Rig (..)
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
    )
import Singular.Application.OpenDatum.Help (openDatumProgram)
import Singular.Application.OpenDatum.Requests.Records
    ( RegistrationData (..)
    , RequestParameters (..)
    , approvalNameOf
    , decodeConfiguration
    , decodeRegistration
    , liveDatum
    )
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , requestAddress
    , requestPolicy
    , requestScriptFromBlueprint
    )
import Singular.CLI.Command (singularVersion)
import Singular.CLI.ManagedState (managedDir, walletPartition)
import Singular.CLI.Options (commandPaths)
import Singular.CLI.Payload (readPayloadFile)
import Singular.CLI.Receipt (JournalEntry (..), readJournal)
import Singular.CLI.Session (Env (..), txIdHex)
import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (OutputQuery (..), Session)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.PlainJson (PayloadSchema (..))
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , jumpChainTo
    , rawChainProvider
    )
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signedTx)
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , emptyRoot
    , scriptHashBytes
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)
import Singular.State.Assemble (inlineDatumOf, readOutputs)
import Singular.State.Preimage (activeTokenName)
import Singular.State.Records (decodeStateDatum)
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , statePolicy
    , stateScriptFromBlueprint
    )

spec :: Spec
spec = describe "the registration commands" $ do
    parserRows
    commandExtentRow
    lifecycleRows
    interruptionRows

-- ---------------------------------------------------------
-- The command lines
-- ---------------------------------------------------------

node :: [String]
node =
    [ "--blueprint"
    , "plutus.json"
    , "--koios-url"
    , "http://koios.example"
    , "--network-magic"
    , "42"
    ]

keyFile :: [String]
keyFile = ["--wallet-skey", "alice.skey"]

aToken :: String
aToken = replicate 56 'a' <> "." <> replicate 64 'b'

aRef :: String
aRef = replicate 64 'c' <> "#0"

-- | The constructor a command line is read as, or why it is refused.
reading :: [String] -> Either String String
reading =
    either (Left . show) (Right . constructorName) . parseOpenDatumCommand
  where
    constructorName = concat . take 1 . words . show

-- | The kind of a refusal and the flag it names.
aboutRefusal :: Either String a -> Maybe (String, String)
aboutRefusal = \case
    Right _ -> Nothing
    Left shown ->
        Just
            ( concat (take 1 (words shown))
            , takeWhile (/= '"') (drop 1 (dropWhile (/= '"') shown))
            )

-- | Every command of the two groups: its words, a documented line, what it reads as.
commandLines :: [(String, [String], String)]
commandLines =
    [
        ( "state create"
        , ["state", "create"] <> node <> keyFile
        , "OpenStateCreate"
        )
    ,
        ( "state fold"
        , ["state", "fold"]
            <> node
            <> ["--state-token", aToken, "--pending", aRef]
            <> keyFile
        , "OpenStateFold"
        )
    ,
        ( "registration book"
        , ["registration", "book"]
            <> node
            <> [ "--state-token"
               , aToken
               , "--key"
               , "alpha"
               , "--payload"
               , "payload.json"
               ]
            <> keyFile
        , "OpenRegistrationBook"
        )
    ,
        ( "registration reclaim"
        , ["registration", "reclaim"]
            <> node
            <> ["--state-token", aToken, "--pending", aRef]
            <> keyFile
        , "OpenRegistrationReclaim"
        )
    ,
        ( "registration cleanup"
        , ["registration", "cleanup"]
            <> node
            <> ["--state-token", aToken, "--pending", aRef]
            <> keyFile
        , "OpenRegistrationCleanup"
        )
    ]

lineOf :: String -> [String]
lineOf name = concat [line | (n, line, _) <- commandLines, n == name]

dropFlag :: String -> [String] -> [String]
dropFlag flag = \case
    f : _ : rest | f == flag -> rest
    w : rest -> w : dropFlag flag rest
    [] -> []

parserRows :: Spec
parserRows = describe "the command line" $ do
    forM_ commandLines $ \(name, line, constructor) ->
        it ("reads the documented line of " <> name) $
            reading line `shouldBe` Right constructor
    it
        "names the pending registration when fold, reclaim or cleanup lack it"
        $ forM_ ["state fold", "registration reclaim", "registration cleanup"]
        $ \name ->
            aboutRefusal (reading (dropFlag "--pending" (lineOf name)))
                `shouldBe` Just ("MissingFlag", "--pending")
    it "names the payload when a booking lacks it, and the key" $ do
        fmap
            snd
            ( aboutRefusal
                (reading (dropFlag "--payload" (lineOf "registration book")))
            )
            `shouldBe` Just "--payload"
        fmap
            snd
            (aboutRefusal (reading (dropFlag "--key" (lineOf "registration book"))))
            `shouldSatisfy` (`elem` [Just "--key", Just "--key-hex"])
    it
        "reads a pending registration that is no output reference as a bad value of a flag the command takes"
        $ do
            let refused =
                    reading
                        ( ["registration", "reclaim"]
                            <> node
                            <> ["--state-token", aToken, "--pending", "alice"]
                            <> keyFile
                        )
            aboutRefusal refused `shouldBe` Just ("BadValue", "--pending")
            fromLeft "" refused
                `shouldNotSatisfy` isInfixOf "is not a flag"
    it
        "takes no funding choice and no spending limit: the builders choose the funding"
        $ forM_ commandLines
        $ \(name, line, _) ->
            forM_ [["--fund-input", aRef], ["--max-outlay", "5000000"]] $ \extra ->
                (name, fmap snd (aboutRefusal (reading (line <> extra))))
                    `shouldBe` (name, Just (concat (take 1 extra)))
    it
        "reads the five parameters of a registry's configuration, and refuses one that is not a number"
        $ do
            reading
                ( ["state", "create"]
                    <> node
                    <> keyFile
                    <> [ "--process-time"
                       , "600000"
                       , "--reclaim-time"
                       , "300000"
                       , "--booking-width"
                       , "60000"
                       , "--registration-cost"
                       , "0"
                       , "--minimum-tip"
                       , "0"
                       ]
                )
                `shouldBe` Right "OpenStateCreate"
            fmap
                snd
                ( aboutRefusal
                    ( reading
                        (["state", "create"] <> node <> keyFile <> ["--booking-width", "wide"])
                    )
                )
                `shouldBe` Just "--booking-width"
    it
        "is two groups of the program, and no other command is read in them"
        $ do
            reading ["state"] `shouldBe` Right "OpenHelp"
            reading ["registration"] `shouldBe` Right "OpenHelp"
            fmap fst (aboutRefusal (reading ["registration", "insert"]))
                `shouldBe` Just "UnknownCommand"

-- | Every command of the two groups the program declares has a line above.
commandExtentRow :: Spec
commandExtentRow =
    it
        "has a documented line for every command of the two groups the program declares"
        $ do
            let declared =
                    [ unwords path
                    | path <- commandPaths (openDatumProgram singularVersion)
                    , take 1 path `elem` [["state"], ["registration"]]
                    , length path == 2
                    ]
                covered = [name | (name, _, _) <- commandLines]
            declared `shouldNotBe` []
            filter (`notElem` covered) declared `shouldBe` []
            filter (`notElem` declared) covered `shouldBe` []

-- ---------------------------------------------------------
-- The rig, with the compiled validators
-- ---------------------------------------------------------

{- | The blueprint of the release: the validators of the open-datum tree and of
the Singular tree in one file, as the release archive carries them.
-}
releaseBlueprint :: IO Aeson.Value
releaseBlueprint = do
    paths <-
        forM ["OPEN_DATUM_BLUEPRINT", "SINGULAR_STATE_BLUEPRINT"] $ \name ->
            lookupEnv name >>= \case
                Just path | not (null path) -> pure path
                _ ->
                    fail (name <> " is not set: the rows need the compiled validators")
    parts <-
        forM paths (Aeson.eitherDecodeFileStrict' >=> either fail pure)
    let objects = [o | Aeson.Object o <- parts]
        validators =
            nub
                [ v
                | o <- objects
                , Just (Aeson.Array vs) <- [KeyMap.lookup "validators" o]
                , v <- toList vs
                ]
        definitions =
            Aeson.Object . foldr KeyMap.union KeyMap.empty $
                [ d
                | o <- objects
                , Just (Aeson.Object d) <- [KeyMap.lookup "definitions" o]
                ]
        preamble =
            fromMaybe Aeson.Null . mapMaybe' $
                [p | o <- objects, Just p <- [KeyMap.lookup "preamble" o]]
    pure . Aeson.Object . KeyMap.fromList $
        [ ("preamble", preamble)
        , ("validators", Aeson.toJSON validators)
        , ("definitions", definitions)
        ]
  where
    mapMaybe' = \case
        p : _ -> Just p
        [] -> Nothing

withReleaseRig :: (Rig -> IO a) -> IO a
withReleaseRig use = do
    blueprint <- releaseBlueprint
    withRigOf blueprint pure use

-- | The scripts of the release for the registries the rows create.
data Scripts = Scripts
    { scRequest :: RequestScript
    , scState :: StateScript
    }

scriptsOf :: Rig -> IO Scripts
scriptsOf rig = do
    blueprint <- loadBlueprint (rigBlueprint rig) >>= either fail pure
    request <-
        either
            fail
            (\s -> pure (RequestScript s Attached))
            (requestScriptFromBlueprint blueprint)
    state <-
        either fail pure $
            stateScriptFromBlueprint blueprint (requestPolicy request)
    pure (Scripts request (StateScript state Attached))

viewing :: Rig -> (Session NoWitness IO -> IO a) -> IO a
viewing rig = SessionIO.withLatest (rawChainProvider (rigChain rig))

outputsFor :: Rig -> OutputQuery -> IO [(TxIn, TxOut ConwayEra)]
outputsFor rig query =
    viewing rig $ \session ->
        readOutputs session query >>= either (fail . show) pure

-- | Whether an output is still live.
isLive :: Rig -> TxIn -> IO Bool
isLive rig ref =
    viewing rig $ \session ->
        either (const False) (not . null) <$> readOutputs session (AtTxIn ref)

-- | Whatever is live at an address.
liveAt :: Rig -> Addr -> IO [(TxIn, TxOut ConwayEra)]
liveAt rig address = outputsFor rig (AtAddress address)

-- | The parameters every row creates its registry with.
parametersGiven :: RequestParameters
parametersGiven =
    RequestParameters
        { rpRegistrationCost = 2_000_000
        , rpMinimumTip = 1_000_000
        , rpProcessTime = 600_000
        , rpRetractTime = 600_000
        , rpBookingWidth = 60_000
        }

parameterFlags :: [String]
parameterFlags =
    [ "--registration-cost"
    , show (rpRegistrationCost parametersGiven)
    , "--minimum-tip"
    , show (rpMinimumTip parametersGiven)
    , "--process-time"
    , show (rpProcessTime parametersGiven)
    , "--reclaim-time"
    , show (rpRetractTime parametersGiven)
    , "--booking-width"
    , show (rpBookingWidth parametersGiven)
    ]

run' :: Rig -> String -> [String] -> IO Run
run' rig = runAt rig "registry"

-- | The registry the first command of a lifecycle creates, as a person passes it on.
createdRegistry :: Rig -> IO (Run, String)
createdRegistry rig = do
    r <- run' rig "create" (["state", "create"] <> parameterFlags)
    outcomeOf (runReceipt r) `shouldBe` Just "success"
    token <-
        maybe
            (fail "no state token in the creation's receipt")
            (pure . T.unpack)
            $ textAt "stateToken" (runReceipt r)
    pure (r, token)

-- | The booking line of a key.
bookLine :: Rig -> String -> String -> [String]
bookLine rig token key =
    [ "registration"
    , "book"
    , "--state-token"
    , token
    , "--key"
    , key
    , "--payload"
    , rigDir rig </> "payload.json"
    , "--deposit"
    , "2000000"
    , "--tip"
    , "1000000"
    ]

pendingFlags :: String -> TxIn -> [String]
pendingFlags token ref =
    ["--state-token", token, "--pending", T.unpack (renderOutRef ref)]

-- | A second wallet: a key file, its wallet and an output to pay with.
secondWallet :: Rig -> IO (FilePath, Wallet)
secondWallet rig = do
    let keyPath = rigDir rig </> "bob.skey"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'b'))
    wallet <- loadWallet (fromIntegral magic) keyPath
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.insert
                    (fundOutput 90)
                    (mkBasicTxOut (walletAddr wallet) (MaryValue (Coin 500_000_000) mempty))
                    (csUTxO facts)
            }
    pure (keyPath, wallet)

registryOf :: String -> IO (PolicyID, AssetName)
registryOf token =
    either (fail . T.unpack) pure (parseStateToken (T.pack token))

identityOf :: (PolicyID, AssetName) -> RegistryIdentity
identityOf (PolicyID policy, name) =
    RegistryIdentity (StatePolicyId (scriptHashBytes policy)) name

pendingOf :: Run -> IO TxIn
pendingOf r =
    maybe
        (fail "no pending registration in the receipt")
        (either fail pure . parseOutRef)
        $ textAt "pending" (runReceipt r)

-- | The registration a pending output carries.
registrationAt
    :: Rig -> TxIn -> IO (TxOut ConwayEra, RegistrationData)
registrationAt rig ref = do
    found <- outputsFor rig (AtTxIn ref)
    case found of
        [(_, out)] ->
            maybe
                (fail "the output carries no registration")
                (pure . (,) out)
                (inlineDatumOf out >>= decodeRegistration Testnet)
        _ -> fail "the pending registration is not on the chain"

holdsOf :: (PolicyID, AssetName) -> TxOut ConwayEra -> Integer
holdsOf (policy, name) out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  fromMaybe 0 (Map.lookup policy assets >>= Map.lookup name)

-- | Move the chain to the first slot after the millisecond has come.
reachMillisecond :: Rig -> Integer -> IO ()
reachMillisecond rig ms = do
    slot <- viewing rig $ \session -> SessionIO.ceilingSlot session ms
    jumpChainTo (rigChain rig) (SlotNo (fromIntegral (unSlotNo slot) + 1))

-- ---------------------------------------------------------
-- The life of a registration
-- ---------------------------------------------------------

lifecycleRows :: Spec
lifecycleRows = describe "from a registry to a cleanup" $ do
    it
        "creates a registry: the state, its configuration record with the parameters given, and the scripts published once"
        $ withReleaseRig
        $ \rig -> do
            scripts <- scriptsOf rig
            (r, token) <- createdRegistry rig
            textAt "command" (runReceipt r) `shouldBe` Just "state create"
            [step | (step, _, _, _) <- submissionsOf (runReceipt r)]
                `shouldBe` ["publish-scripts", "create"]
            registry <- registryOf token
            states <- outputsFor rig (HoldingAsset registry)
            case states of
                [(_, out)] -> do
                    holdsOf registry out `shouldBe` 1
                    (inlineDatumOf out >>= decodeStateDatum) `shouldBe` Just emptyRoot
                _ ->
                    expectationFailure "the registry's state is not exactly one output"
            records <- liveAt rig (requestAddress Testnet (scRequest scripts))
            mapMaybe (\(_, o) -> inlineDatumOf o >>= decodeConfiguration) records
                `shouldBe` [parametersGiven]
            fst registry `shouldBe` statePolicy (scState scripts)
            r2 <- run' rig "second create" (["state", "create"] <> parameterFlags)
            outcomeOf (runReceipt r2) `shouldBe` Just "success"
            [step | (step, _, _, _) <- submissionsOf (runReceipt r2)]
                `shouldBe` ["create"]
            textAt "stateToken" (runReceipt r2)
                `shouldNotBe` textAt "stateToken" (runReceipt r)

    it
        "books a registration: a pending registration at the request address that holds its approval, with the deadlines the registry's configuration gives"
        $ withReleaseRig
        $ \rig -> do
            scripts <- scriptsOf rig
            (_, token) <- createdRegistry rig
            r <- run' rig "book" (bookLine rig token "alpha")
            runExit r `shouldBe` ExitSuccess
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "command" (runReceipt r) `shouldBe` Just "registration book"
            [step | (step, _, _, _) <- submissionsOf (runReceipt r)]
                `shouldBe` ["book"]
            ref <- pendingOf r
            (out, registration) <- registrationAt rig ref
            out ^. addrTxOutL
                `shouldBe` requestAddress Testnet (scRequest scripts)
            rdKey registration `shouldBe` BC.pack "alpha"
            rdDeposit registration `shouldBe` 2_000_000
            rdRefundAddress registration `shouldBe` walletAddr (rigWallet rig)
            rdProcessDeadline registration - rdBookedAt registration
                `shouldBe` rpProcessTime parametersGiven
            rdReclaimEnd registration - rdProcessDeadline registration
                `shouldBe` rpRetractTime parametersGiven
            approval <-
                maybe (fail "no approval name") pure (approvalNameOf registration)
            holdsOf (requestPolicy (scRequest scripts), approval) out `shouldBe` 1
            let Coin held = out ^. coinTxOutL
            held `shouldSatisfy` (>= 3_000_000)

    it
        "folds a booked registration for a second wallet from the chain alone: the key's token lands in the holding with the payload and the deposit"
        $ withReleaseRig
        $ \rig -> do
            scripts <- scriptsOf rig
            (_, token) <- createdRegistry rig
            booked <- run' rig "book" (bookLine rig token "alpha")
            ref <- pendingOf booked
            (_, registration) <- registrationAt rig ref
            approval <-
                maybe (fail "no approval name") pure (approvalNameOf registration)
            (keyPath, bob) <- secondWallet rig
            alicesOutputs <- map fst <$> liveAt rig (walletAddr (rigWallet rig))
            already <- length <$> readIORef (rigSubmitted rig)
            r <-
                runWithKey
                    keyPath
                    rig
                    "fold"
                    (["state", "fold"] <> pendingFlags token ref)
            runExit r `shouldBe` ExitSuccess
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "command" (runReceipt r) `shouldBe` Just "state fold"
            transactions <- readIORef (rigSubmitted rig)
            length transactions - already `shouldBe` 1
            -- built from the chain alone by the second wallet: it spends nothing of the booker's
            let fold = last transactions
                spent = toList (fold ^. bodyTxL . inputsTxBodyL)
            spent `shouldContain` [ref]
            filter (`elem` alicesOutputs) spent `shouldBe` []
            -- the pending registration and its approval are gone
            isLive rig ref `shouldReturn` False
            approvals <-
                outputsFor
                    rig
                    (HoldingAsset (requestPolicy (scRequest scripts), approval))
            approvals `shouldBe` []
            -- the key's token is in the holding the booking committed, with its payload and deposit
            registry <- registryOf token
            payload <- readPayloadFile PlainSchema (rigDir rig </> "payload.json")
            let key = rdKey registration
                active = (fst registry, activeTokenName (identityOf registry) key)
                controller = addrKeyHashBytes (walletAddr (rigWallet rig))
            holdings <- outputsFor rig (HoldingAsset active)
            case holdings of
                [(_, out)] -> do
                    out ^. addrTxOutL `shouldBe` rdHoldingAddress registration
                    holdsOf active out `shouldBe` 1
                    inlineDatumOf out
                        `shouldBe` Just
                            (liveDatum (identityOf registry) key controller 2_000_000 payload)
                    let Coin kept = out ^. coinTxOutL
                    kept `shouldSatisfy` (>= 2_000_000)
                _ -> expectationFailure "the key's token is not in exactly one holding"
            -- the state's root moved
            states <- outputsFor rig (HoldingAsset registry)
            case states of
                [(_, out)] ->
                    (inlineDatumOf out >>= decodeStateDatum) `shouldNotBe` Just emptyRoot
                _ ->
                    expectationFailure "the registry's state is not exactly one output"
            bobOutputs <- liveAt rig (walletAddr bob)
            map fst bobOutputs `shouldNotContain` [fundOutput 90]

    it
        "returns everything to the refund address when the booker reclaims inside the window"
        $ withReleaseRig
        $ \rig -> do
            (_, token) <- createdRegistry rig
            booked <- run' rig "book" (bookLine rig token "alpha")
            ref <- pendingOf booked
            (out, registration) <- registrationAt rig ref
            reachMillisecond rig (rdProcessDeadline registration)
            r <-
                run'
                    rig
                    "reclaim"
                    (["registration", "reclaim"] <> pendingFlags token ref)
            runExit r `shouldBe` ExitSuccess
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "command" (runReceipt r) `shouldBe` Just "registration reclaim"
            isLive rig ref `shouldReturn` False
            alice <- liveAt rig (walletAddr (rigWallet rig))
            let Coin request = out ^. coinTxOutL
            [c | (_, o) <- alice, let Coin c = o ^. coinTxOutL, c >= request]
                `shouldSatisfy` (not . null)

    it
        "lets anyone clean up after the window: the deposit goes to the refund address, the rest to the cleaner"
        $ withReleaseRig
        $ \rig -> do
            (_, token) <- createdRegistry rig
            booked <- run' rig "book" (bookLine rig token "alpha")
            ref <- pendingOf booked
            (out, registration) <- registrationAt rig ref
            (keyPath, bob) <- secondWallet rig
            aliceBefore <- map fst <$> liveAt rig (walletAddr (rigWallet rig))
            reachMillisecond rig (rdReclaimEnd registration)
            r <-
                runWithKey
                    keyPath
                    rig
                    "cleanup"
                    (["registration", "cleanup"] <> pendingFlags token ref)
            runExit r `shouldBe` ExitSuccess
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "command" (runReceipt r) `shouldBe` Just "registration cleanup"
            isLive rig ref `shouldReturn` False
            -- the refund address received exactly the deposit, in an output of its own
            aliceAfter <- liveAt rig (walletAddr (rigWallet rig))
            let received =
                    [ c
                    | (i, o) <- aliceAfter
                    , i `notElem` aliceBefore
                    , let Coin c = o ^. coinTxOutL
                    ]
            received `shouldBe` [rdDeposit registration]
            -- the cleaner kept what the request held above the deposit, less the fee
            let Coin request = out ^. coinTxOutL
            bobOutputs <- liveAt rig (walletAddr bob)
            let Coin funded = Coin 500_000_000
                held = sum [c | (_, o) <- bobOutputs, let Coin c = o ^. coinTxOutL]
            held
                `shouldSatisfy` (> funded + (request - rdDeposit registration) - 2_000_000)

-- ---------------------------------------------------------
-- Interrupted commands
-- ---------------------------------------------------------

{- | One command of the two groups, with the state it needs: the key to sign
with, the line to run, the directory of its journal, and the number of the
submission to interrupt, counted from the start of its run (the first creation
of a registry sends two transactions, the others one).
-}
data Scenario = Scenario
    { scenarioName :: String
    , scenarioSubmission :: Int
    , scenarioSetup :: Rig -> IO (FilePath, [String], FilePath)
    }

registryJournal :: Rig -> (PolicyID, AssetName) -> Wallet -> FilePath
registryJournal rig registry wallet =
    managedDir
        (rigDir rig </> "registry")
        (fromIntegral magic)
        registry
        (walletPartition wallet)

scenarios :: [Scenario]
scenarios =
    [ Scenario "state create" 2 $ \rig -> do
        scripts <- scriptsOf rig
        pure
            ( rigKey rig
            , ["state", "create"] <> parameterFlags
            , registryJournal
                rig
                (statePolicy (scState scripts), AssetName mempty)
                (rigWallet rig)
            )
    , Scenario "registration book" 1 $ \rig -> do
        (_, token) <- createdRegistry rig
        registry <- registryOf token
        pure
            ( rigKey rig
            , bookLine rig token "alpha"
            , registryJournal rig registry (rigWallet rig)
            )
    , Scenario "state fold" 1 $ \rig -> do
        (_, token) <- createdRegistry rig
        booked <- run' rig "book" (bookLine rig token "alpha")
        ref <- pendingOf booked
        (keyPath, bob) <- secondWallet rig
        registry <- registryOf token
        pure
            ( keyPath
            , ["state", "fold"] <> pendingFlags token ref
            , registryJournal rig registry bob
            )
    , Scenario "registration reclaim" 1 $ \rig -> do
        (_, token) <- createdRegistry rig
        booked <- run' rig "book" (bookLine rig token "alpha")
        ref <- pendingOf booked
        (_, registration) <- registrationAt rig ref
        reachMillisecond rig (rdProcessDeadline registration)
        registry <- registryOf token
        pure
            ( rigKey rig
            , ["registration", "reclaim"] <> pendingFlags token ref
            , registryJournal rig registry (rigWallet rig)
            )
    , Scenario "registration cleanup" 1 $ \rig -> do
        (_, token) <- createdRegistry rig
        booked <- run' rig "book" (bookLine rig token "alpha")
        ref <- pendingOf booked
        (_, registration) <- registrationAt rig ref
        (keyPath, bob) <- secondWallet rig
        reachMillisecond rig (rdReclaimEnd registration)
        registry <- registryOf token
        pure
            ( keyPath
            , ["registration", "cleanup"] <> pendingFlags token ref
            , registryJournal rig registry bob
            )
    ]

{- | The environment whose node answers the submission the scenario names
otherwise, counting from the first one of this environment: it applies the
transaction before it stops answering, or never sees it. A submission number
of zero changes nothing.
-}
answeringAfter :: Rig -> Int -> Bool -> IO (Env, IO [ConwayTx])
answeringAfter rig nth applies = do
    sent <- newIORef []
    count <- newIORef (0 :: Int)
    let caps = capabilities rig
        watching =
            caps
                { capSubmit = \signed -> do
                    modifyIORef' sent (<> [signedTx signed])
                    modifyIORef' count (+ 1)
                    here <- readIORef count
                    if here == nth
                        then do
                            when applies (void (capSubmit caps signed))
                            pure (Cage.SubmitFailed "the node did not answer")
                        else capSubmit caps signed
                }
    pure ((envOf rig){envWrites = \_ k -> k watching}, readIORef sent)

recordingEnv :: Rig -> IO (Env, IO [ConwayTx])
recordingEnv rig = answeringAfter rig 0 False

runKeyed :: Rig -> Env -> FilePath -> String -> [String] -> IO Run
runKeyed rig env keyPath label line =
    runVia rig env "registry" label (line <> ["--wallet-skey", keyPath])

interruptionRows :: Spec
interruptionRows = describe "an interrupted command" $
    forM_ scenarios $ \scenario -> describe (scenarioName scenario) $ do
        it
            "keeps the transaction when the node's answer is lost after it took it, and the next command observes it once"
            $ withReleaseRig
            $ \rig -> do
                (keyPath, line, journalDir) <- scenarioSetup scenario rig
                (env, sent) <- answeringAfter rig (scenarioSubmission scenario) True
                r <- runKeyed rig env keyPath "lost answer" line
                outcomeOf (runReceipt r) `shouldBe` Just "partial"
                runExit r `shouldBe` ExitFailure 15
                lost <- (!! (scenarioSubmission scenario - 1)) . map txIdHex <$> sent
                entries <- readJournal journalDir
                [ journalTxId e
                  | e <- entries
                  , journalEvent e == "prepared"
                  , journalTxId e == lost
                  ]
                    `shouldBe` [lost]
                (env2, sent2) <- recordingEnv rig
                _ <- runKeyed rig env2 keyPath "next" line
                later <- readJournal journalDir
                length
                    [e | e <- later, journalTxId e == lost, journalEvent e == "observed"]
                    `shouldBe` 1
                length
                    [e | e <- later, journalTxId e == lost, journalEvent e == "prepared"]
                    `shouldBe` 1
                resent <- map txIdHex <$> sent2
                resent `shouldNotContain` [lost]
        it
            "keeps the transaction when the node never saw it, and the next command is refused naming it and sends nothing"
            $ withReleaseRig
            $ \rig -> do
                (keyPath, line, journalDir) <- scenarioSetup scenario rig
                (env, sent) <- answeringAfter rig (scenarioSubmission scenario) False
                r <- runKeyed rig env keyPath "never saw" line
                outcomeOf (runReceipt r) `shouldBe` Just "partial"
                lost <- (!! (scenarioSubmission scenario - 1)) . map txIdHex <$> sent
                (env2, sent2) <- recordingEnv rig
                r2 <- runKeyed rig env2 keyPath "refused" line
                outcomeOf (runReceipt r2) `shouldBe` Just "partial"
                runExit r2 `shouldBe` ExitFailure 15
                T.unpack (fromMaybe "" (textAt "reason" (runReceipt r2)))
                    `shouldSatisfy` (T.unpack lost `isInfixOf`)
                sent2 `shouldReturn` []
                entries <- readJournal journalDir
                [ journalTxId e
                  | e <- entries
                  , journalEvent e == "prepared"
                  , journalTxId e == lost
                  ]
                    `shouldBe` [lost]
        it
            "keeps the transaction when the command is cancelled while it sends, and nothing is sent again"
            $ withReleaseRig
            $ \rig -> do
                (keyPath, line, journalDir) <- scenarioSetup scenario rig
                reached <- newEmptyMVar
                count <- newIORef (0 :: Int)
                let caps = capabilities rig
                    stalling =
                        caps
                            { capSubmit = \signed -> do
                                modifyIORef' count (+ 1)
                                here <- readIORef count
                                if here == scenarioSubmission scenario
                                    then do
                                        putMVar reached (signedTx signed)
                                        threadDelay maxBound
                                        capSubmit caps signed
                                    else capSubmit caps signed
                            }
                    env = (envOf rig){envWrites = \_ k -> k stalling}
                running <- async (runKeyed rig env keyPath "cancelled" line)
                outcome <- race (takeMVar reached) (waitCatch running)
                held <- case outcome of
                    Left signed -> pure signed
                    Right ended ->
                        fail
                            ( "the command ended before it sent: "
                                <> either show (const "with a receipt") ended
                            )
                cancel running
                _ <- waitCatch running
                entries <- readJournal journalDir
                [ journalTxId e
                  | e <- entries
                  , journalEvent e == "prepared"
                  , journalTxId e == txIdHex held
                  ]
                    `shouldBe` [txIdHex held]
                (env2, sent2) <- recordingEnv rig
                r2 <- runKeyed rig env2 keyPath "after cancel" line
                outcomeOf (runReceipt r2) `shouldBe` Just "partial"
                T.unpack (fromMaybe "" (textAt "reason" (runReceipt r2)))
                    `shouldSatisfy` (T.unpack (txIdHex held) `isInfixOf`)
                sent2 `shouldReturn` []
